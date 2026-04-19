import CatLaserDevice
import Foundation

/// Presentable failure modes for the schedule setup screen.
///
/// The shape mirrors ``CatLaserHistory.HistoryError``: coarser than
/// ``DeviceClientError`` because the UI only distinguishes the
/// failure modes that drive different recovery hints (retry,
/// reconnect, re-pair, fix input). Adding a new case means the UI
/// gains a new banner; mapping trivia lives in
/// ``ScheduleError/from(_:)`` so every call site renders the same
/// error identically.
public enum ScheduleError: Error, Equatable, Sendable {
    /// Device TCP channel was closed when the user opened the
    /// screen or hit save. Indicates a connectivity hiccup at the
    /// host; the supervisor owns actual reconnection and the UI
    /// surfaces a passive hint.
    case notConnected

    /// Transport error mid-request (connect failed, TCP dropped).
    /// Retryable once the network comes back.
    case transportFailure(String)

    /// Request timed out waiting on the device. Distinct from
    /// ``transportFailure`` because the device MAY still have
    /// executed the write: the UI surfaces a "please verify" hint
    /// on the next refresh.
    case timeout

    /// The device responded with a typed ``DeviceError`` payload.
    /// Carries the server-assigned code so the UI can special-case
    /// known codes (none currently, but the typed surface means a
    /// future schedule-specific error code lands with a matching
    /// banner).
    case deviceError(code: UInt32, message: String)

    /// The device's reply was a oneof branch the screen did not
    /// expect — protocol drift between app and device.
    case wrongEventKind(expected: String, got: String)

    /// Caller-side validation refused the draft before any wire
    /// traffic. Carries a ``ScheduleValidation/Failure`` so the UI
    /// can surface a field-level hint.
    case validation(ScheduleValidation.Failure)

    /// Catch-all for failure modes outside the device layer —
    /// encoding glitches, client-side invariant violations. Kept
    /// distinct from ``transportFailure`` so observability can
    /// tell "network blip" from "client bug" without scraping the
    /// wrapped string.
    case internalFailure(String)

    /// Lift a ``DeviceClientError`` into the screen-level error
    /// surface. Every mapping follows the history screen's
    /// precedent — a single place where classification happens so
    /// individual call sites never embed the logic. Handshake and
    /// auth-revoked errors collapse to ``transportFailure``
    /// because the supervisor in ``ConnectionManager`` owns the
    /// re-pair routing; at this layer the user just needs "can't
    /// talk to the device right now" + a retry button.
    public static func from(_ clientError: DeviceClientError) -> ScheduleError {
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
