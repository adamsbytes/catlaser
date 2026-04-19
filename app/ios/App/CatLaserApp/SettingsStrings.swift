import CatLaserAuth
import Foundation

/// User-facing copy for the Settings tab.
///
/// Centralised here so the Settings view (and its destructive-confirm
/// dialogs and the sign-out alert) stay consistent with the rest of
/// the app's *Strings pattern. Plain string members rather than
/// ``NSLocalizedString`` keys to mirror the convention in
/// ``PairingStrings``: the iOS app ships English-only for v1 per the
/// product brief and the future localisation pass touches one file at
/// a time.
///
/// ``signOutErrorMessage(for:)`` maps an ``Error`` thrown by the sign-
/// out coordinator into a presentable sentence — the raw
/// ``String(describing:)`` of an underlying ``AuthError`` is a
/// developer artefact (associated values include OSStatus codes,
/// server messages, provider stack fragments) that does not belong on
/// a user-facing alert. Known ``AuthError`` cases are routed through
/// the existing ``SignInStrings.message(for:)`` mapping; anything else
/// surfaces a generic safe fallback.
enum SettingsStrings {
    // MARK: - Screen chrome

    static let screenTitle = "Settings"

    // MARK: - Notifications section

    static let notificationsSection = "Notifications"
    static let notificationsRowLabel = "Push notifications"
    static let notificationsStatusOn = "On"
    static let notificationsStatusOff = "Off"
    static let notificationsStatusConfiguring = "Setting up…"
    static let notificationsStatusDenied = "Denied"
    static let notificationsStatusNeedsAttention = "Needs attention"
    static let notificationsScreenTitle = "Push notifications"

    // MARK: - Device section

    static let deviceSection = "Catlaser device"
    static let deviceNameLabel = "Name"
    static let deviceIDLabel = "Device ID"
    static let deviceStatusLabel = "Status"
    static let deviceFallbackName = "Catlaser"
    static let deviceNotPaired = "No Catlaser paired."

    // MARK: - Account section

    static let accountSection = "Account"
    static let signOutButton = "Sign out"

    // MARK: - About section

    static let aboutSection = "About"
    static let versionLabel = "Version"
    static let buildLabel = "Build"
    static let privacyPolicyRow = "Privacy policy"
    static let termsOfServiceRow = "Terms of service"

    // MARK: - Delete account dialog

    static let deleteAccountButton = "Delete account"
    static let confirmDeleteAccountTitle = "Delete your account?"
    static let confirmDeleteAccountMessage =
        "Your sessions, cat profiles, schedule, and pairings will be permanently removed from the server. This can't be undone."
    static let confirmDeleteAccountAction = "Delete account"
    static let deleteAccountErrorTitle = "Couldn't delete account"
    static let deleteAccountErrorOK = "OK"

    /// Map an error thrown by ``AuthCoordinator/deleteAccount`` into a
    /// user-presentable sentence. Mirrors ``signOutErrorMessage(for:)``
    /// — typed ``AuthError`` cases route through the sign-in copy so
    /// the wording stays consistent; everything else falls back to a
    /// generic safe message so the alert never leaks raw error
    /// descriptions (OSStatus codes, server messages, provider stack
    /// fragments — developer artefacts that belong in logs, not UI).
    static func deleteAccountErrorMessage(for error: Error) -> String {
        if let authError = error as? AuthError {
            return SignInStrings.message(for: authError)
        }
        return deleteAccountGenericFallback
    }

    /// Fallback shown when the error thrown by ``deleteAccount`` is
    /// not an ``AuthError``. Unlike sign-out, delete-account does NOT
    /// wipe local state when the server call fails — the account
    /// still exists on the server and a half-deleted local state
    /// would be worse than the error. This copy tells the user the
    /// operation did not complete and they can try again.
    private static let deleteAccountGenericFallback =
        "We couldn't reach the server to delete your account. Try again in a moment."

    // MARK: - Confirm-unpair dialog

    static let confirmUnpairTitle = "Unpair this Catlaser?"
    static let confirmUnpairMessage =
        "You'll need to scan the QR code on the device to pair again."
    static let confirmUnpairAction = "Unpair"
    static let cancelButton = "Cancel"

    // MARK: - Confirm-sign-out dialog

    static let confirmSignOutTitle = "Sign out?"
    static let confirmSignOutMessage =
        "Your Catlaser pairing stays on the device — signing in again restores it."
    static let confirmSignOutAction = "Sign out"

    // MARK: - Sign-out failure alert

    static let signOutErrorTitle = "Sign-out issue"
    static let signOutErrorOK = "OK"

    /// Map an error thrown by ``AuthCoordinator/signOut`` into a
    /// user-presentable sentence. Known typed errors route through
    /// ``SignInStrings.message(for:)`` so the wording matches what the
    /// sign-in screen uses for the same failure class. Everything else
    /// falls back to a generic safe message so the alert never leaks
    /// raw error descriptions (which can include OSStatus codes,
    /// server messages, or provider stack fragments — developer
    /// artefacts that belong in logs, not in UI).
    static func signOutErrorMessage(for error: Error) -> String {
        if let authError = error as? AuthError {
            return SignInStrings.message(for: authError)
        }
        return signOutGenericFallback
    }

    /// Fallback shown when the error thrown by ``signOut`` is not an
    /// ``AuthError`` — the local-state wipe still happened (the
    /// coordinator's docstring guarantees that), so the user is being
    /// signed out regardless; this message just acknowledges that the
    /// server couldn't be told.
    private static let signOutGenericFallback =
        "We signed you out on this device. The server couldn't be notified — sign in again to refresh."
}
