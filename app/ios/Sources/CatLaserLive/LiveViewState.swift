import Foundation

/// View-model phase for the live-view screen.
///
/// Transitions are linear and explicit — every case corresponds to a
/// distinct UI layout:
///
/// * `.disconnected` — entry state; user can tap "Watch live".
/// * `.requestingOffer` — we've asked the device for a stream; spinner
///   over the placeholder.
/// * `.connecting(credentials)` — we have an offer and are dialling
///   LiveKit; spinner over the placeholder.
/// * `.streaming(track)` — video is live; `LiveView` renders the track
///   and shows a "Stop" button.
/// * `.disconnecting` — user tapped "Stop"; we are issuing the device
///   StopStreamRequest and tearing LiveKit down.
/// * `.failed(error)` — terminal-ish; user can retry (which moves to
///   `.disconnected`) or dismiss.
public enum LiveViewState: Sendable, Equatable {
    case disconnected
    case requestingOffer
    case connecting(LiveStreamCredentials)
    case streaming(any LiveVideoTrackHandle)
    case disconnecting
    case failed(LiveViewError)

    public var isBusy: Bool {
        switch self {
        case .requestingOffer, .connecting, .disconnecting:
            true
        case .disconnected, .streaming, .failed:
            false
        }
    }

    public var canStart: Bool {
        switch self {
        case .disconnected, .failed:
            true
        case .requestingOffer, .connecting, .streaming, .disconnecting:
            false
        }
    }

    public var canStop: Bool {
        switch self {
        case .streaming:
            true
        case .requestingOffer, .connecting, .disconnected, .disconnecting, .failed:
            false
        }
    }

    public static func == (lhs: LiveViewState, rhs: LiveViewState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.requestingOffer, .requestingOffer),
             (.disconnecting, .disconnecting):
            true
        case let (.connecting(a), .connecting(b)):
            a == b
        case let (.streaming(a), .streaming(b)):
            a.trackID == b.trackID
        case let (.failed(a), .failed(b)):
            a == b
        default:
            false
        }
    }
}
