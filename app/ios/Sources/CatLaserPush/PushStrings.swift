import Foundation

/// Localised strings for the push-notification surface.
///
/// Pattern mirrors ``HistoryStrings`` and ``ScheduleStrings``:
/// every string has a stable ``NSLocalizedString`` key, an English
/// default, and a one-line ``comment``. Tests assert that every
/// ``PushError`` case resolves to a non-empty string so a refactor
/// that adds a new case without a localisation row fails loudly.
public enum PushStrings {
    // MARK: - Primer / pre-prompt copy

    public static let primerTitle = NSLocalizedString(
        "push.primer.title",
        value: "Stay in the loop",
        comment: "Title shown on the push-notification primer screen before the OS permission prompt.",
    )

    public static let primerBody = NSLocalizedString(
        "push.primer.body",
        value: "Get a notification when a play session ends, a new cat is spotted, or the treat hopper runs low.",
        comment: "Body copy on the push-notification primer screen.",
    )

    public static let primerAllowButton = NSLocalizedString(
        "push.primer.allow",
        value: "Turn on notifications",
        comment: "Primary button on the push-notification primer screen — triggers the OS permission prompt.",
    )

    public static let primerLaterButton = NSLocalizedString(
        "push.primer.later",
        value: "Not now",
        comment: "Dismiss button on the push-notification primer screen.",
    )

    // MARK: - Postponed (user tapped "Not now")

    public static let postponedTitle = NSLocalizedString(
        "push.postponed.title",
        value: "Notifications are off",
        comment: "Title shown after the user tapped \"Not now\" on the primer.",
    )

    public static let postponedBody = NSLocalizedString(
        "push.postponed.body",
        value: "Turn them on any time from here.",
        comment: "Body copy on the postponed push-notification pane, pointing the user at the re-engage button.",
    )

    public static let postponedTurnOnButton = NSLocalizedString(
        "push.postponed.turn_on",
        value: "Turn on notifications",
        comment: "Button on the postponed pane that re-opens the primer and triggers the OS permission prompt.",
    )

    // MARK: - In-flight state copy

    public static let awaitingTokenLabel = NSLocalizedString(
        "push.state.awaiting_token",
        value: "Connecting to Apple's push service…",
        comment: "Spinner label while the app waits for APNs to hand back a device token.",
    )

    public static let registeringLabel = NSLocalizedString(
        "push.state.registering",
        value: "Telling your device you're ready to hear from it…",
        comment: "Spinner label while the app is registering the push token with the paired device.",
    )

    public static let registeredTitle = NSLocalizedString(
        "push.state.registered.title",
        value: "You're all set",
        comment: "Title shown once the push token has been registered with the paired device.",
    )

    public static let registeredBody = NSLocalizedString(
        "push.state.registered.body",
        value: "The Cat Laser will ping you when something happens.",
        comment: "Body copy shown once the push token has been registered with the paired device.",
    )

    public static let deniedTitle = NSLocalizedString(
        "push.state.denied.title",
        value: "Notifications are off",
        comment: "Title shown when OS push authorization was denied.",
    )

    public static let deniedBody = NSLocalizedString(
        "push.state.denied.body",
        value: "You can re-enable them in iOS Settings whenever you'd like.",
        comment: "Body copy shown when OS push authorization was denied.",
    )

    public static let openSettingsButton = NSLocalizedString(
        "push.state.denied.settings",
        value: "Open Settings",
        comment: "Button that deep-links into the iOS Settings app for this app's notification settings.",
    )

    public static let retryButton = NSLocalizedString(
        "push.retry",
        value: "Try again",
        comment: "Retry button on the push-notification failure banner.",
    )

    public static let errorBannerTitle = NSLocalizedString(
        "push.error.title",
        value: "Couldn't turn on notifications",
        comment: "Title for the error banner on the push-notification screen.",
    )

    /// Render a ``PushError`` into a human-readable message. The
    /// underlying technical detail (OS messages, APNs reason codes,
    /// transport strings) deliberately does NOT leak into the
    /// user-facing string — those values belong in logs, not banners.
    public static func message(for error: PushError) -> String {
        switch error {
        case .notConnected:
            return NSLocalizedString(
                "push.error.not_connected",
                value: "Your phone isn't connected to the device. We'll try again once the connection is back.",
                comment: "Error shown when the device TCP channel is closed during push registration.",
            )
        case .transportFailure:
            return NSLocalizedString(
                "push.error.transport",
                value: "The connection to your device dropped. Please try again.",
                comment: "Error shown when the device TCP channel errored mid-registration.",
            )
        case .timeout:
            return NSLocalizedString(
                "push.error.timeout",
                value: "The device didn't respond in time. Please try again.",
                comment: "Error shown when the push registration timed out.",
            )
        case let .deviceError(_, message):
            return message.isEmpty ? genericMessage : message
        case .wrongEventKind:
            return NSLocalizedString(
                "push.error.protocol",
                value: "The device returned an unexpected response. Please try again.",
                comment: "Error shown when the device's reply oneof did not match push_token_ack.",
            )
        case .authorizationDenied:
            // Should not reach this path from the error banner — the
            // screen has a dedicated denied state — but we provide a
            // localised fallback so a future code path that surfaces
            // it in the banner renders non-empty.
            return NSLocalizedString(
                "push.error.denied",
                value: "Notifications are turned off in iOS Settings.",
                comment: "Fallback message for the authorizationDenied error case.",
            )
        case .apnsRegistrationFailed:
            return NSLocalizedString(
                "push.error.apns",
                value: "Apple's push service couldn't register this device right now. Please try again later.",
                comment: "Error shown when APNs itself refused to register the device.",
            )
        case .invalidToken:
            return NSLocalizedString(
                "push.error.invalid_token",
                value: "Apple sent a token we couldn't use. Please try again later.",
                comment: "Error shown when the APNs token was too short, too long, or malformed.",
            )
        case .internalFailure:
            return genericMessage
        }
    }

    private static let genericMessage = NSLocalizedString(
        "push.error.generic",
        value: "Something went wrong while turning on notifications. Please try again.",
        comment: "Generic error message on the push-notification screen.",
    )
}
