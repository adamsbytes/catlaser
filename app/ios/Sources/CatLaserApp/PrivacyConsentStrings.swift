import Foundation

enum PrivacyConsentStrings {
    static let title = NSLocalizedString(
        "privacy.consent.title",
        value: "Help improve Catlaser",
        comment: "Title on the first-launch privacy consent screen.",
    )
    static let subtitle = NSLocalizedString(
        "privacy.consent.subtitle",
        value: "Choose what you want to share. You can change these any time in Settings.",
        comment: "Subtitle on the privacy consent screen explaining the toggles can be changed later.",
    )

    static let crashToggleTitle = NSLocalizedString(
        "privacy.consent.crashToggle.title",
        value: "Crash reports",
        comment: "Title of the crash-reporting opt-in toggle.",
    )
    static let crashToggleBody = NSLocalizedString(
        "privacy.consent.crashToggle.body",
        value: "Send anonymous crash logs so we can fix problems quickly. No personal data, no cat photos.",
        comment: "Explanation of what the crash-reporting toggle enables.",
    )

    static let telemetryToggleTitle = NSLocalizedString(
        "privacy.consent.telemetryToggle.title",
        value: "Product analytics",
        comment: "Title of the telemetry opt-in toggle.",
    )
    static let telemetryToggleBody = NSLocalizedString(
        "privacy.consent.telemetryToggle.body",
        value: "Share anonymous usage counts (screens opened, features used) so we can improve what matters. Hashed device ID only.",
        comment: "Explanation of what the telemetry toggle enables.",
    )

    static let privacyNote = NSLocalizedString(
        "privacy.consent.privacyNote",
        value: "All data is sent to our own servers — never to third parties. TLS-pinned, device-hashed, stripped of personal identifiers.",
        comment: "Footnote reassuring the user about where data goes.",
    )

    static let continueButton = NSLocalizedString(
        "privacy.consent.continue",
        value: "Continue",
        comment: "Primary button that commits the user's consent choices.",
    )
}
