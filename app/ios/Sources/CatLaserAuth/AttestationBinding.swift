import Foundation

/// Per-call freshness input mixed into the ECDSA signature of a
/// `DeviceAttestation`. Without this, the signed payload is just the
/// fingerprint hash — a value that is stable for a given device and
/// therefore indefinitely replayable by anyone who ever captures a valid
/// attestation header (server-side logs, a one-off TLS bypass, a future
/// pinning hook). Binding each signature to a context-specific value
/// collapses that window to a single request.
///
/// Six variants, one per authenticated endpoint:
///
/// * `.request(timestamp:)` — placed on the outbound `requestMagicLink`
///   call. Timestamp is Unix seconds at the moment the attestation is
///   built. Server rejects skew > ~60s; that implicitly limits the
///   replay window to one minute even if the full header leaks.
///
/// * `.verify(token:)` — placed on the `completeMagicLink` call. The
///   magic-link token is single-use and server-issued; binding the
///   signature to it means a request-time attestation cannot satisfy a
///   verify call, and a verify-time attestation cannot be re-used with
///   a different token. Request and verify signatures are disjoint by
///   construction even when every other input is identical.
///
/// * `.social(timestamp:rawNonce:)` — placed on the `exchangeSocial`
///   call for Apple / Google ID-token sign-in. Binds TWO freshness
///   inputs: the per-sign-in raw nonce (client-generated and also
///   echoed in the provider ID token's `nonce` claim — hashed for
///   Apple, verbatim for Google — so the server can three-way-match the
///   binding against the body and the provider claim), AND a wall-clock
///   Unix-seconds timestamp under the same ±60s skew contract as
///   `.request` / `.signOut`.
///
///   The timestamp is the v4 addition — without it a captured
///   `(body, attestation)` pair could be replayed for the full ID-token
///   lifetime (~10 minutes on Apple, up to an hour on Google) because
///   replay does not require the non-extractable Secure-Enclave private
///   key: the attacker re-submits the original bytes verbatim.
///   Enforcing the timestamp pins the replay window to ±60s, matching
///   the rest of the attestation surface.
///
/// * `.signOut(timestamp:)` — placed on the `signOut` call. Same
///   timestamp + skew contract as `.request`; distinct tag prevents a
///   captured `req:` signature from being submitted to the sign-out
///   endpoint (and vice versa). Device-binds the revocation so a leaked
///   bearer token alone cannot invalidate a session without also
///   forging a signature under the original Secure-Enclave key.
///
/// * `.api(timestamp:)` — placed on every authenticated API call after
///   sign-in. Same timestamp + skew contract as the other timestamped
///   bindings. Distinct tag prevents a captured sign-in-time attestation
///   from being replayed against a protected route, and vice versa. The
///   server-side protected-route middleware verifies every `api:`
///   binding under the pk captured at sign-in, so a leaked bearer alone
///   cannot act — a fresh SE signature is also required. ADR-006
///   documents the full contract.
///
/// * `.device(timestamp:)` — placed on the `AuthRequest` frame the app
///   sends as the FIRST frame on every TCP connection to the device
///   daemon. The frame carries a full v4 attestation header with
///   `bnd = "dev:<unix_seconds>"`. The device parses the header,
///   reconstructs the signed bytes, verifies the P-256 ECDSA signature
///   against the `pk` embedded in the frame, and then matches that pk
///   against its cached ACL of authorized users. Skew is checked by the
///   device against its local clock with the same ±60s window as the
///   server-side bindings. Distinct tag prevents any other captured
///   attestation from being replayed as a device auth frame, and
///   prevents a captured device frame from being replayed against a
///   coordination-server endpoint.
///
/// Wire format: the binding renders to a tagged UTF-8 string
/// (`"req:<ts>"`, `"ver:<token>"`, `"sis:<ts>:<rawNonce>"`,
/// `"out:<ts>"`, `"api:<ts>"`, or `"dev:<ts>"`) that is both:
///
/// 1. Placed on the wire under the `bnd` key of the attestation payload.
/// 2. Appended to the 32-byte `fph` hash and fed as the ECDSA message —
///    `sig = ECDSA-P256-SHA256(fph_raw || bnd_utf8, private_key)`.
///
/// The tagging prevents cross-context confusion: a server that strips the
/// prefix before parsing would still refuse to accept a `ver:` signature
/// as a `req:` input (or a `sis:` signature as either), because the raw
/// signed bytes differ in their first four characters.
public enum AttestationBinding: Sendable, Equatable {
    case request(timestamp: Int64)
    case verify(token: String)
    case social(timestamp: Int64, rawNonce: String)
    case signOut(timestamp: Int64)
    case api(timestamp: Int64)
    case device(timestamp: Int64)

    /// Upper bound on the UTF-8 size of `wireBytes`. Magic-link tokens and
    /// raw nonces are small (tens of bytes); this bound exists so a
    /// malformed caller cannot inflate the attestation header. Enforced
    /// by `DeviceAttestationEncoder` before placing the binding on the
    /// wire.
    public static let maxWireBytes = 1024

    /// Canonical UTF-8 encoding placed on the wire under `bnd` and mixed
    /// into the ECDSA signature input.
    public var wireValue: String {
        switch self {
        case let .request(timestamp): "req:\(timestamp)"
        case let .verify(token): "ver:\(token)"
        case let .social(timestamp, rawNonce): "sis:\(timestamp):\(rawNonce)"
        case let .signOut(timestamp): "out:\(timestamp)"
        case let .api(timestamp): "api:\(timestamp)"
        case let .device(timestamp): "dev:\(timestamp)"
        }
    }

    public var wireBytes: Data {
        Data(wireValue.utf8)
    }

    /// Parse a wire value back into a binding. Used by the server plugin's
    /// Swift port and by tests; the app itself only ever encodes.
    ///
    /// Tolerates nothing: unknown tag, empty payload, leading-zero /
    /// signed / non-numeric timestamps, and control characters in the
    /// token or nonce all reject.
    public static func decode(wireValue: String) throws(AuthError) -> AttestationBinding {
        guard wireValue.utf8.count <= maxWireBytes else {
            throw .attestationFailed("bnd exceeds \(maxWireBytes) bytes (got \(wireValue.utf8.count))")
        }
        if let ts = wireValue.prefixStrippedIfMatches("req:") {
            guard let parsed = Int64(ts), parsed > 0, String(parsed) == ts else {
                throw .attestationFailed("bnd timestamp is not a positive decimal Int64")
            }
            return .request(timestamp: parsed)
        }
        if let token = wireValue.prefixStrippedIfMatches("ver:") {
            guard !token.isEmpty else {
                throw .attestationFailed("bnd verify token is empty")
            }
            let disallowed = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
            if token.unicodeScalars.contains(where: disallowed.contains) {
                throw .attestationFailed("bnd verify token contains control characters")
            }
            return .verify(token: token)
        }
        if let payload = wireValue.prefixStrippedIfMatches("sis:") {
            // `sis:` carries `<timestamp>:<rawNonce>`. Split on the FIRST
            // `:` so a future widening of the nonce charset that happened
            // to contain `:` still round-trips — iOS `NonceGenerator`
            // currently emits base64url-no-pad (no `:` possible), so this
            // is strictly forward-compatibility insurance.
            guard let sep = payload.firstIndex(of: ":") else {
                throw .attestationFailed(
                    "bnd sis: missing ':<rawNonce>' suffix (expected 'sis:<unix_seconds>:<raw_nonce>')",
                )
            }
            let tsString = String(payload[..<sep])
            let rawNonce = String(payload[payload.index(after: sep)...])
            guard let parsed = Int64(tsString), parsed > 0, String(parsed) == tsString else {
                throw .attestationFailed("bnd sis: timestamp is not a positive decimal Int64")
            }
            guard !rawNonce.isEmpty else {
                throw .attestationFailed("bnd social raw nonce is empty")
            }
            let disallowed = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
            if rawNonce.unicodeScalars.contains(where: disallowed.contains) {
                throw .attestationFailed("bnd social raw nonce contains control characters")
            }
            return .social(timestamp: parsed, rawNonce: rawNonce)
        }
        if let ts = wireValue.prefixStrippedIfMatches("out:") {
            guard let parsed = Int64(ts), parsed > 0, String(parsed) == ts else {
                throw .attestationFailed("bnd sign-out timestamp is not a positive decimal Int64")
            }
            return .signOut(timestamp: parsed)
        }
        if let ts = wireValue.prefixStrippedIfMatches("api:") {
            guard let parsed = Int64(ts), parsed > 0, String(parsed) == ts else {
                throw .attestationFailed("bnd api timestamp is not a positive decimal Int64")
            }
            return .api(timestamp: parsed)
        }
        if let ts = wireValue.prefixStrippedIfMatches("dev:") {
            guard let parsed = Int64(ts), parsed > 0, String(parsed) == ts else {
                throw .attestationFailed("bnd device timestamp is not a positive decimal Int64")
            }
            return .device(timestamp: parsed)
        }
        throw .attestationFailed(
            "bnd has no recognised tag (expected 'req:', 'ver:', 'sis:', 'out:', 'api:', or 'dev:')",
        )
    }
}

private extension String {
    func prefixStrippedIfMatches(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
