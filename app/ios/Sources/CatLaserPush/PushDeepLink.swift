import Foundation

/// Typed screen route a tapped push notification resolves to.
///
/// The app composition-root consumes a ``PushDeepLink`` to drive tab
/// switches or sheet presentations. Keeping the mapping out of the UI
/// layer (and centralised in this enum) means tests can assert the
/// route for every payload type without spinning up a SwiftUI host.
///
/// The mapping is intentionally conservative: every unknown or
/// ambiguous payload maps to ``home``, never to a destructive or
/// presence-sensitive screen. A malformed push must not surface live
/// video or dispense controls just because the attacker guessed the
/// right `type` string.
public enum PushDeepLink: Sendable, Equatable {
    /// App's default / home screen. Used for unknown payloads and for
    /// the "session summary" notification (where "go to home" means
    /// "continue what you were doing, summary is already in the
    /// banner").
    case home

    /// Open the history + cat-profiles screen. The user tapped a
    /// ``new_cat_detected`` push; the naming prompt for that track
    /// arrives on the device-channel events stream when the app
    /// connects, so routing to history surfaces the sheet naturally.
    case history

    /// Open the device-status / hopper screen. The user tapped a
    /// ``hopper_empty`` push; the app should land on the refill
    /// instructions rather than live video so they can see what to
    /// do.
    case hopperStatus

    /// Open the live-view screen. The user tapped a
    /// ``session_started`` push — they want to watch the session
    /// that just began.
    case liveView

    /// Derive the deep-link route for a parsed payload.
    public static func route(for payload: PushNotificationPayload) -> PushDeepLink {
        switch payload {
        case .sessionSummary:
            // Summary is shown in the banner itself; the most
            // predictable tap-through is "home" where the user can
            // pick their next action.
            .home
        case .sessionStarted:
            .liveView
        case .hopperEmpty:
            .hopperStatus
        case .newCatDetected:
            .history
        case .unknown:
            .home
        }
    }
}
