#if canImport(UserNotifications)
import Foundation
import UserNotifications

/// Darwin-only ``UNUserNotificationCenterDelegate`` that forwards
/// incoming pushes into the ``PushViewModel``.
///
/// Two callbacks matter:
///
/// * ``userNotificationCenter(_:willPresent:withCompletionHandler:)``
///   — fires while the app is in the foreground. We return
///   ``.banner + .sound`` so a notification still appears as a banner
///   even when the user is looking at the app (the default is silent
///   delivery, which surprises users who expect the same banner as
///   when backgrounded). The VM still receives the payload so any
///   in-app surface that cares (cat-profiles screen, live view) can
///   refresh.
/// * ``userNotificationCenter(_:didReceive:withCompletionHandler:)``
///   — fires when the user taps the notification. We parse the FCM
///   ``data`` dict into a typed ``PushNotificationPayload`` and hand
///   it to the VM; the VM queues the resolved deep-link route.
///
/// ## Delegate ownership
///
/// The delegate is held strongly by the host app (the SwiftUI
/// `App` struct, typically via a ``@State`` property). Assigning
/// ``UNUserNotificationCenter.current().delegate`` only keeps a weak
/// reference per Apple's docs; the host is responsible for keeping
/// the concrete instance alive.
///
/// ## Threading
///
/// UNUserNotificationCenter invokes delegate callbacks on an
/// unspecified serial queue. Both callbacks hop to the ``MainActor``
/// before touching the VM so the VM's `@MainActor` isolation is
/// preserved without an explicit unsafe-unchecked fallback.
public final class AppPushDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let viewModel: @Sendable () async -> PushViewModel?

    /// Build a delegate that forwards into ``PushViewModel``.
    ///
    /// The view model is captured indirectly (via a closure) so a
    /// host that builds the VM lazily does not have to construct it
    /// before wiring the delegate. The closure is expected to return
    /// a stable reference — re-evaluating it on every callback is
    /// cheap and avoids a retain cycle when the VM holds the host's
    /// composition.
    public init(viewModel: @Sendable @escaping () async -> PushViewModel?) {
        self.viewModel = viewModel
    }

    public func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void,
    ) {
        let payload = Self.extractPayload(from: notification)
        Task { [viewModel] in
            guard let vm = await viewModel() else { return }
            await MainActor.run {
                vm.handleDidReceive(payload: payload)
            }
        }
        // Foreground: render the banner + play the sound so the
        // user gets the same UX as when backgrounded. `.list` adds
        // it to Notification Center.
        completionHandler([.banner, .list, .sound])
    }

    public func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void,
    ) {
        // Only the default action (tap) routes to a deep link; a
        // dismiss action is observational and does not open a screen.
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
            completionHandler()
            return
        }
        let payload = Self.extractPayload(from: response.notification)
        Task { [viewModel] in
            guard let vm = await viewModel() else { return }
            await MainActor.run {
                vm.handleDidReceive(payload: payload)
            }
        }
        completionHandler()
    }

    /// Pull the FCM `data` dict off a ``UNNotification``'s
    /// ``userInfo``, stringify every value (FCM may deliver numeric
    /// fields as ``NSNumber`` on iOS), and parse into the typed
    /// ``PushNotificationPayload``. Falls back to ``.unknown("")`` on
    /// an empty / non-dictionary payload.
    static func extractPayload(from notification: UNNotification) -> PushNotificationPayload {
        let raw = notification.request.content.userInfo
        var flattened: [String: String] = [:]
        flattened.reserveCapacity(raw.count)
        for (key, value) in raw {
            guard let keyString = key as? String else { continue }
            // FCM includes the `aps` dictionary unchanged; only the
            // flat scalar fields map to the parser's typed input.
            // Skipping `aps` avoids interpreting a nested `NSDictionary`
            // as a numeric field.
            if keyString == "aps" { continue }
            if let stringValue = value as? String {
                flattened[keyString] = stringValue
            } else if let number = value as? NSNumber {
                flattened[keyString] = number.stringValue
            }
            // Any other type (nested dict, array) is ignored — the
            // server side never emits those at the top level.
        }
        return PushNotificationPayload.parse(data: flattened)
    }
}
#endif
