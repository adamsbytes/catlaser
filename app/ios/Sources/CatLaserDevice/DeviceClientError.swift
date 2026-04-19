import Foundation

/// Failure modes for `DeviceClient`.
///
/// All surfaced errors fall into one of these cases. Each exists
/// because a caller needs to tell it apart from the others — the
/// recovery actions differ:
///
/// * `.notConnected` — caller should open the connection first.
/// * `.connectFailed` / `.transport` — network-layer problem; retry
///   with backoff once the app regains network.
/// * `.closedByPeer` — server dropped the connection cleanly; reopen
///   and continue.
/// * `.malformedFrame` / `.frameTooLarge` / `.encodingFailed` — wire
///   invariant broken; the connection is already torn down, tear down
///   any higher-level state too.
/// * `.requestTimedOut` — the response never arrived; the device may
///   still have executed the side-effect; caller decides whether to
///   retry (idempotency at this level is per-route).
/// * `.remote` — the device responded with a `DeviceError` payload;
///   caller inspects `code`/`message` to decide what to show.
/// * `.wrongEventKind` — response arrived but its oneof branch didn't
///   match what the caller asked for; a protocol bug on either side.
/// * `.handshakeFailed` — the mandatory first-frame device-auth
///   handshake was rejected. Carries the `DEVICE_AUTH_*` reason string
///   emitted by the device daemon (matches
///   `catlaser_brain.auth.handshake.HandshakeReason`). Actionable by
///   the caller: `DEVICE_AUTH_NOT_AUTHORIZED` / `DEVICE_AUTH_ACL_NOT_READY`
///   mean re-pair; `DEVICE_AUTH_SKEW_EXCEEDED` means sync the clock;
///   anything else is a client bug or a captured-replay attempt.
/// * `.authRevoked` — the device daemon sent a terminal
///   `DeviceError { code: AUTH_REVOKED }` frame because the ACL poller
///   dropped this user's SPKI from the device's allowed set. Distinct
///   from `.handshakeFailed` because the revocation arrives on an
///   already-authorized connection rather than during the initial
///   handshake: the caller must treat it as "re-pair required, do NOT
///   retry on the same endpoint." Carries the server-provided message
///   for diagnostics.
public enum DeviceClientError: Error, Equatable, Sendable {
    case notConnected
    case alreadyConnected
    case connectFailed(String)
    case transport(String)
    case closedByPeer
    case malformedFrame(String)
    case frameTooLarge(length: Int, limit: Int)
    case encodingFailed(String)
    case requestTimedOut
    case cancelled
    case remote(code: UInt32, message: String)
    case wrongEventKind(expected: String, got: String)
    case handshakeFailed(reason: String)
    case authRevoked(message: String)
    /// `connect(handshake:)` was called with a non-nil handshake builder
    /// but the client was constructed without a `responseVerifier`. This
    /// is a programmer error: a production handshake without a
    /// signature-verification step would silently accept a forged
    /// `AuthResponse` from any party that can speak the wire framing
    /// against the Tailscale endpoint, defeating the entire
    /// impostor-at-the-endpoint defense. The runtime guard is a
    /// belt-and-braces check on top of the composition-root invariant
    /// that always wires both — surfaced as a typed error so a refactor
    /// that drops the verifier crashes loudly on the first connect
    /// attempt instead of silently weakening the security posture.
    case handshakeVerifierMissing
    /// The device's AuthResponse carried a `nonce` that did not
    /// match the 16 bytes the app sent in its AuthRequest. A live
    /// device echoes the challenge verbatim; a mismatch means an
    /// impostor replayed a signature captured from a previous
    /// exchange — the only defence is to tear the connection down.
    /// Treated as terminal-retry (reconnect-with-backoff): the next
    /// attempt uses a fresh nonce that the attacker cannot have
    /// anticipated.
    case handshakeNonceMismatch
    /// The device's AuthResponse verified structurally but the
    /// `signed_at_unix_ns` timestamp was outside the ±5-minute
    /// acceptance window. Defends against long-lived replay of a
    /// captured AuthResponse against a nonce collision.
    case handshakeSkewExceeded
    /// The device's Ed25519 signature over the AuthResponse
    /// transcript failed to verify against the public key the
    /// coordination server published at pairing time. An impostor
    /// at the Tailscale endpoint; tear the connection down and do
    /// NOT retry against the same endpoint without re-pairing.
    case handshakeSignatureInvalid

    /// Server-side ``DeviceError.code`` value the device daemon emits
    /// on the last frame of an ACL-revoked session, mirroring
    /// `ERR_AUTH_REVOKED` in `catlaser_brain.network.server`. The
    /// constant lives here so the app and the daemon cannot drift —
    /// a change to this number is a cross-stack breaking change that
    /// both sides must land atomically.
    public static let authRevokedCode: UInt32 = 1001

    /// `DEVICE_AUTH_NOT_AUTHORIZED` reason string — the device rejects
    /// the first-frame handshake because the signer's SPKI is not in
    /// the current ACL snapshot. Matches
    /// `catlaser_brain.auth.handshake.HandshakeReason.NOT_AUTHORIZED`.
    /// Shared as a typed constant so the terminal-failure classifier
    /// does not rely on a magic string.
    public static let handshakeReasonNotAuthorized = "DEVICE_AUTH_NOT_AUTHORIZED"

    /// `DEVICE_AUTH_REPLAY_DETECTED` reason string — the device rejects
    /// a first-frame handshake whose exact `(spki, timestamp,
    /// signature)` tuple was already consumed within the server's
    /// replay-cache TTL. Mirrors
    /// `catlaser_brain.auth.handshake.HandshakeReason.REPLAY_DETECTED`.
    ///
    /// Deliberately **not** terminal: an honest client never collides
    /// with itself under ECDSA-P256-SHA256 (the random `k` makes every
    /// signing op produce a distinct signature), so if this reason
    /// reaches the client the on-path attacker beat us to the server
    /// with our own captured bytes. The supervisor's next reconnect
    /// signs a fresh attestation with a fresh `k` — the collision is
    /// not reproducible without the SE private key — and the retry
    /// succeeds. Kept out of `isTerminalAuthRevocation` so the normal
    /// transient-failure backoff path handles it.
    public static let handshakeReasonReplayDetected = "DEVICE_AUTH_REPLAY_DETECTED"

    /// True if this error indicates the device side permanently no
    /// longer considers the current user authorized. Two distinct
    /// wire signals map here:
    ///
    /// * `.authRevoked` — the daemon force-closed an already-open
    ///   session after an ACL snapshot removed this user's SPKI.
    /// * `.handshakeFailed(reason:)` with reason
    ///   `DEVICE_AUTH_NOT_AUTHORIZED` — the first reconnect attempt
    ///   after revocation dies in the handshake because the ACL
    ///   already reflects the revocation.
    ///
    /// Both cases must NOT be retried on the same endpoint — the
    /// correct behaviour is to unpair locally and route the user
    /// back through the pairing flow. Transient states
    /// (`DEVICE_AUTH_ACL_NOT_READY`, `DEVICE_AUTH_SKEW_EXCEEDED`,
    /// transport drops) are explicitly excluded so ordinary
    /// reconnect-and-retry semantics still apply to them.
    public var isTerminalAuthRevocation: Bool {
        switch self {
        case .authRevoked:
            true
        case let .handshakeFailed(reason):
            reason == Self.handshakeReasonNotAuthorized
        default:
            false
        }
    }

    /// Human-readable message for a terminal auth-revocation error.
    /// Returns the wrapped message for both `.authRevoked(message:)`
    /// and `.handshakeFailed(reason:)`; nil for any other case.
    /// `ConnectionManager` threads this into `PairingError.authRevoked`
    /// so the UI has a non-empty reason to show.
    public var authRevokedMessage: String {
        switch self {
        case let .authRevoked(message):
            message
        case let .handshakeFailed(reason):
            reason
        default:
            ""
        }
    }
}
