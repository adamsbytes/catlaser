import Foundation

/// Per-call freshness input mixed into the ECDSA signature of a
/// `DeviceAttestation`. Without this, the signed payload is just the
/// fingerprint hash — a value that is stable for a given device and
/// therefore indefinitely replayable by anyone who ever captures a valid
/// attestation header (server-side logs, a one-off TLS bypass, a future
/// pinning hook). Binding each signature to a context-specific value
/// collapses that window to a single request.
///
/// Four variants, one per authenticated endpoint:
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
/// * `.social(rawNonce:)` — placed on the `exchangeSocial` call for
///   Apple / Google ID-token sign-in. The raw nonce is client-generated
///   per sign-in and also echoed in the provider ID token's `nonce`
///   claim (hashed for Apple, verbatim for Google); server compares the
///   claim against the `bnd` payload and the request-body `idToken.nonce`
///   for a three-way match. Binding to the nonce means a captured
///   attestation for a spent nonce can never satisfy a fresh sign-in,
///   and a captured (idToken, nonce, attestation) triple cannot be
///   replayed from a different device because the SE private key never
///   leaves the device that signed the nonce in the first place.
///
/// * `.signOut(timestamp:)` — placed on the `signOut` call. Same
///   timestamp + skew contract as `.request`; distinct tag prevents a
///   captured `req:` signature from being submitted to the sign-out
///   endpoint (and vice versa). Device-binds the revocation so a leaked
///   bearer token alone cannot invalidate a session without also
///   forging a signature under the original Secure-Enclave key.
///
/// Wire format: the binding renders to a tagged UTF-8 string
/// (`"req:<ts>"`, `"ver:<token>"`, `"sis:<rawNonce>"`, or
/// `"out:<ts>"`) that is both:
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
    case social(rawNonce: String)
    case signOut(timestamp: Int64)

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
        case let .social(rawNonce): "sis:\(rawNonce)"
        case let .signOut(timestamp): "out:\(timestamp)"
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
        if let rawNonce = wireValue.prefixStrippedIfMatches("sis:") {
            guard !rawNonce.isEmpty else {
                throw .attestationFailed("bnd social raw nonce is empty")
            }
            let disallowed = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
            if rawNonce.unicodeScalars.contains(where: disallowed.contains) {
                throw .attestationFailed("bnd social raw nonce contains control characters")
            }
            return .social(rawNonce: rawNonce)
        }
        if let ts = wireValue.prefixStrippedIfMatches("out:") {
            guard let parsed = Int64(ts), parsed > 0, String(parsed) == ts else {
                throw .attestationFailed("bnd sign-out timestamp is not a positive decimal Int64")
            }
            return .signOut(timestamp: parsed)
        }
        throw .attestationFailed("bnd has no recognised tag (expected 'req:', 'ver:', 'sis:', or 'out:')")
    }
}

private extension String {
    func prefixStrippedIfMatches(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
