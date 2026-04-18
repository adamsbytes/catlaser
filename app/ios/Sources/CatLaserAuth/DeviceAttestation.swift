import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Wire-format attestation attached to authenticated server calls.
/// Replaces the v1 plaintext-JSON fingerprint header and the v2
/// unbounded-lifetime signature.
///
/// ## Wire format (v4)
///
/// Header name: `x-device-attestation`.
///
/// Header value: base64(UTF-8(canonicalJSON(payload))) where `payload` is
/// an object with exactly these keys, sorted lexicographically:
///
/// ```
/// {
///   "bnd": "req:<unix_seconds>"
///        | "ver:<magic_link_token>"
///        | "sis:<unix_seconds>:<raw_nonce>"
///        | "out:<unix_seconds>"
///        | "api:<unix_seconds>",
///   "fph": "<base64url-no-pad(sha256(canonical fingerprint JSON), 32 bytes)>",
///   "pk":  "<base64(DER SubjectPublicKeyInfo of the client's P-256 public key, 91 bytes)>",
///   "sig": "<base64(DER ECDSA-P256-SHA256 signature over fph_raw || bnd_utf8)>",
///   "v":   4
/// }
/// ```
///
/// ### Version history
///
/// * v4 (current) — adds a signed wall-clock timestamp to the `sis:`
///   binding. The server enforces the same ±60s skew window on `sis:`
///   as on `req:`/`out:`/`api:`. Closes the capture-then-replay vector
///   the v3 nonce-only `sis:` left open: a captured `(body,
///   attestation)` pair could otherwise be replayed for the full
///   ID-token lifetime (~10 min on Apple, up to an hour on Google)
///   without the SE private key, since replay is a verbatim resend of
///   the original bytes. Also introduces the `api:` binding used on
///   every authenticated API call after sign-in (ADR-006).
/// * v3 — introduced per-binding tagged freshness; `sis:` carried the
///   raw nonce only. Retired with v4.
/// * v2, v1 — pre-attestation wire formats. Permanently retired.
///
/// Outer encoding is standard base64 (with `+`/`/`/padding) — HTTP
/// headers accept those characters. Inner `fph` is base64url-no-pad for
/// a shorter, URL-logger-safe hash representation; the raw 32-byte hash
/// digest is what's concatenated with `bnd` and signed.
///
/// ## Why `bnd`
///
/// The v2 signature was over the fingerprint hash alone. Because the
/// fingerprint is deterministic per device, any captured v2 header was a
/// forever-valid attestation for that device — an attacker who got a
/// single `(fph, pk, sig)` triple out of a log store, an eBPF hook on
/// the unencrypted path, or a briefly-compromised TLS middlebox could
/// replay it indefinitely. v3+ binds each signature to a freshness input:
///
/// * On `requestMagicLink`: `bnd = "req:<now_seconds>"`. Server rejects
///   skew > ~60s; captured headers expire within a minute.
/// * On `completeMagicLink`: `bnd = "ver:<magic_link_token>"`. The token
///   is server-issued, single-use, and rotated on every request. A
///   request-time signature cannot satisfy a verify call because the
///   signed bytes differ, and a verify-time signature cannot be re-used
///   with any other token.
/// * On `exchangeSocial`: `bnd = "sis:<now_seconds>:<raw_nonce>"`. The
///   nonce is single-use, echoed through the identity provider, and
///   three-way-matched server-side (request body, ID-token claim, `bnd`
///   raw nonce). The timestamp adds the ±60s skew window so that a
///   captured `(body, attestation)` pair cannot be replayed past that
///   bound even within the provider ID-token's validity period.
/// * On `signOut`: `bnd = "out:<now_seconds>"`. Same skew contract as
///   the request-time binding; the distinct tag means a captured
///   `req:<ts>` header cannot be replayed against the sign-out
///   endpoint, and vice versa.
/// * On every authenticated API call after sign-in: `bnd =
///   "api:<now_seconds>"`. Same skew contract; server verifies the
///   signature under the pk captured at sign-in so a leaked bearer
///   alone cannot act.
///
/// The tagged prefix also prevents cross-context confusion in which a
/// client or server strips the prefix before parsing — the raw bytes fed
/// to ECDSA already differ in the first four characters.
///
/// ## Server verification
///
/// On every attestation-bearing endpoint:
///
/// 1. Parse the header; reject if `v != 4`.
/// 2. base64-decode `pk`; assert length == 91 and the first 26 bytes
///    match the P-256 SPKI prefix (`DeviceIdentity.ecP256SPKIPrefix`).
/// 3. base64url-decode `fph`; assert length == 32.
/// 4. Parse `bnd`. The tag must match the endpoint (`req:` on
///    `requestMagicLink`, `ver:` on `completeMagicLink`, `sis:` on
///    `exchangeSocial`, `out:` on `signOut`, `api:` on every
///    authenticated API call). Payload validation is per-tag: timestamps
///    must be positive Int64s inside the ±60s skew window; `ver:` token
///    must byte-equal the token parsed from the magic-link URL; `sis:`
///    raw nonce must byte-equal `body.idToken.nonce`.
/// 5. Reconstruct the signed message as `fph_raw_32_bytes || bnd_utf8`
///    and verify `sig` over it using the public key from `pk`. Reject on
///    verify failure.
///
/// Additionally, at **verify time** only:
///
/// 6. Look up the stored request-time record by the magic-link token.
/// 7. Byte-compare the verify request's `fph` against the stored `fph`.
///    Reject on mismatch with `DEVICE_MISMATCH`.
/// 8. Byte-compare the verify request's `pk` against the stored `pk`.
///    Reject on mismatch with `DEVICE_MISMATCH`.
///
/// Step 8 is required: an attacker who observes the stored `fph` value
/// could attempt to forge a verify call under their own public key. The
/// stored-`pk` comparison binds the verify call to the exact Secure
/// Enclave that requested the link.
///
/// On **protected-route** (`api:`) calls the verify path uses the pk
/// captured against the session at sign-in instead of the pk on the
/// wire, so a captured bearer paired with a fresh attestation signed
/// by any other key cannot satisfy the signature check.
///
/// ## What is NOT on the wire
///
/// `platform`, `model`, `systemName`, `osVersion`, `locale`, `timezone`,
/// `appVersion`, `appBuild`, `bundleID`, `installID` — all collapsed
/// into the 32-byte `fph` hash. Server-side observability tools that
/// capture request headers cannot derive them.
public struct DeviceAttestation: Sendable, Equatable {
    public static let currentVersion: Int = 4

    public let version: Int
    public let fingerprintHash: Data
    public let publicKeySPKI: Data
    public let binding: AttestationBinding
    public let signature: Data

    public init(
        version: Int = DeviceAttestation.currentVersion,
        fingerprintHash: Data,
        publicKeySPKI: Data,
        binding: AttestationBinding,
        signature: Data,
    ) {
        self.version = version
        self.fingerprintHash = fingerprintHash
        self.publicKeySPKI = publicKeySPKI
        self.binding = binding
        self.signature = signature
    }
}

public enum DeviceAttestationEncoder {
    public static let headerName = "x-device-attestation"

    /// Upper bound on the serialized base64 value. Empirically ~450-500
    /// bytes for v3 (32 + 91 + ~72 + JSON framing including `bnd`, base64
    /// of all of that). HTTP stacks typically reject header values past
    /// 8 KiB; the conservative ceiling here catches any runaway encoding
    /// bug before it hits the server.
    public static let maxHeaderValueBytes = 2048

    public static func encodeHeaderValue(_ attestation: DeviceAttestation) throws(AuthError) -> String {
        guard attestation.fingerprintHash.count == 32 else {
            throw .attestationFailed(
                "fingerprint hash must be 32 bytes, got \(attestation.fingerprintHash.count)",
            )
        }
        guard attestation.publicKeySPKI.count >= 26,
              attestation.publicKeySPKI.prefix(DeviceIdentity.ecP256SPKIPrefix.count)
                == Data(DeviceIdentity.ecP256SPKIPrefix)
        else {
            throw .attestationFailed(
                "public key is not a well-formed P-256 SPKI (len=\(attestation.publicKeySPKI.count))",
            )
        }
        guard !attestation.signature.isEmpty else {
            throw .attestationFailed("signature is empty")
        }
        let bnd = attestation.binding.wireValue
        guard bnd.utf8.count <= AttestationBinding.maxWireBytes else {
            throw .attestationFailed(
                "bnd exceeds \(AttestationBinding.maxWireBytes) bytes (got \(bnd.utf8.count))",
            )
        }
        let payload = WirePayload(
            bnd: bnd,
            fph: DeviceIdentity.base64URLNoPad(attestation.fingerprintHash),
            pk: attestation.publicKeySPKI.base64EncodedString(),
            sig: attestation.signature.base64EncodedString(),
            v: attestation.version,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            throw .attestationFailed("attestation encode failed: \(error.localizedDescription)")
        }
        let header = data.base64EncodedString()
        guard header.utf8.count <= maxHeaderValueBytes else {
            throw .attestationFailed(
                "attestation header exceeds \(maxHeaderValueBytes) bytes (got \(header.utf8.count))",
            )
        }
        return header
    }

    /// Parse a header value back into a `DeviceAttestation`. Used by
    /// tests and by a Swift port of the server plugin; the app itself
    /// only ever encodes.
    public static func decodeHeaderValue(_ value: String) throws(AuthError) -> DeviceAttestation {
        guard let outer = Data(base64Encoded: value) else {
            throw .attestationFailed("outer base64 decode failed")
        }
        let payload: WirePayload
        do {
            payload = try JSONDecoder().decode(WirePayload.self, from: outer)
        } catch {
            throw .attestationFailed("attestation JSON decode failed: \(error.localizedDescription)")
        }
        guard let fph = decodeBase64URL(payload.fph), fph.count == 32 else {
            throw .attestationFailed("fph is not 32 base64url-decoded bytes")
        }
        guard let pk = Data(base64Encoded: payload.pk) else {
            throw .attestationFailed("pk base64 decode failed")
        }
        guard let sig = Data(base64Encoded: payload.sig) else {
            throw .attestationFailed("sig base64 decode failed")
        }
        let binding = try AttestationBinding.decode(wireValue: payload.bnd)
        return DeviceAttestation(
            version: payload.v,
            fingerprintHash: fph,
            publicKeySPKI: pk,
            binding: binding,
            signature: sig,
        )
    }

    private struct WirePayload: Codable {
        let bnd: String
        let fph: String
        let pk: String
        let sig: String
        let v: Int
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.utf8.count % 4
        if remainder != 0 {
            standard.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: standard)
    }
}

/// Compose a `DeviceAttestation` from a `DeviceFingerprint` plus a
/// `DeviceIdentityStoring`. Factored out so call sites can build one
/// without depending on `DeviceAttestationProviding` (e.g. when
/// constructing an attestation from a Fingerprint that was produced
/// elsewhere).
public enum DeviceAttestationBuilder {
    #if canImport(CryptoKit)
    private typealias Digest = CryptoKit.SHA256
    #else
    private typealias Digest = Crypto.SHA256
    #endif

    /// Build a v3 attestation. The signed ECDSA message is
    /// `fph_raw_32_bytes || binding.wireBytes`; both components are
    /// echoed to the server on the wire so it can reconstruct and verify
    /// exactly the same byte sequence.
    public static func build(
        fingerprint: DeviceFingerprint,
        identity: any DeviceIdentityStoring,
        binding: AttestationBinding,
    ) async throws -> DeviceAttestation {
        let canonical = try fingerprint.canonicalJSONBytes()
        let hash = Data(Digest.hash(data: canonical))
        let spki = try await identity.publicKeySPKI()
        let bindingBytes = binding.wireBytes
        guard bindingBytes.count <= AttestationBinding.maxWireBytes else {
            throw AuthError.attestationFailed(
                "bnd exceeds \(AttestationBinding.maxWireBytes) bytes (got \(bindingBytes.count))",
            )
        }
        var signed = Data(capacity: hash.count + bindingBytes.count)
        signed.append(hash)
        signed.append(bindingBytes)
        let signature = try await identity.sign(signed)
        return DeviceAttestation(
            fingerprintHash: hash,
            publicKeySPKI: spki,
            binding: binding,
            signature: signature,
        )
    }
}
