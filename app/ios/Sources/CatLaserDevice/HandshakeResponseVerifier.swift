#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import CatLaserProto
import Foundation

/// Verifies the Ed25519 signature on an `AuthResponse` against the
/// device's published public key.
///
/// The device side builds a canonical transcript covering the echoed
/// nonce, the signing timestamp, and the accept/reject result plus
/// reason string (see Python
/// `catlaser_brain.auth.handshake_response.build_auth_response_transcript`).
/// Only a party holding the device's Ed25519 private key can produce
/// a signature that verifies under the public key the coordination
/// server returned in the `device_public_key` field of the pair /
/// paired responses. An impostor at the Tailscale endpoint cannot.
///
/// Replay resistance is split across three checks:
///
/// 1. **Nonce echo** — the response must carry the exact 16 bytes the
///    request put in `AuthRequest.nonce`. A signature captured from a
///    previous exchange will not validate because its nonce is from
///    that older exchange.
/// 2. **Timestamp skew** — `signed_at_unix_ns` must be within
///    :data:`maxSkewSeconds` of the local clock. Defends against the
///    vanishingly-unlikely nonce collision (2⁻¹²⁸ per exchange).
/// 3. **Signature verify** — the 64-byte Ed25519 signature must
///    validate over the canonical transcript. Catches every
///    "signature for a different response" attack that slips past the
///    two checks above.
///
/// A failure on any of the three aborts the handshake with a typed
/// :class:`DeviceClientError` case so the caller can distinguish
/// "impostor" from "bad clock" from "nonce collision."
public struct HandshakeResponseVerifier: Sendable {
    /// Raw 32-byte Ed25519 public key from
    /// :property:`PairedDevice.devicePublicKey`. The verifier takes
    /// the raw bytes rather than the Curve25519 handle so the caller
    /// (composition root) owns deserialisation at a single boundary
    /// and test code can construct fixture verifiers from a plain
    /// `Data`.
    public let devicePublicKey: Data

    /// Clock-skew tolerance for ``AuthResponse.signedAtUnixNs``.
    /// Matches the SE-attestation skew window used elsewhere in the
    /// handshake (±5 minutes). Wide enough to absorb drift between
    /// the phone's wall clock and the device's RTC, tight enough
    /// that a recorded-and-replayed response older than five minutes
    /// fails verification even if the attacker somehow steered a
    /// nonce collision.
    public static let maxSkewSeconds: TimeInterval = 300

    /// Domain-separator bytes covered by the signature. Must match
    /// `catlaser_brain.auth.handshake_response.AUTH_RESPONSE_DOMAIN`
    /// byte-for-byte. The trailing `0x00` is load-bearing — it
    /// separates the fixed prefix from the variable-length fields
    /// that follow, preventing an attacker from coercing a different
    /// transcript shape into validating.
    public static let transcriptDomain: [UInt8] = Array("catlaser-auth-response-v1".utf8) + [0]

    public init(devicePublicKey: Data) {
        self.devicePublicKey = devicePublicKey
    }

    /// Validate an ``AuthResponse`` against the request nonce and
    /// local clock reading. Throws a typed
    /// :class:`DeviceClientError` on any rejection; returns normally
    /// on success.
    public func verify(
        response: Catlaser_App_V1_AuthResponse,
        expectedNonce: Data,
        now: Date,
    ) throws(DeviceClientError) {
        // Check the nonce FIRST, before any crypto work. A captured
        // response replayed against a fresh nonce cannot match, and
        // a client bug (forgetting to set the nonce) surfaces with a
        // distinct error rather than a generic signature-invalid.
        let responseNonce = Data(response.nonce)
        guard constantTimeEquals(responseNonce, expectedNonce) else {
            throw .handshakeNonceMismatch
        }

        // Skew check BEFORE signature verify: a stale signature is a
        // replay candidate; rejecting on skew gives the caller a more
        // useful diagnostic (clock drift vs. impostor).
        let signedAt = Double(response.signedAtUnixNs) / 1_000_000_000
        let nowSeconds = now.timeIntervalSince1970
        guard abs(nowSeconds - signedAt) <= Self.maxSkewSeconds else {
            throw .handshakeSkewExceeded
        }

        // Build the transcript the device signed and verify the
        // signature. A failure here is the impostor signal:
        // everything structural matched but the bytes were not
        // actually signed by the device key the coordination
        // server endorsed at pairing.
        let transcript = Self.buildTranscript(
            nonce: expectedNonce,
            signedAtUnixNs: response.signedAtUnixNs,
            ok: response.ok,
            reason: response.reason,
        )
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: devicePublicKey)
        } catch {
            // `PairedDevice` enforces the 32-byte length at decode
            // time, so reaching this branch implies the caller
            // passed an unverified key. Surface as signature-invalid
            // to collapse the entire "we can't verify" class into
            // one error for higher layers.
            throw .handshakeSignatureInvalid
        }
        guard publicKey.isValidSignature(response.signature, for: transcript) else {
            throw .handshakeSignatureInvalid
        }
    }

    /// Construct the canonical bytes the device signs. Exposed so
    /// tests can produce signatures that exercise the full
    /// verification path without reimplementing the layout.
    public static func buildTranscript(
        nonce: Data,
        signedAtUnixNs: Int64,
        ok: Bool,
        reason: String,
    ) -> Data {
        var bytes = Data(capacity: transcriptDomain.count + nonce.count + 8 + 1 + reason.utf8.count)
        bytes.append(contentsOf: transcriptDomain)
        bytes.append(nonce)
        var timestamp = signedAtUnixNs.littleEndian
        withUnsafeBytes(of: &timestamp) { raw in
            bytes.append(contentsOf: raw)
        }
        bytes.append(ok ? 0x01 : 0x00)
        bytes.append(contentsOf: reason.utf8)
        return bytes
    }

    private func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0 ..< a.count {
            diff |= a[a.index(a.startIndex, offsetBy: i)] ^ b[b.index(b.startIndex, offsetBy: i)]
        }
        return diff == 0
    }
}
