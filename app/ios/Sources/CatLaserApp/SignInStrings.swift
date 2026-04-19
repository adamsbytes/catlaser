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

    /// Map an `AuthError` to a user-presentable message. Does not include
    /// the underlying server / OS message: those values are developer
    /// artefacts that would leak implementation detail and potentially
    /// PII (email fragments, usernames) into the UI surface.
    public static func message(for error: AuthError) -> String {
        switch error {
        case .cancelled:
            return "Sign-in was cancelled."
        case .credentialInvalid:
            return "We could not verify that account. Please try again."
        case .missingIDToken, .missingBearerToken, .malformedResponse, .idTokenClaimMismatch:
            return "The sign-in service returned an unexpected response. Please try again."
        case .network:
            return "You appear to be offline. Check your connection and try again."
        case let .serverError(status, _):
            return status >= 500
                ? "Our service is having trouble right now. Please try again in a moment."
                : "The sign-in service rejected that request."
        case .keychain:
            return "This device's secure storage is unavailable. Please try again."
        case .providerUnavailable:
            return "That sign-in option isn't available on this device."
        case .providerInternal:
            return "Something went wrong while signing in. Please try again."
        case .invalidEmail:
            return "Enter a valid email address."
        case .invalidMagicLink:
            return "This sign-in link isn't valid. It may have expired or already been used."
        case .attestationFailed:
            return "This device can't sign in right now. Restart the app and try again."
        case .secureEnclaveUnavailable:
            return "This device's secure hardware is unavailable. Sign-in requires it."
        case .invalidRedirectURL:
            return "Sign-in is misconfigured on this install. Please reinstall the app."
        case .biometricFailed:
            return "Biometric check failed. Please try again."
        case .biometricUnavailable:
            return "Biometric unlock isn't set up on this device."
        }
    }
}
