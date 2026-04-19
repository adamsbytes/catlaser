import CatLaserApp
import CatLaserPush
import SwiftUI
import UIKit
import UserNotifications

/// `@main` entry for the shipping iOS app.
///
/// Delegates APNs + UNUserNotificationCenter callbacks via
/// ``CatLaserAppDelegate`` (both are still wired through
/// ``UIApplicationDelegate`` even in a SwiftUI-lifecycle app), builds
/// the ``AppComposition`` on first scene mount, and routes
/// ``ScenePhase`` transitions into the composition's lifecycle hooks.
///
/// The composition is only built ONCE per process — ``AppRoot``'s
/// `.task` modifier calls ``AppState/bootstrapIfNeeded()`` which
/// self-gates — so a secondary scene on iPad reuses the existing
/// graph rather than racing a second bootstrap.
@main
struct CatLaserAppEntry: App {
    @UIApplicationDelegateAdaptor(CatLaserAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppRoot(appState: appDelegate.state)
                .onChange(of: scenePhase) { _, newPhase in
                    handleScenePhase(newPhase, state: appDelegate.state)
                }
        }
    }

    /// Route scene-phase transitions into the composition's
    /// lifecycle hooks. The Task is fire-and-forget: the hooks are
    /// `async` but the iOS runtime does not wait for us to finish —
    /// the OS's own suspension window caps the work, and both hooks
    /// internally guard against concurrent invocation.
    @MainActor
    private func handleScenePhase(_ phase: ScenePhase, state: AppState) {
        guard let composition = state.composition else { return }
        switch phase {
        case .background:
            Task { await composition.applicationDidEnterBackground() }
        case .active:
            Task { await composition.applicationDidBecomeActive() }
        default:
            break
        }
    }
}

/// Root view rendered inside the ``WindowGroup``. Shows the
/// ``LaunchPlaceholder`` until ``AppState`` finishes bootstrapping,
/// then hands over to ``RootView``.
///
/// The `.task` modifier fires once per appear; ``bootstrapIfNeeded``
/// is idempotent so a re-mount does not rebuild the graph.
private struct AppRoot: View {
    @Bindable var appState: AppState

    var body: some View {
        Group {
            if let shell = appState.shell {
                RootView(
                    shell: shell,
                    appVersion: appState.appVersion,
                    buildNumber: appState.buildNumber,
                )
            } else {
                LaunchPlaceholder()
            }
        }
        .task {
            await appState.bootstrapIfNeeded()
        }
    }
}

/// `UIApplicationDelegate` bridge. `@UIApplicationDelegateAdaptor`
/// routes UIKit's delegate callbacks here; we forward APNs register
/// / fail into the long-lived ``PushViewModel`` on the shared
/// ``AppState``, and install the single process-wide
/// ``UNUserNotificationCenterDelegate`` implementation.
///
/// Intentionally NOT `@MainActor`: UIKit calls delegate methods on
/// the main thread but that constraint is expressed via the
/// protocol's own annotations, and leaving this class unisolated
/// lets the ``@UIApplicationDelegateAdaptor`` initialiser pattern
/// compile cleanly against Swift 6 strict concurrency.
final class CatLaserAppDelegate: NSObject, UIApplicationDelegate {
    /// Shared app state. UIKit creates the delegate on the main
    /// thread, so `MainActor.assumeIsolated` is a safe cast — the
    /// compiler cannot see the UIKit guarantee, but Apple's docs on
    /// `UIApplicationDelegate` are explicit: delegate construction
    /// and every delegate callback run on the main thread.
    let state: AppState = MainActor.assumeIsolated { AppState() }

    /// Retention for the UNUserNotificationCenter delegate.
    /// ``UNUserNotificationCenter.delegate`` is ``weak``; we hold the
    /// concrete ``AppPushDelegate`` here so the registration stays
    /// alive for the process lifetime.
    private var notificationDelegate: AppPushDelegate?

    // MARK: - UIApplicationDelegate

    @MainActor
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil,
    ) -> Bool {
        let capturedState = state
        let delegate = AppPushDelegate { [weak capturedState] in
            await MainActor.run { capturedState?.pushViewModel }
        }
        notificationDelegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
        return true
    }

    @MainActor
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data,
    ) {
        let capturedState = state
        Task { @MainActor in
            if let vm = capturedState.pushViewModel {
                await vm.handleDidRegister(tokenData: deviceToken)
            }
        }
    }

    @MainActor
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error,
    ) {
        state.pushViewModel?.handleDidFailToRegister(error: error)
    }
}
