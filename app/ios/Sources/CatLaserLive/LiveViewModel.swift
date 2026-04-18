import CatLaserDevice
import CatLaserProto
import Foundation
import Observation

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
    public private(set) var state: LiveViewState = .disconnected

    private let deviceClient: DeviceClient
    private let sessionFactory: @Sendable () -> any LiveStreamSession
    private var currentSession: (any LiveStreamSession)?
    private var eventsTask: Task<Void, Never>?

    public init(
        deviceClient: DeviceClient,
        sessionFactory: @escaping @Sendable () -> any LiveStreamSession,
    ) {
        self.deviceClient = deviceClient
        self.sessionFactory = sessionFactory
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
    public func start() async {
        guard state.canStart else { return }
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
            credentials = try LiveStreamCredentials(offer: offer)
        } catch {
            state = .failed(.streamOfferInvalid(error))
            await rollbackDeviceStream()
            return
        }

        state = .connecting(credentials)

        let session = sessionFactory()
        currentSession = session
        bindEvents(from: session)

        do {
            try await session.connect(using: credentials)
        } catch {
            state = .failed(.streamConnectFailed(error.localizedDescription))
            await tearDownSession()
            await rollbackDeviceStream()
            return
        }

        // Success is confirmed by the `.streaming` event flowing
        // through `bindEvents`. On some timings the event is already
        // in-flight by the time `connect` returns; the binder is
        // idempotent with respect to repeated `.streaming` events for
        // the same track.
    }

    /// Stop an in-progress stream. Sends the device `StopStreamRequest`,
    /// tears down the LiveKit session, and returns to `.disconnected`.
    public func stop() async {
        guard state.canStop else { return }
        state = .disconnecting
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
        if let session = currentSession {
            await session.disconnect()
        }
        currentSession = nil
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
                state = .streaming(track)
            } else if case .streaming = state {
                // Replace with the latest track — LiveKit can re-publish.
                state = .streaming(track)
            }
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
