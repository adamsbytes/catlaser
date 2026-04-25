import CatLaserAuth
import CatLaserProto
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

    // MARK: - Hopper row

    static let hopperLabel = "Treat hopper"
    static let hopperLevelPending = "Waiting for device…"
    static let hopperLevelOk = "Full"
    static let hopperLevelLow = "Low"
    static let hopperLevelEmpty = "Empty"

    // MARK: - Hopper refill detail

    /// Trailing label on the hopper row that hints the row is
    /// tappable. The label changes by level so a user with a
    /// just-emptied hopper sees an actionable verb ("Refill"), while
    /// a user with a healthy reading sees a passive "How to refill"
    /// — both routes lead to the same instructions, but the verb
    /// matches the urgency of the moment.
    static func hopperRowAction(_ level: Catlaser_App_V1_HopperLevel?) -> String {
        switch level {
        case .empty: return "Refill now"
        case .low: return "Refill"
        default: return "How to refill"
        }
    }

    /// Navigation title on the refill-instructions destination.
    static let hopperRefillScreenTitle = "Refill the hopper"

    /// Hero copy at the top of the refill-instructions screen. Frames
    /// the task as a short, friendly chore rather than a maintenance
    /// procedure — the owner is here to feed their cat, not service a
    /// machine.
    static let hopperRefillIntro =
        "Top up your Catlaser's treat hopper so it's ready for the next session. The whole thing takes about a minute."

    /// Section header above the numbered step list.
    static let hopperRefillStepsTitle = "How to refill"

    /// Numbered refill steps. Concrete physical actions in order, no
    /// jargon. The list is rendered with positional numbers by the
    /// view; each entry stays single-action so a user reading on a
    /// phone with the device in their other hand can complete one
    /// step before scanning to the next.
    static let hopperRefillSteps: [String] = [
        "Unplug your Catlaser so the laser stays off while you're working with it.",
        "Set it upside down on a flat surface — the laser end points away from you.",
        "Twist the bottom panel a quarter turn counter-clockwise to release the hopper lid.",
        "Pour treats into the hopper. Stop when they reach the fill line.",
        "Twist the lid back on until it clicks. Plug your Catlaser back in to resume play.",
    ]

    /// Section header above the "what to use" callout.
    static let hopperRefillSafetyTitle = "What to use"

    /// Body copy under ``hopperRefillSafetyTitle``. Spells out the
    /// supported treat shape so a user does not jam the dispenser
    /// with the wrong size — a real failure mode the dispenser
    /// mechanics impose. Numeric ranges chosen to match the
    /// hopper-bay design in the BRIEF.
    static let hopperRefillSafetyBody =
        "Small, dry treats around 8 mm wide work best. Avoid soft, sticky, or oversized pieces — they can clog the dispenser and stop play sessions."

    /// Footer copy on the refill screen. Reassures the user that the
    /// device knows when it's been refilled and they don't have to
    /// "tell" the app anything — the level row updates on the next
    /// device heartbeat.
    static let hopperRefillFooter =
        "Your Catlaser detects the new fill level on the next play session. The hopper status here updates automatically."

    /// Map a wire-level ``HopperLevel`` into the trailing-text label
    /// shown on the hopper row. Matches the severity-tint pattern the
    /// Push section already uses: a healthy reading is muted text, a
    /// ``low`` reading is the warning tint, ``empty`` is destructive
    /// so the user reaches for the next refill before they next tap
    /// "Watch live" and discover it the hard way.
    ///
    /// ``.unspecified`` / ``.UNRECOGNIZED`` falls back to the same
    /// "waiting for device" copy as ``latestStatus == nil`` so the
    /// row never shows a confusing placeholder while the first
    /// heartbeat is still in flight.
    static func hopperLevelLabel(_ level: Catlaser_App_V1_HopperLevel?) -> String {
        guard let level else { return hopperLevelPending }
        switch level {
        case .ok: return hopperLevelOk
        case .low: return hopperLevelLow
        case .empty: return hopperLevelEmpty
        case .unspecified, .UNRECOGNIZED:
            return hopperLevelPending
        }
    }

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
