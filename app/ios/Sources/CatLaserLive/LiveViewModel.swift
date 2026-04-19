import CatLaserDevice
import CatLaserProto
import Foundation
import Observation

/// Decision returned by the pre-stream user-presence gate.
///
/// The live-view screen calls into a caller-supplied gate before any
/// stream machinery is touched. The gate reports one of three
/// outcomes, and `LiveViewModel` maps each to a distinct phase:
/// `.allowed` advances to `.requestingOffer`; `.cancelled` lands back
/// on `.disconnected` silently (user said no, don't nag); `.denied`
/// lands on `.failed(.authenticationRequired)` so the UI surfaces a
/// retry path and the diagnostic reason.
public enum LiveAuthGateOutcome: Sendable, Equatable {
    case allowed
    case cancelled
    case denied(String)
}

/// Observable view model backing the live-view screen.
///
/// Responsibilities:
///
/// 1. Drive the phase state machine (`LiveViewState`).
/// 2. Own the `DeviceClient` round-trip for `StartStreamRequest` and
///    `StopStreamRequest`.
/// 3. Own the `LiveStreamSession` that subscribes to LiveKit.
/// 4. Listen for unsolicited session events (server-side disconnect,
///    network drop) and move the phase accordingly.
/// 5. Gate `start()` behind a caller-supplied user-presence check so
///    a momentarily-unlocked phone cannot reveal the in-home feed
///    without an explicit Face ID / passcode confirmation.
///
/// Reentrancy:
///
/// Every public action guards on the current phase. The state table
/// is explicit — see `start()`, `stop()`, and `dismissError()`. A
/// second tap on "Watch live" while a connect is already in flight
/// is dropped on the floor, matching `SignInViewModel`'s pattern.
///
/// Cancellation:
///
/// The VM spawns one long-running `Task` that listens on
/// `session.events`. That task is cancelled on `disconnect()` and on
/// `deinit` (via `stopEventsTask`). Individual `connect` operations
/// are performed via `await`, not detached tasks; SwiftUI's `.task`
/// modifier can cancel the whole orchestration if the view goes away
/// mid-connect.
///
/// Threading:
///
/// Marked `@MainActor` so every state mutation runs on the main
/// thread. `DeviceClient` and `LiveStreamSession` are actors, so the
/// VM awaits into them and back without explicit hopping.
@MainActor
@Observable
public final class LiveViewModel {
    /// Builder for the pre-stream user-presence gate. Called once at
    /// the top of `start()`; the VM never proceeds past this hop if
    /// the outcome is anything but `.allowed`. The closure is
    /// `@Sendable` so the composition root can thread in the
    /// auth-module's `GatedBearerTokenStore.requireLiveVideo`
    /// wrapper directly.
    public typealias AuthGate = @Sendable () async -> LiveAuthGateOutcome

    public private(set) var state: LiveViewState = .disconnected

    /// Wall-clock deadline for the ``.connecting`` phase. A legitimate
    /// LiveKit connect over Tailscale settles in a few seconds; 30
    /// seconds is generous even on slow cellular. If no ``.streaming``
    /// event arrives before the deadline, the VM tears down and
    /// lands on ``LiveViewError.streamConnectTimeout`` so the user
    /// isn't left staring at a spinner that will never resolve.
    public static let connectTimeout: TimeInterval = 30

    private let deviceClient: DeviceClient
    private let sessionFactory: @Sendable () -> any LiveStreamSession
    private let authGate: AuthGate
    private let liveKitAllowlist: LiveKitHostAllowlist
    private let connectTimeout: TimeInterval
    private var currentSession: (any LiveStreamSession)?
    private var eventsTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?

    public init(
        deviceClient: DeviceClient,
        authGate: @escaping AuthGate,
        liveKitAllowlist: LiveKitHostAllowlist,
        sessionFactory: @escaping @Sendable () -> any LiveStreamSession,
        connectTimeout: TimeInterval = LiveViewModel.connectTimeout,
    ) {
        self.deviceClient = deviceClient
        self.authGate = authGate
        self.liveKitAllowlist = liveKitAllowlist
        self.sessionFactory = sessionFactory
        self.connectTimeout = connectTimeout
    }

    // No deinit: `LiveViewModel` is `@MainActor` so `eventsTask` is
    // MainActor-isolated and cannot be safely touched from deinit.
    // The events task is cancelled explicitly on `stop()` and on any
    // failure path in `start()`; there is no path where the VM gets
    // deallocated while an events task is alive in practice, and the
    // task's own `[weak self]` capture means an orphaned task exits
    // as soon as the VM is collected.

    // MARK: - Public API

    /// Start a live stream. No-op if already starting, connecting, or
    /// streaming. Resets a `.failed` phase before retrying so the UI
    /// transitions cleanly.
    ///
    /// The very first hop is the pre-stream user-presence gate. A
    /// `.cancelled` result returns the VM to `.disconnected`; a
    /// `.denied` result lands on `.failed(.authenticationRequired)`.
    /// Neither path performs any device round-trip or LiveKit dial,
    /// so a user who cancels never leaks the fact that the device
    /// was reachable or that a stream would have been available.
    public func start() async {
        guard state.canStart else { return }

        switch await authGate() {
        case .allowed:
            break
        case .cancelled:
            // User said no. Don't bounce them through an error banner
            // that re-prompts on dismiss — that would punish the
            // explicit decline. Return to the idle entry point.
            state = .disconnected
            return
        case let .denied(reason):
            state = .failed(.authenticationRequired(reason))
            return
        }

        state = .requestingOffer

        let offer: Catlaser_App_V1_StreamOffer
        do {
            offer = try await fetchStreamOffer()
        } catch let error as LiveViewError {
            state = .failed(error)
            return
        } catch let error as DeviceClientError {
            state = .failed(.from(error))
            return
        } catch {
            state = .failed(.internalFailure(error.localizedDescription))
            return
        }

        let credentials: LiveStreamCredentials
        do {
            credentials = try LiveStreamCredentials(offer: offer, allowlist: liveKitAllowlist)
        } catch {
            state = .failed(.streamOfferInvalid(error))
            await rollbackDeviceStream()
            return
        }

        state = .connecting(credentials)

        let session = sessionFactory()
        currentSession = session
        bindEvents(from: session)
        scheduleConnectTimeout()

        do {
            try await session.connect(using: credentials)
        } catch {
            cancelConnectTimeout()
            state = .failed(.streamConnectFailed(error.localizedDescription))
            await tearDownSession()
            await rollbackDeviceStream()
            return
        }

        // Success is confirmed by the `.streaming` event flowing
        // through `bindEvents`. On some timings the event is already
        // in-flight by the time `connect` returns; the binder is
        // idempotent with respect to repeated `.streaming` events for
        // the same track. The timeout task started above remains
        // armed until either the streaming event lands (armed task
        // cancelled in `apply`) or the deadline fires.
    }

    /// Stop an in-progress stream. Sends the device `StopStreamRequest`,
    /// tears down the LiveKit session, and returns to `.disconnected`.
    ///
    /// Callable in any busy phase (`.requestingOffer`, `.connecting`,
    /// `.streaming`) — the user must always have a back-out. The VM
    /// idempotently tears down whatever state exists: a stop during
    /// `.requestingOffer` finds no session yet, a stop during
    /// `.connecting` tears the session down before `.streaming`
    /// arrives, a stop during `.streaming` is the common case.
    public func stop() async {
        guard state.canStop else { return }
        state = .disconnecting
        cancelConnectTimeout()
        await tearDownSession()
        await rollbackDeviceStream()
        state = .disconnected
    }

    /// Dismiss a `.failed` state. No-op otherwise.
    public func dismissError() {
        if case .failed = state {
            state = .disconnected
        }
    }

    // MARK: - Test hooks

    /// Synchronously-accessible, test-only tag that identifies the
    /// session currently bound to `currentSession`. `nil` when no
    /// session exists. Used by tests to assert that `stop()` wiped
    /// the reference.
    public var hasActiveSession: Bool { currentSession != nil }

    // MARK: - Private

    private func fetchStreamOffer() async throws -> Catlaser_App_V1_StreamOffer {
        let isConnected = await deviceClient.isConnected
        guard isConnected else {
            throw LiveViewError.notConnected
        }
        var request = Catlaser_App_V1_AppRequest()
        request.startStream = Catlaser_App_V1_StartStreamRequest()

        let response: Catlaser_App_V1_DeviceEvent
        do {
            response = try await deviceClient.request(request)
        } catch let error as DeviceClientError {
            throw LiveViewError.from(error)
        }

        guard case let .streamOffer(offer) = response.event else {
            let got = response.event?.description ?? "unspecified"
            throw LiveViewError.from(.wrongEventKind(expected: "stream_offer", got: got))
        }
        return offer
    }

    /// Best-effort `StopStreamRequest` to the device so the publisher
    /// side tears down too. Errors here are non-fatal — we still want
    /// the VM to settle back into `.disconnected` or `.failed`.
    private func rollbackDeviceStream() async {
        let isConnected = await deviceClient.isConnected
        guard isConnected else { return }
        var request = Catlaser_App_V1_AppRequest()
        request.stopStream = Catlaser_App_V1_StopStreamRequest()
        _ = try? await deviceClient.request(request)
    }

    private func tearDownSession() async {
        eventsTask?.cancel()
        eventsTask = nil
        cancelConnectTimeout()
        if let session = currentSession {
            await session.disconnect()
        }
        currentSession = nil
    }

    /// Arm the wall-clock watchdog for the `.connecting` phase.
    /// Cancelled when a `.streaming` event arrives, when the user
    /// taps stop, when the session tears down for any reason, or
    /// when the deadline fires (at which point the VM transitions
    /// to `.failed(.streamConnectTimeout)` and rolls back).
    private func scheduleConnectTimeout() {
        connectTimeoutTask?.cancel()
        let deadline = connectTimeout
        connectTimeoutTask = Task { [weak self] in
            let nanos = UInt64(max(deadline, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await self?.handleConnectTimeoutFired()
        }
    }

    private func cancelConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
    }

    private func handleConnectTimeoutFired() async {
        // Only act if we're still in `.connecting` — if the track
        // already arrived (or the user bailed), the task is a stale
        // echo of a cancellation that didn't catch in time.
        guard case .connecting = state else { return }
        state = .failed(.streamConnectTimeout)
        await tearDownSession()
        await rollbackDeviceStream()
    }

    private func bindEvents(from session: any LiveStreamSession) {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            let stream = await session.events
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.apply(event: event)
            }
        }
    }

    private func apply(event: LiveStreamEvent) async {
        switch event {
        case .connecting:
            // We're already in `.connecting(credentials)` from the
            // caller; the event is informational. Drop it if the
            // caller has since advanced (e.g. tore down before connect
            // resolved).
            return
        case let .streaming(track):
            if case .connecting = state {
                cancelConnectTimeout()
                state = .streaming(track)
            } else if case .streaming = state {
                // Replace with the latest track — LiveKit can re-publish.
                state = .streaming(track)
            }
        case let .unexpectedPublisher(identity):
            // A participant published a track whose identity did
            // not match the one the pairing binds us to. Terminal
            // for this start attempt — re-trying against the same
            // room will hit the same impostor. The composition root
            // sees `.failed(.unexpectedPublisher)` and may surface a
            // "report this device" affordance; at minimum the user
            // is NOT left staring at a spinner that will never
            // resolve.
            state = .failed(.unexpectedPublisher(identity: identity))
            await tearDownSession()
            await rollbackDeviceStream()
        case let .disconnected(reason):
            switch reason {
            case .localRequest:
                // Expected: our own `stop()` path calls
                // `session.disconnect()`, which fires this reason. The
                // VM will finalise in `stop()`.
                return
            case let .serverClosed(message):
                state = .failed(.streamDropped(message))
                await tearDownSession()
                await rollbackDeviceStream()
            case let .networkFailure(message):
                state = .failed(.networkFailure(message))
                await tearDownSession()
                await rollbackDeviceStream()
            }
        }
    }
}

// MARK: - Oneof event name helper

private extension Catlaser_App_V1_DeviceEvent.OneOf_Event {
    var description: String {
        switch self {
        case .statusUpdate: "status_update"
        case .catProfileList: "cat_profile_list"
        case .playHistory: "play_history"
        case .streamOffer: "stream_offer"
        case .sessionSummary: "session_summary"
        case .newCatDetected: "new_cat_detected"
        case .hopperEmpty: "hopper_empty"
        case .diagnosticResult: "diagnostic_result"
        case .error: "error"
        case .schedule: "schedule"
        case .pushTokenAck: "push_token_ack"
        case .authResponse: "auth_response"
        }
    }
}
