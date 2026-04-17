import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Wire-format attestation attached to magic-link request and verify
/// calls. Replaces the v1 plaintext-JSON fingerprint header.
///
/// ## Wire format
///
/// Header name: `x-device-attestation`.
///
/// Header value: base64(UTF-8(canonicalJSON(payload))) where `payload` is
/// an object with exactly these keys, sorted lexicographically:
///
/// ```
/// {
///   "fph": "<base64url-no-pad(sha256(canonical fingerprint JSON), 32 bytes)>",
///   "pk":  "<base64(DER SubjectPublicKeyInfo of the client's P-256 public key, 91 bytes)>",
///   "sig": "<base64(DER ECDSA-P256-SHA256 signature over fph's 32 raw bytes)>",
///   "v":   2
/// }
/// ```
///
/// Outer encoding is standard base64 (with `+`/`/`/padding) — HTTP
/// headers accept those characters. Inner `fph` is base64url-no-pad for
/// a shorter, URL-logger-safe hash representation; the raw 32-byte hash
/// digest is what's signed.
///
/// ## Server verification
///
/// For BOTH request and verify endpoints:
///
/// 1. Parse the header; reject if `v != 2`.
/// 2. base64-decode `pk`; assert length == 91 and the first 26 bytes
///    match the P-256 SPKI prefix (`DeviceIdentity.ecP256SPKIPrefix`).
/// 3. base64url-decode `fph`; assert length == 32.
/// 4. Verify `sig` over the 32-byte `fph` using the public key from `pk`.
///    Reject on verify failure.
///
/// Additionally, at **verify time** only:
///
/// 5. Look up the stored request-time record by the magic-link token.
/// 6. Byte-compare the verify request's `fph` against the stored `fph`.
///    Reject on mismatch with `DEVICE_MISMATCH`.
/// 7. Byte-compare the verify request's `pk` against the stored `pk`.
///    Reject on mismatch with `DEVICE_MISMATCH`.
///
/// Step 7 is required: an attacker who observes the stored `fph` value
/// could replay it with their own public key and a valid signature from
/// their own key. Comparing `pk` too binds the verify call to the exact
/// Secure Enclave that requested the link.
///
/// ## What is NOT on the wire
///
/// `platform`, `model`, `systemName`, `osVersion`, `locale`, `timezone`,
/// `appVersion`, `appBuild`, `bundleID`, `installID` — all collapsed
/// into the 32-byte `fph` hash. Server-side observability tools that
/// capture request headers cannot derive them.
public struct DeviceAttestation: Sendable, Equatable {
    public static let currentVersion: Int = 2

    public let version: Int
    public let fingerprintHash: Data
    public let publicKeySPKI: Data
    public let signature: Data

    public init(
        version: Int = DeviceAttestation.currentVersion,
        fingerprintHash: Data,
        publicKeySPKI: Data,
        signature: Data,
    ) {
        self.version = version
        self.fingerprintHash = fingerprintHash
        self.publicKeySPKI = publicKeySPKI
        self.signature = signature
    }
}

public enum DeviceAttestationEncoder {
    public static let headerName = "x-device-attestation"

    /// Upper bound on the serialized base64 value. Empirically ~420 bytes
    /// for v2 (32 + 91 + ~72 + JSON framing, base64 of all of that). HTTP
    /// stacks typically reject header values past 8 KiB; the conservative
    /// ceiling here catches any runaway encoding bug before it hits the
    /// server.
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
        let payload = WirePayload(
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
        return DeviceAttestation(
            version: payload.v,
            fingerprintHash: fph,
            publicKeySPKI: pk,
            signature: sig,
        )
    }

    private struct WirePayload: Codable {
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

    public static func build(
        fingerprint: DeviceFingerprint,
        identity: any DeviceIdentityStoring,
    ) async throws -> DeviceAttestation {
        let canonical = try fingerprint.canonicalJSONBytes()
        let hash = Data(Digest.hash(data: canonical))
        let spki = try await identity.publicKeySPKI()
        let signature = try await identity.sign(hash)
        return DeviceAttestation(
            fingerprintHash: hash,
            publicKeySPKI: spki,
            signature: signature,
        )
    }
}
