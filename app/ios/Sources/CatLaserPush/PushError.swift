import CatLaserDevice
import Foundation

/// Presentable failure modes for the push-notification surface.
///
/// Shape mirrors ``CatLaserHistory.HistoryError`` and
/// ``CatLaserSchedule.ScheduleError``: coarser than the underlying
/// ``DeviceClientError`` because the UI only distinguishes recovery
/// hints (retry, reconnect, re-grant, report). ``from(_:)`` centralises
/// the ``DeviceClientError`` mapping so every call site (register,
/// unregister) renders the same category for the same underlying
/// cause.
public enum PushError: Error, Equatable, Sendable {
    /// The device TCP channel was not open when the registrar tried to
    /// send. The supervisor owns actual reconnection; the registrar
    /// keeps the cached token and re-attempts on the next fresh
    /// `DeviceClient` it sees.
    case notConnected

    /// Transport-level failure mid-request. Retryable.
    case transportFailure(String)

    /// Request timed out waiting on the device. The device MAY still
    /// have executed the register/unregister; the registrar clears its
    /// "currently registered" cache on timeout so the next call
    /// re-issues idempotently (the device's register is an UPSERT, so
    /// a double-register is harmless).
    case timeout

    /// Device responded with a typed ``DeviceError`` payload. Surfaces
    /// the server-assigned code so the UI can special-case known codes
    /// — the device daemon emits `_ERR_UNKNOWN_REQUEST = 2` on an
    /// unsupported ``PushPlatform``; every other push-register failure
    /// is a client bug.
    case deviceError(code: UInt32, message: String)

    /// Device's reply was a oneof branch other than
    /// ``push_token_ack`` — protocol drift between app and device.
    case wrongEventKind(expected: String, got: String)

    /// The user declined OS push authorization. Terminal at the
    /// authorization boundary until the user re-grants in Settings;
    /// the registrar never reaches the wire for a denied session.
    case authorizationDenied

    /// APNs itself refused to register (no network, no
    /// entitlement, no APNs cert on the server side, etc.). Carries
    /// the OS-level diagnostic for the banner.
    case apnsRegistrationFailed(String)

    /// The APNs device token carried fewer than
    /// ``PushToken.minimumLength`` bytes or exceeded
    /// ``PushToken.maximumLength``. APNs tokens are currently 32
    /// bytes; the registrar refuses to send anything that would not
    /// round-trip through the device's SQLite `TEXT` column or through
    /// the FCM messaging API. Wire traffic is skipped — the registrar
    /// keeps the old cached token (if any) so the next valid token
    /// lands cleanly.
    case invalidToken(reason: String)

    /// Catch-all for client-side internal errors (encoding glitches,
    /// logic bugs). Kept distinct from ``transportFailure`` so
    /// observability can distinguish network blips from client bugs
    /// without scraping wrapped strings.
    case internalFailure(String)

    /// Lift a ``DeviceClientError`` into the push-surface error
    /// space. Classification mirrors the history / schedule modules'
    /// precedent so a transient blip surfaces identically on every
    /// screen.
    public static func from(_ clientError: DeviceClientError) -> PushError {
        switch clientError {
        case .notConnected, .closedByPeer:
            .notConnected
        case let .connectFailed(reason), let .transport(reason):
            .transportFailure(reason)
        case .requestTimedOut:
            .timeout
        case let .remote(code, message):
            .deviceError(code: code, message: message)
        case let .malformedFrame(reason), let .encodingFailed(reason):
            .internalFailure(reason)
        case let .frameTooLarge(length, limit):
            .internalFailure("frame too large: \(length) bytes (limit \(limit))")
        case let .wrongEventKind(expected, got):
            .wrongEventKind(expected: expected, got: got)
        case .alreadyConnected:
            .internalFailure("device client already connected")
        case .cancelled:
            .internalFailure("cancelled")
        case let .handshakeFailed(reason):
            // Collapse to ``transportFailure`` so the supervisor's
            // re-pair flow owns the recovery path. At this layer the
            // user sees "can't talk to the device right now."
            .transportFailure("device-auth handshake rejected: \(reason)")
        case let .authRevoked(message):
            .transportFailure("access revoked: \(message)")
        case .handshakeNonceMismatch,
             .handshakeSkewExceeded,
             .handshakeSignatureInvalid:
            .transportFailure("device handshake verification failed")
        case .handshakeVerifierMissing:
            .internalFailure("handshake verifier missing")
        }
    }
}
