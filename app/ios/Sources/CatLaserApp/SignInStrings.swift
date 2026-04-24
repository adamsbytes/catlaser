import CatLaserAuth
import Foundation

/// User-facing strings and `AuthError` → presentable-message mapping.
///
/// Kept as constants (not Localizable.strings keys) at this stage because
/// the iOS app ships English-only for v1 per the product brief; when
/// localization lands, swap each constant for `String(localized:)` with
/// a stable key and move this file into a module-scoped
/// `String.LocalizationValue` table.
///
/// Error messages deliberately do not echo the `AuthError`'s associated
/// value (server messages, OSStatus codes, provider-side stack
/// fragments) — those belong in logs, not in UI. Each user-facing
/// message is a plain-language remediation hint; operators read the
/// structured error through logging and observability, not the banner.
public enum SignInStrings {
    public static let title = "Welcome to Catlaser"
    public static let subtitle = "Sign in to pair your device."
    public static let appleButton = "Sign in with Apple"
    public static let googleButton = "Continue with Google"
    public static let emailButton = "Continue with email"
    public static let dividerLabel = "or"
    public static let emailSheetTitle = "Sign in by email"
    /// Pre-send body copy on the email-entry sheet. The value-
    /// proposition framing belongs HERE, before the link has been
    /// sent; the post-send expiry-warning ``emailSentHint`` belongs
    /// on the confirmation view only.
    public static let emailSheetPrompt =
        "One-tap sign-in. We'll email you a link — no password needed."
    public static let emailFieldLabel = "Email"
    public static let emailFieldPlaceholder = "you@example.com"
    public static let emailSendButton = "Send sign-in link"
    public static let emailSendingButton = "Sending…"
    public static let emailInvalid = "Enter a valid email address."
    public static let emailSentTitle = "Check your email"
    public static let emailSentHint =
        "Open the link on this device to finish signing in. The link expires after a few minutes."
    public static let resendButton = "Resend link"
    public static let useDifferentEmailButton = "Use a different email"
    public static let dismissButton = "Dismiss"
    public static let retryButton = "Try again"
    public static let cancelButton = "Cancel"
    public static let errorBannerTitle = "Sign-in failed"

    /// Title shown on the full-screen cover when a Universal Link is
    /// being verified against the server (cold start off a tapped
    /// email link, or the in-session transition). Without this cover
    /// the sign-in buttons stay visible and tappable while the
    /// verification is running; users had no feedback that their tap
    /// on the email link had done anything.
    public static let verifyingMagicLinkTitle = "Signing you in…"
    public static let verifyingMagicLinkSubtitle =
        "Checking your sign-in link. This usually takes a moment."

    public static func emailSentBody(_ address: String) -> String {
        "We sent a sign-in link to \(address)."
    }

    // MARK: - Backup code

    /// Prompt above the backup-code field on the "check your email"
    /// screen. Frames the code as the cross-device escape hatch rather
    /// than the primary path — the vast majority of users tap the link
    /// on the phone that requested it.
    public static let backupCodePrompt = NSLocalizedString(
        "signin.backupCode.prompt",
        value: "Reading email on a different device?",
        comment: "Section header shown above the 6-digit backup-code field.",
    )

    public static let backupCodeHint = NSLocalizedString(
        "signin.backupCode.hint",
        value: "Enter the 6-digit code from the email to finish signing in on this phone.",
        comment: "Body copy that tells the user to use the backup code when email is on another device.",
    )

    public static let backupCodeFieldLabel = NSLocalizedString(
        "signin.backupCode.field",
        value: "6-digit code",
        comment: "Accessibility label for the backup-code text field.",
    )

    public static let backupCodePlaceholder = NSLocalizedString(
        "signin.backupCode.placeholder",
        value: "123 456",
        comment: "Placeholder shown inside the empty backup-code text field.",
    )

    public static let backupCodeSubmitButton = NSLocalizedString(
        "signin.backupCode.submit",
        value: "Sign in with code",
        comment: "Primary action beneath the backup-code field.",
    )

    public static let backupCodeSubmittingLabel = NSLocalizedString(
        "signin.backupCode.submitting",
        value: "Signing in…",
        comment: "In-flight label shown while the backup-code round-trip is running.",
    )

    public static let backupCodeInvalid = NSLocalizedString(
        "signin.backupCode.invalid",
        value: "Enter the 6-digit code from the email.",
        comment: "Validation message when the backup-code input is not 6 digits.",
    )

    /// Map an `AuthError` to a user-presentable message. Does not include
    /// the underlying server / OS message: those values are developer
    /// artefacts that would leak implementation detail and potentially
    /// PII (email fragments, usernames) into the UI surface.
    public static func message(for error: AuthError) -> String {
        switch error {
        case .cancelled:
            return "Sign-in was cancelled."
        case .credentialInvalid:
            return "We couldn't sign you in with that account. Try again."
        case .missingIDToken, .missingBearerToken, .malformedResponse, .idTokenClaimMismatch:
            return "We got an unexpected response. Try again in a moment."
        case .network:
            return "You appear to be offline. Check your connection and try again."
        case let .serverError(status, _):
            return status >= 500
                ? "Our servers are having trouble. Try again in a minute or two."
                : "We couldn't sign you in. Try again."
        case .keychain:
            return "Your phone couldn't save your sign-in. Try again in a moment."
        case .providerUnavailable:
            return "That sign-in option isn't available on this phone."
        case .providerInternal:
            return "Something went wrong while signing in. Try again."
        case .invalidEmail:
            return "Enter a valid email address."
        case .invalidMagicLink:
            return "This sign-in link or code isn't working. It may have expired or already been used — request a fresh one."
        case .attestationFailed:
            return "Something on your phone is blocking sign-in. Restart your phone and try again."
        case .secureEnclaveUnavailable:
            return "Your phone's security features are turned off. Set up Face ID or a passcode in Settings, then try again."
        case .invalidRedirectURL:
            return "Sign-in is misconfigured on this install. Reinstall Catlaser from the App Store."
        case .biometricFailed:
            return "Face ID couldn't recognise you. Try again, or use your passcode."
        case .biometricUnavailable:
            return "Face ID or a passcode isn't set up on this phone. Add one in Settings to sign in."
        }
    }
}
