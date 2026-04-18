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
