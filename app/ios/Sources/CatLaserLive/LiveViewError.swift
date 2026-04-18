import CatLaserDevice
import Foundation

/// Presentable failure modes for the live-view screen.
///
/// Each case maps to a distinct user-facing message and recovery
/// hint. The categories are intentionally coarser than the underlying
/// `DeviceClientError` — tests assert on a category, not on every
/// possible wrapped string.
public enum LiveViewError: Error, Equatable, Sendable {
    /// The device replied with a `DeviceError`. Carries the
    /// server-assigned code so the UI can special-case known codes
    /// (e.g. "stream already active").
    case deviceError(code: UInt32, message: String)

    /// The device replied with something other than `stream_offer` —
    /// a protocol bug.
    case streamOfferMissing

    /// The `StreamOffer` contents were malformed (empty URL, bad
    /// scheme, empty token). The server is supposed to guard this
    /// already, but we check before dialling LiveKit.
    case streamOfferInvalid(LiveStreamCredentialsError)

    /// The device TCP channel was not connected when the user tapped
    /// "Watch live". Indicates a pairing / connectivity bug in the
    /// host; surfaced so the UI can prompt a reconnect.
    case notConnected

    /// The device TCP channel failed during the request/response
    /// round-trip. Retry typically works once network comes back.
    case transportFailure(String)

    /// The device request timed out.
    case timeout

    /// LiveKit connect / subscribe failed.
    case streamConnectFailed(String)

    /// The LiveKit server dropped the stream after we connected.
    case streamDropped(String?)

    /// The network underneath LiveKit failed mid-stream.
    case networkFailure(String?)

    /// The pre-stream user-presence gate refused the stream (biometric
    /// unavailable, lockout, repeated failures — anything other than a
    /// plain user cancellation, which returns silently to `.disconnected`
    /// rather than landing on a `.failed` banner).
    case authenticationRequired(String)

    /// Catch-all for errors outside the device or LiveKit layers.
    case internalFailure(String)

    /// Lift a `DeviceClientError` into the view-level error space.
    /// Centralised here so every caller renders the same message for
    /// the same underlying cause.
    static func from(_ clientError: DeviceClientError) -> LiveViewError {
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
            .internalFailure("expected \(expected), got \(got)")
        case .alreadyConnected:
            .internalFailure("device client already connected")
        case .cancelled:
            .internalFailure("cancelled")
        case let .handshakeFailed(reason):
            // A rejected device-auth handshake collapses to
            // `.notConnected` with the reason embedded so the UI
            // can surface "re-pair" vs "clock sync" messaging. The
            // view-level distinction between a missing session and
            // a failed handshake is not load-bearing — both mean
            // "can't talk to the device right now."
            .transportFailure("device-auth handshake rejected: \(reason)")
        case let .authRevoked(message):
            // Terminal revocation at the live-view layer surfaces as
            // a transport failure for the VM's error banner. The
            // actual unpair + re-pair flow is owned by
            // `PairingViewModel`, which observes the connection
            // manager's terminal `.failed(.authRevoked)` state and
            // handles keychain wipe and routing automatically — by
            // the time the live-view sees this error the pairing
            // flow has already started.
            .transportFailure("access revoked: \(message)")
        }
    }
}
