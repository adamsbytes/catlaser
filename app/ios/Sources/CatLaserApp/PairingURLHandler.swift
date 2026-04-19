import CatLaserPairing
import Foundation

/// Policy gate for every `catlaser://pair?...` URL the app might be
/// asked to open.
///
/// The app's pairing policy is **QR-only**: a pairing code leaves
/// the device as a QR rendered on-screen, the user scans it, and
/// `PairingViewModel.confirmPairing()` (behind an explicit tap)
/// forwards it to the coordination server. A URL-delivered pairing
/// code — message, email, universal-link, deep-link into the
/// pairing view — bypasses the QR gate and lets an attacker trick a
/// user into pairing against an attacker-controlled device by
/// tapping a link.
///
/// This helper is the compile-time insurance that the policy
/// holds. Any Xcode-target code that later adds a URL scheme
/// handler MUST route `catlaser://` URLs through
/// ``PairingURLHandler/handle(url:)``; the method refuses to pair
/// and returns a typed ``Decision/refusedURLBasedPairing`` so the
/// caller can surface the user-facing explanation. Magic-link URLs
/// are passed through unchanged — those are handled by
/// ``SignInView``'s `.onOpenURL`, not by this helper.
public enum PairingURLHandler {
    /// Possible outcomes when the app is asked to open a URL.
    public enum Decision: Sendable, Equatable {
        /// The URL is not claimed by the pairing module. The caller
        /// should forward it to whichever other handler (e.g.
        /// magic-link) owns it.
        case notPairingRelated
        /// The URL had the `catlaser://pair` shape. Refused per
        /// policy — pairing only happens via QR + explicit user
        /// confirmation. `message` is a user-facing explanation
        /// the caller can surface in an alert.
        case refusedURLBasedPairing(message: String)
    }

    /// Pairing URL scheme. Declared in `CFBundleURLTypes` by the
    /// Xcode target (if that target ever chooses to claim the
    /// scheme). Matching here is case-insensitive per RFC 3986.
    public static let pairingScheme = "catlaser"

    /// Inspect `url` and decide what the caller should do. The app
    /// entry point's `.onOpenURL { ... }` should call this and, on
    /// ``refusedURLBasedPairing``, present an alert; anything else
    /// falls through to the sign-in / magic-link handler.
    public static func handle(url: URL) -> Decision {
        guard let scheme = url.scheme?.lowercased() else {
            return .notPairingRelated
        }
        guard scheme == pairingScheme else {
            return .notPairingRelated
        }
        // A URL claiming the `catlaser://` scheme is refused
        // regardless of host/path. Even if some future release
        // wants to carry auxiliary (non-pairing) data on the
        // scheme, the decision must go through here first and
        // pattern-match explicitly; the current policy is a
        // blanket refusal.
        return .refusedURLBasedPairing(
            message: NSLocalizedString(
                "pairing.url_refused.message",
                value: "Pairing happens by scanning the QR code on your device. Links can't be trusted for pairing.",
                comment: "Alert shown when the app is opened via a catlaser:// URL.",
            ),
        )
    }
}
