#if canImport(UserNotifications)
import Foundation
import UserNotifications

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Thin Darwin-only bridge to ``UNUserNotificationCenter`` +
/// ``UIApplication``.
///
/// The bridge exposes three closures the cross-platform
/// ``PushViewModel`` takes as typealiases: `prompt`,
/// `readAuthorization`, and `registerForRemoteNotifications`.
/// Keeping the OS calls behind closures means the Linux SPM runner
/// builds the VM without linking ``UserNotifications`` and the tests
/// exercise the state machine with deterministic stubs.
///
/// ## Authorization policy
///
/// The app requests `.alert + .sound + .badge`. ``.provisional`` is
/// NOT requested: a provisional authorization would deliver
/// notifications quietly (no banner / no sound) which defeats the
/// point of the primer screen — a user who taps "Turn on
/// notifications" wants the banner. The alternative ("always request
/// provisional first, upgrade on user action") adds a state to the
/// VM that no wireframe needed.
///
/// ## Threading
///
/// ``UNUserNotificationCenter.requestAuthorization`` is thread-safe
/// and async-compatible; it does not need ``MainActor`` isolation.
/// ``UIApplication.registerForRemoteNotifications()`` must be called
/// on the main thread — the ``@MainActor`` hop is explicit in
/// ``registerForRemoteNotifications()``.
public struct PushAuthorizationController: Sendable {
    private let center: @Sendable () -> UNUserNotificationCenter

    public init(
        center: @escaping @Sendable () -> UNUserNotificationCenter = { .current() },
    ) {
        self.center = center
    }

    /// Permissions set the app requests. Intentionally narrow: the
    /// wireframes use alert + sound + badge. Expanding the set is an
    /// explicit product decision, not something a refactor should
    /// widen by accident.
    public static let requestedOptions: UNAuthorizationOptions = [.alert, .sound, .badge]

    /// Prompt the user via `UNUserNotificationCenter.requestAuthorization`
    /// and return the resulting ``PushAuthorizationStatus``. If the OS
    /// returns `(granted: false, error: nil)` we report ``.denied`` —
    /// this is what happens when the user hits "Don't Allow" on the
    /// OS sheet. A thrown error is propagated so the VM can surface
    /// the OS diagnostic.
    public func prompt() async throws -> PushAuthorizationStatus {
        let granted = try await center().requestAuthorization(options: Self.requestedOptions)
        let status = await currentStatus()
        if granted, status == .authorized {
            return .authorized
        }
        if status == .notDetermined {
            // The OS says "still undetermined" after a returned
            // request — unusual, but real on lock-screen-while-prompt
            // scenarios. Treat as still-idle so the VM re-shows the
            // primer rather than silently acting as if denied.
            return .notDetermined
        }
        return .denied
    }

    /// Read the current OS authorization without prompting.
    public func currentStatus() async -> PushAuthorizationStatus {
        let settings = await center().notificationSettings()
        return Self.mapStatus(settings.authorizationStatus)
    }

    /// Kick ``UIApplication.registerForRemoteNotifications()`` on the
    /// main actor. APNs hands the token back asynchronously via the
    /// app's ``UIApplicationDelegate``; there is no completion
    /// handler to await on the call itself.
    public func registerForRemoteNotifications() async {
        #if canImport(UIKit) && !os(watchOS)
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
        #endif
    }

    /// Deliberate mapping from ``UNAuthorizationStatus`` to the
    /// three-valued ``PushAuthorizationStatus`` consumed by the VM.
    ///
    /// Both `.provisional` and `.ephemeral` (App Clips) collapse to
    /// ``.authorized`` — the app has permission to deliver, which is
    /// all the VM cares about. A future addition to
    /// ``UNAuthorizationStatus`` lands here as the `@unknown default`
    /// and is treated as ``.denied`` (fail-closed).
    static func mapStatus(_ raw: UNAuthorizationStatus) -> PushAuthorizationStatus {
        switch raw {
        case .notDetermined:
            .notDetermined
        case .authorized, .provisional, .ephemeral:
            .authorized
        case .denied:
            .denied
        @unknown default:
            .denied
        }
    }
}
#endif
