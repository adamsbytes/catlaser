import CatLaserAuth
import Foundation

/// State machine for the sign-in screen. Every user-visible screen
/// configuration maps to exactly one case; the view renders off
/// `SignInViewModel.phase` and the VM mutates it.
///
/// The legal transitions are:
///
/// * `.idle`
///    → `.authenticating(.apple)` / `.authenticating(.google)` on
///      social-button tap
///    → `.requestingMagicLink` on magic-link submit
///    → `.verifyingMagicLink` when a Universal Link is tapped from
///      anywhere in the app (including cold-start deeplink)
///
/// * `.authenticating(_)`, `.requestingMagicLink`, `.verifyingMagicLink`
///    → `.succeeded(session)` on success
///    → `.emailSent(address)` from `.requestingMagicLink` on success
///    → `.failed(error)` on any error except `.cancelled`
///    → `.idle` on `.cancelled`
///
/// * `.emailSent(_)`
///    → `.verifyingMagicLink` when the Universal Link callback arrives
///    → `.idle` when the user taps "Use a different email"
///    → `.requestingMagicLink` when the user taps "Resend"
///
/// * `.failed(_)`
///    → `.idle` on `dismissError`
///
/// * `.succeeded(_)` is terminal; hosting code navigates away of the
///    sign-in screen and the VM's lifetime ends.
public enum SignInPhase: Sendable, Equatable {
    case idle
    case authenticating(SocialProvider)
    case requestingMagicLink
    case emailSent(String)
    case resendingMagicLink(String)
    case verifyingMagicLink
    case succeeded(AuthSession)
    case failed(AuthError)

    /// True while an in-flight operation holds the VM. Used as a reentrancy
    /// lock — a second sign-in tap arriving before the first completes
    /// must be ignored rather than racing the coordinator.
    public var isBusy: Bool {
        switch self {
        case .authenticating,
             .requestingMagicLink,
             .resendingMagicLink,
             .verifyingMagicLink:
            true
        case .idle, .emailSent, .succeeded, .failed:
            false
        }
    }

    /// True once sign-in has succeeded. Hosting code drives the
    /// transition out of the sign-in screen when this flips.
    public var isTerminal: Bool {
        if case .succeeded = self { true } else { false }
    }
}
