import CatLaserDevice
import Foundation

/// Presentable failure modes for the history + cat profiles screen.
///
/// The category granularity is intentionally coarser than the underlying
/// ``DeviceClientError``: tests assert on a category, not on every
/// possible wrapped string. Each case maps to a single user-visible
/// message in ``HistoryStrings/message(for:)`` and a single recovery
/// hint (retry / reconnect / re-pair).
public enum HistoryError: Error, Equatable, Sendable {
    /// The device TCP channel was not open when the user opened the
    /// screen or tapped a button. Indicates a pairing / connectivity
    /// hiccup at the host; the UI surfaces a "reconnect" hint and the
    /// supervisor handles the actual reconnect.
    case notConnected

    /// The device TCP channel failed mid-request. Retry typically works
    /// once network comes back.
    case transportFailure(String)

    /// The device request timed out. Distinct from ``transportFailure``
    /// because the side-effect may still have executed: the UI prompts
    /// retry but a delete-cat retry is an idempotent re-issue (the
    /// device's `delete_cat` is a no-op on a missing row).
    case timeout

    /// The device responded with a typed ``DeviceError``. Carries the
    /// server-assigned code so the UI can special-case known codes
    /// (currently `4 = NOT_FOUND` from the device handler).
    case deviceError(code: UInt32, message: String)

    /// The named cat (or pending track id) does not exist on the
    /// device. Distinct from ``deviceError`` so the UI can render a
    /// "this cat was already removed — refreshing" message rather than
    /// a generic error banner. Folded out of `deviceError(code: 4, ...)`
    /// by ``from(_:)`` so callers do not need to know the wire code.
    case notFound(String)

    /// The device replied with a oneof branch other than the one this
    /// request expected. Indicates a protocol drift between app and
    /// device — surface enough detail to triage from logs without
    /// dumping the raw event into the UI.
    case wrongEventKind(expected: String, got: String)

    /// Caller-side validation refused the input before any wire
    /// traffic — typically an empty / whitespace-only cat name. Carries
    /// the rejection reason so the field-level UI can render a precise
    /// hint.
    case validation(String)

    /// Catch-all for failure modes outside the device layer (encoding
    /// glitches, internal logic errors). Surfaced separately from
    /// ``transportFailure`` so observability can distinguish "network
    /// blip" from "client bug" without inspecting the wrapped string.
    case internalFailure(String)

    /// Lift a ``DeviceClientError`` into the screen-level error space.
    /// Centralising the mapping here means every caller (cat list,
    /// edit, delete, identify-new, history load) renders the same
    /// presentation for the same underlying cause.
    public static func from(_ clientError: DeviceClientError) -> HistoryError {
        switch clientError {
        case .notConnected, .closedByPeer:
            .notConnected
        case let .connectFailed(reason), let .transport(reason):
            .transportFailure(reason)
        case .requestTimedOut:
            .timeout
        case let .remote(code, message):
            // Code 4 is `_ERR_NOT_FOUND` in
            // `python/catlaser_brain/network/handler.py`. Folding it
            // into a typed case here keeps the UI free of magic
            // numbers.
            code == HistoryError.notFoundCode
                ? .notFound(message)
                : .deviceError(code: code, message: message)
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
            // re-pair / clock-sync messaging owns the actual
            // recovery surface — at this layer the user just sees
            // "can't talk to the device right now."
            .transportFailure("device-auth handshake rejected: \(reason)")
        case let .authRevoked(message):
            // Terminal at the connection-supervisor layer. By the time
            // the history screen sees this, ``ConnectionManager`` is
            // already routing the user back to the pairing flow.
            .transportFailure("access revoked: \(message)")
        case .handshakeNonceMismatch,
             .handshakeSkewExceeded,
             .handshakeSignatureInvalid:
            .transportFailure("device handshake verification failed")
        case .handshakeVerifierMissing:
            .internalFailure("handshake verifier missing")
        }
    }

    /// Wire constant mirrored from the device handler's
    /// `_ERR_NOT_FOUND` code. Lives on the type so the
    /// ``DeviceClientError.remote`` → ``HistoryError`` mapping does
    /// not embed the magic value inline. A change to the device-side
    /// constant is a cross-stack break that both ends must land
    /// atomically.
    public static let notFoundCode: UInt32 = 4
}
