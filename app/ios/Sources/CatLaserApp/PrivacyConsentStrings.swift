import Foundation

enum PrivacyConsentStrings {
    static let title = NSLocalizedString(
        "privacy.consent.title",
        value: "Help improve Catlaser",
        comment: "Title on the first-launch privacy consent screen.",
    )
    static let subtitle = NSLocalizedString(
        "privacy.consent.subtitle",
        value: "Both are off by default — turn on what you're comfortable sharing. You can change these any time in Settings.",
        comment: "Subtitle on the privacy consent screen; names the opt-out-by-default posture and notes the toggles can be changed later.",
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
        value: "Your cat data never leaves our servers. We verify every connection, keep the camera feed on your home network, and collect less than almost every app on your phone.",
        comment: "Hero privacy sentence shown beneath the consent toggles.",
    )

    static let privacyInfoAccessibilityLabel = NSLocalizedString(
        "privacy.consent.info.accessibility",
        value: "What makes this private",
        comment: "VoiceOver label for the info button that opens the privacy details sheet.",
    )

    static let privacyDetailsTitle = NSLocalizedString(
        "privacy.consent.details.title",
        value: "What makes this private",
        comment: "Title for the sheet shown when the user taps the privacy info icon.",
    )

    static let privacyDetailsBody = NSLocalizedString(
        "privacy.consent.details.body",
        value:
            "Here's exactly what we do and don't do with your data.",
        comment: "Intro paragraph on the privacy details sheet.",
    )

    static let privacyDetailsTlsTitle = NSLocalizedString(
        "privacy.consent.details.tls.title",
        value: "Every connection is verified",
        comment: "Heading for the TLS-pinning bullet on the privacy details sheet.",
    )

    static let privacyDetailsTlsBody = NSLocalizedString(
        "privacy.consent.details.tls.body",
        value: "Your phone checks our servers' identity on every request using a technique called certificate pinning. If anyone tried to sit in the middle of the connection, the app would refuse to talk to them.",
        comment: "Body copy for the TLS-pinning bullet on the privacy details sheet.",
    )

    static let privacyDetailsLocalTitle = NSLocalizedString(
        "privacy.consent.details.local.title",
        value: "The camera feed stays home",
        comment: "Heading for the local-network bullet on the privacy details sheet.",
    )

    static let privacyDetailsLocalBody = NSLocalizedString(
        "privacy.consent.details.local.body",
        value: "Live video between your Catlaser and your phone runs over a private network (Tailscale). The feed never crosses our servers, even when you're watching remotely.",
        comment: "Body copy for the local-network bullet on the privacy details sheet.",
    )

    static let privacyDetailsNoTrackersTitle = NSLocalizedString(
        "privacy.consent.details.no_trackers.title",
        value: "No third-party trackers",
        comment: "Heading for the no-third-parties bullet on the privacy details sheet.",
    )

    static let privacyDetailsNoTrackersBody = NSLocalizedString(
        "privacy.consent.details.no_trackers.body",
        value: "We don't embed analytics, ad networks, or fingerprinting SDKs from anyone else. Every bit of data the app sends goes only to our servers.",
        comment: "Body copy for the no-third-parties bullet on the privacy details sheet.",
    )

    static let privacyDetailsMinimalTitle = NSLocalizedString(
        "privacy.consent.details.minimal.title",
        value: "We collect less than almost every app",
        comment: "Heading for the minimal-data bullet on the privacy details sheet.",
    )

    static let privacyDetailsMinimalBody = NSLocalizedString(
        "privacy.consent.details.minimal.body",
        value: "No location data. No contacts. No ads. No fingerprinting. Crash reports and anonymous usage counts only if you turn the toggles above ON — both default to OFF.",
        comment: "Body copy for the minimal-data bullet on the privacy details sheet.",
    )

    static let privacyDetailsDone = NSLocalizedString(
        "privacy.consent.details.done",
        value: "Done",
        comment: "Button that dismisses the privacy details sheet.",
    )

    static let continueButton = NSLocalizedString(
        "privacy.consent.continue",
        value: "Continue",
        comment: "Primary button that commits the user's consent choices.",
    )
}
