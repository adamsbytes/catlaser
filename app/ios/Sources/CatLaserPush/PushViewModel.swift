import CatLaserDevice
import Foundation
import Observation

/// Observable view model backing the push-notification screen.
///
/// Responsibilities:
///
/// 1. Drive the ``PushRegistrationState`` state machine from user
///    actions and from ``PushTokenRegistrar.Outcome`` events.
/// 2. Gate OS authorization via an injected closure so the VM
///    compiles on Linux CI; the Darwin host wires the closure to
///    ``UNUserNotificationCenter`` + ``UIApplication`` registration.
/// 3. Receive tapped-notification deep-links from the UN delegate,
///    queue them, and surface the next one to the host. A FIFO
///    queue lets the host present the previous route's sheet before
///    honouring the next tap.
///
/// ## Reentrancy
///
/// Every public action consults ``state.isBusy`` before issuing work.
/// Double-tap on "Turn on notifications" is dropped; a concurrent
/// register attempt is prevented by the registrar actor's own
/// isolation.
///
/// ## Threading
///
/// ``@MainActor`` — every state mutation runs on the main thread.
/// The registrar is an actor and is awaited. The outcomes-watch task
/// is captured as ``outcomesTask`` and cancelled in ``stop()``.
@MainActor
@Observable
public final class PushViewModel {
    // MARK: - Public state

    public private(set) var state: PushRegistrationState = .idle
    public private(set) var authorization: PushAuthorizationStatus = .notDetermined

    /// FIFO queue of pending deep-link routes from tapped notifications.
    /// The head is surfaced to the host; ``consumePendingDeepLink()``
    /// pops it.
    public private(set) var pendingDeepLinks: [PushDeepLink] = []

    // MARK: - Collaborators

    public typealias AuthorizationPrompt = @Sendable () async throws -> PushAuthorizationStatus
    public typealias AuthorizationStatusReader = @Sendable () async -> PushAuthorizationStatus
    public typealias RegisterForRemoteNotifications = @Sendable () async -> Void

    private let registrar: PushTokenRegistrar
    private let prompt: AuthorizationPrompt
    private let readAuthorization: AuthorizationStatusReader
    private let registerForRemote: RegisterForRemoteNotifications

    /// Observes ``PushTokenRegistrar.outcomes`` and folds each outcome
    /// into ``state`` on the main actor. Created in ``start()`` and
    /// cancelled in ``stop()``.
    private var outcomesTask: Task<Void, Never>?

    public init(
        registrar: PushTokenRegistrar,
        prompt: @escaping AuthorizationPrompt,
        readAuthorization: @escaping AuthorizationStatusReader,
        registerForRemoteNotifications: @escaping RegisterForRemoteNotifications,
    ) {
        self.registrar = registrar
        self.prompt = prompt
        self.readAuthorization = readAuthorization
        self.registerForRemote = registerForRemoteNotifications
    }

    // MARK: - Lifecycle

    /// Hook the VM to the registrar's outcome stream and refresh the
    /// OS authorization status. Idempotent: re-calling from a host
    /// that re-mounts the screen is a no-op (the outcomes-watch task
    /// is only ever spawned once).
    public func start() async {
        startOutcomesWatcherIfNeeded()
        let status = await readAuthorization()
        authorization = status
        // If the OS already remembers a previous grant, auto-kick the
        // APNs registration. This is the "user already turned push on
        // in an earlier session" path — the composition fires
        // ``start()`` on app launch, so the APNs token arrives without
        // the user having to tap "Turn on" again.
        if status == .authorized, case .idle = state {
            state = .awaitingAPNsToken
            await registerForRemote()
        } else if status == .denied {
            state = .authorizationDenied
        }
    }

    /// Cancel the outcomes watcher. Hosting code calls this when the
    /// screen is permanently dismissed.
    public func stop() {
        outcomesTask?.cancel()
        outcomesTask = nil
    }

    // MARK: - User actions

    /// User explicitly tapped "Not now" on the primer. The primer
    /// collapses to the compact ``.postponed`` pane for the rest of
    /// the session; the OS permission prompt is untouched, so a
    /// later ``requestAuthorization()`` call still produces the
    /// one-shot system sheet. No-op if the state has already moved
    /// past the primer (we should not backtrack a busy or terminal
    /// state to a postponed label).
    public func postponeAuthorization() {
        guard case .idle = state else { return }
        state = .postponed
    }

    /// Trigger the OS authorization prompt. No-op if a prompt or
    /// registration is already in flight, or if we already have a
    /// terminal authorization answer.
    public func requestAuthorization() async {
        guard !state.isBusy else { return }
        if case .registered = state { return }
        if case .authorizationDenied = state { return }
        state = .requestingAuthorization
        let status: PushAuthorizationStatus
        do {
            status = try await prompt()
        } catch {
            state = .failed(.apnsRegistrationFailed(error.localizedDescription))
            return
        }
        authorization = status
        switch status {
        case .authorized:
            state = .awaitingAPNsToken
            await registerForRemote()
        case .denied:
            state = .authorizationDenied
        case .notDetermined:
            // Treat a still-not-determined result as a failure to
            // complete the prompt (user backgrounded the app mid-
            // prompt, etc). The state falls back so the UI re-shows
            // the primer.
            state = .idle
        }
    }

    /// Hand the VM the APNs token. Called from the Darwin bridge's
    /// `didRegisterForRemoteNotificationsWithDeviceToken` hook.
    /// Forwards the typed token to the registrar; the registrar's
    /// outcome stream drives the state transition.
    public func handleDidRegister(tokenData: Data) async {
        let token: PushToken
        do {
            token = try PushToken(rawBytes: tokenData)
        } catch {
            state = .failed(error)
            return
        }
        state = .registering(token)
        await registrar.setToken(token)
    }

    /// APNs refused to register (no network, no entitlement, etc).
    /// Surfaces the OS-level diagnostic to the state machine.
    public func handleDidFailToRegister(error: any Error) {
        state = .failed(.apnsRegistrationFailed(error.localizedDescription))
    }

    /// Called by the UN delegate on a tapped notification. Queues the
    /// resolved deep-link route for the host to consume.
    public func handleDidReceive(payload: PushNotificationPayload) {
        let route = PushDeepLink.route(for: payload)
        pendingDeepLinks.append(route)
    }

    /// Pop the next pending deep-link route, if any. The host calls
    /// this from its `.task { ... }` / `.onChange(of: ...)` hooks and
    /// drives the navigation itself; the VM does not drive navigation
    /// directly so the SwiftUI / UIKit hosts can present the route
    /// however their navigation shell prefers.
    @discardableResult
    public func consumePendingDeepLink() -> PushDeepLink? {
        guard !pendingDeepLinks.isEmpty else { return nil }
        return pendingDeepLinks.removeFirst()
    }

    /// User tapped "Try again" on the failure banner. Re-issue the
    /// register attempt against the cached token if we have one;
    /// otherwise re-request the APNs token.
    public func retry() async {
        if case .authorizationDenied = state { return }
        if let cachedToken = state.token {
            state = .registering(cachedToken)
            await registrar.retry()
            return
        }
        // No cached token — ask APNs again. This also handles the
        // "we hit a transient APNs failure" path.
        if authorization == .authorized {
            state = .awaitingAPNsToken
            await registerForRemote()
        } else {
            await requestAuthorization()
        }
    }

    // MARK: - Internal: outcomes watcher

    private func startOutcomesWatcherIfNeeded() {
        guard outcomesTask == nil else { return }
        outcomesTask = Task { [weak self, registrar] in
            let stream = registrar.outcomes
            for await outcome in stream {
                guard !Task.isCancelled else { return }
                await self?.handleOutcome(outcome)
            }
        }
    }

    private func handleOutcome(_ outcome: PushTokenRegistrar.Outcome) async {
        switch outcome {
        case let .registered(token):
            state = .registered(token)
        case .unregistered:
            // Either an explicit sign-out or an unregister fired by
            // the composition. Return to idle so a later sign-in /
            // re-pair starts the flow cleanly. Authorization status
            // is untouched — the OS grant persists across sign-ins.
            state = .idle
            pendingDeepLinks.removeAll()
        case let .failed(error):
            state = .failed(error)
        }
    }
}
