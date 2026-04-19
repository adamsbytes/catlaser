#if canImport(UIKit) && !os(watchOS)
import Observation
import SwiftUI
import UIKit

/// Shared state for per-screen interface-orientation policy.
///
/// Why this exists
/// ---------------
///
/// The app's hero experience is the live-video tab, which needs
/// landscape so a 16:9 camera feed can fill the phone screen. Every
/// other screen — sign-in, pairing, tabs with forms, QR scanner — is
/// a portrait-first layout and would look wrong (or outright break
/// layout) in landscape. Apple supports "per-screen orientation" only
/// via the UIKit delegate:
/// ``UIApplicationDelegate/application(_:supportedInterfaceOrientationsFor:)``
/// reads a policy for the current window, and the OS consults it on
/// every rotation decision. SwiftUI does not surface this API; we
/// bridge by reading the mask from this shared controller.
///
/// Usage contract
/// --------------
///
/// - The ``CatLaserAppDelegate`` reads ``mask`` from the main actor
///   every time UIKit asks for the supported orientations.
/// - SwiftUI views that want to unlock orientation call ``allow(_:)``
///   on ``onAppear`` and reset to portrait on ``onDisappear``.
/// - When the mask changes, the controller requests a geometry update
///   via ``UIWindowScene/requestGeometryUpdate(_:errorHandler:)`` so
///   the OS immediately re-evaluates supported orientations — without
///   this, a user who rotates back to portrait and then moves to a
///   landscape-enabled screen would stay portrait-locked until the
///   next rotation attempt.
///
/// The controller is ``@MainActor``-isolated — ``UIApplication`` is
/// too, and the delegate callback runs on the main thread. Callers
/// must hop from non-main contexts before invoking ``allow(_:)`` /
/// ``lockToPortrait()``.
@MainActor
@Observable
public final class OrientationLock {
    /// Process-wide singleton. The ``UIApplicationDelegate`` hook is
    /// one-per-app by definition, and the delegate has no way to
    /// receive an injected instance from the SwiftUI view graph, so
    /// the bridge has to read from a shared location. Kept a `let`
    /// to make the single-instance invariant visible.
    public static let shared = OrientationLock()

    /// Currently-permitted orientations. Defaults to portrait-only on
    /// iPhone, which is the posture every screen except the live-view
    /// tab wants; overrides via ``allow(_:)`` lift the restriction on
    /// the specific screens that benefit.
    ///
    /// On iPad the default is ``all`` because the entire iPad layout
    /// is expected to adapt to any orientation — the iPhone-only
    /// portrait lock would be actively bad on iPad and contradicts
    /// ``Info.plist``'s `UISupportedInterfaceOrientations~ipad`.
    public private(set) var mask: UIInterfaceOrientationMask = .portrait

    private init() {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            mask = .all
        }
        #endif
    }

    /// Request a wider orientation policy. A repeat call for the same
    /// mask is a no-op; a distinct mask updates the shared state and
    /// immediately asks UIKit to re-evaluate supported orientations
    /// against the active scene. If the current physical orientation
    /// is not in the new mask, the OS rotates to a permitted one.
    public func allow(_ newMask: UIInterfaceOrientationMask) {
        guard mask != newMask else { return }
        mask = newMask
        invalidateSupportedOrientations()
    }

    /// Revert to the portrait-only default. Used by tabs other than
    /// Live on appear (so switching away from Live immediately
    /// rotates back) and by the paired shell when a non-paired phase
    /// re-enters the flow.
    public func lockToPortrait() {
        allow(.portrait)
    }

    // MARK: - UIKit bridge

    /// Ask UIKit to re-read the supported orientations. Must be
    /// called any time ``mask`` changes so the OS picks up the new
    /// policy without waiting for a physical rotation event.
    ///
    /// Structured as a best-effort call — the app has exactly one
    /// active scene by Info.plist policy (``UIApplicationSupportsMultipleScenes``
    /// is ``false``), so the first ``UIWindowScene`` is the one to
    /// invalidate. If for some reason no scene is yet connected
    /// (e.g. this method were called during initial scene
    /// construction) the call silently no-ops; the next scene mount
    /// will pick up the mask naturally via the delegate hook.
    private func invalidateSupportedOrientations() {
        #if os(iOS)
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        guard let scene else { return }
        let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(
            interfaceOrientations: mask,
        )
        scene.requestGeometryUpdate(geometryPreferences) { _ in
            // Errors here are benign — iPad ignores portrait-only
            // requests in full-screen multitasking, and an error path
            // through ``setNeedsUpdateOfSupportedInterfaceOrientations``
            // recovers the next time the scene becomes active. We
            // intentionally do not surface these to the user.
        }
        scene.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
        #endif
    }
}

// MARK: - SwiftUI integration

/// View modifier that installs a per-screen orientation policy on
/// appear and restores the portrait default on disappear.
///
/// Usage on the live-video tab:
///
///     LiveView(viewModel: vm)
///         .allowOrientations(.allButUpsideDown)
///
/// Other tabs / screens do NOT need to apply the modifier — the
/// shared lock defaults to portrait and only Live unlocks it. This
/// keeps the wiring concentrated at the one place that benefits.
public struct OrientationLockModifier: ViewModifier {
    let allowed: UIInterfaceOrientationMask

    public func body(content: Content) -> some View {
        content
            .onAppear {
                OrientationLock.shared.allow(allowed)
            }
            .onDisappear {
                OrientationLock.shared.lockToPortrait()
            }
    }
}

public extension View {
    /// Permit `allowed` orientations while this view is on screen.
    /// Reverts to portrait-only on disappear so sibling tabs / modal
    /// screens keep their portrait-first layout intact.
    func allowOrientations(_ allowed: UIInterfaceOrientationMask) -> some View {
        modifier(OrientationLockModifier(allowed: allowed))
    }
}
#endif
