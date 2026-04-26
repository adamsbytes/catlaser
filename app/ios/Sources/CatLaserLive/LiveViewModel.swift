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

    /// True when the user tapped "Watch live" and then cancelled the
    /// biometric / passcode prompt before the stream could proceed.
    /// The VM returns to ``.disconnected`` silently on a cancel (no
    /// error banner — the user said no, and nagging them with a red
    /// dialog punishes the explicit choice), but the disconnected
    /// screen reads the flag and softens its subtitle to "Couldn't
    /// confirm your identity. Tap Watch live to try again." so the
    /// user understands *why* nothing happened and where to go next.
    ///
    /// Cleared at the top of ``start()`` so any subsequent success
    /// or failure rewrites the subtitle. Also cleared by
    /// ``dismissError`` and when the screen hands the VM a
    /// successful stream start — the flag is only truthful for the
    /// single intervening disconnected frame.
    public private(set) var didCancelAuthGate: Bool = false

    /// True when the most recent stream ended because of a network-
    /// class drop (wifi roam, cellular hiccup, app suspended in
    /// background → socket dropped by iOS). The VM lands in
    /// ``.disconnected`` rather than ``.failed`` for this class — the
    /// red error pane and Retry button are the wrong UX for a
    /// transient condition the user probably caused themselves by
    /// switching apps. The screen reads this flag and surfaces a
    /// softened "Stream paused when your phone lost the connection.
    /// Tap Watch live to resume." subtitle so the user understands
    /// the feed stopped rather than thinking their first tap was
    /// never registered.
    ///
    /// Cleared at the top of ``start()`` so a retry rewrites the
    /// subtitle, and cleared on any subsequent ``.failed`` path so a
    /// follow-up hard error surfaces its own message cleanly.
    public private(set) var didDropFromNetwork: Bool = false

    /// View-facing snapshot of the device's play-session status and
    /// hopper reading. Updated by the broker subscription; renders the
    /// top-of-stream overlay ("Playing now • 1m 20s") and the
    /// stationary hopper badge. Observable so SwiftUI re-renders on
    /// every status push.
    public private(set) var sessionStatus: LiveSessionStatus = .init()

    /// Wall-clock deadline for the ``.connecting`` phase. A legitimate
    /// LiveKit connect over Tailscale settles in a few seconds; 30
    /// seconds is generous even on slow cellular. If no ``.streaming``
    /// event arrives before the deadline, the VM tears down and
    /// lands on ``LiveViewError.streamConnectTimeout`` so the user
    /// isn't left staring at a spinner that will never resolve.
    public static let connectTimeout: TimeInterval = 30

    /// Wall-clock deadline for the ``.disconnecting`` phase. A healthy
    /// ``LiveStreamSession.disconnect()`` + best-effort
    /// ``StopStreamRequest`` settles inside a second; the watchdog
    /// guards against a wedged LiveKit room or a device that refuses
    /// to ack the stop request. If the deadline wins, the teardown
    /// continues in the background (the LiveKit room cleans up on
    /// its own once the network path recovers) but the UI moves
    /// back to ``.disconnected`` so the user has a path forward
    /// instead of a spinner that never resolves.
    public static let stopTimeout: TimeInterval = 5

    /// How long a successful ``StreamOffer`` round-trip stays cached
    /// for re-use by a subsequent ``start()``. The LiveKit subscriber
    /// JWT in the offer is short-lived but well within ten minutes;
    /// bounding the cache here keeps Watch live → Stop → Watch live
    /// cycles within the cache window instant (no round-trip, no
    /// LiveKit room recreation) without risking a stale credential
    /// being used after the device has rotated the room.
    ///
    /// The cache is a soft hint, not a contract. Any stream-side
    /// failure (drop, server-side close, dial error) invalidates the
    /// cache so the next ``start()`` falls back to a fresh offer
    /// fetch. A device-client swap (sign-out, re-pair, supervisor
    /// reconnect) also invalidates because the freshly-bound device
    /// owns its own room mint.
    public static let credentialCacheTTL: TimeInterval = 600

    /// The device control channel. ``var`` rather than ``let`` so a
    /// supervisor reconnect on the SAME paired device can swap in a
    /// fresh client without tearing down the user-visible streaming
    /// state. See ``swapDeviceClient(_:eventBroker:)``.
    private var deviceClient: DeviceClient
    private let sessionFactory: @Sendable () -> any LiveStreamSession
    private let authGate: AuthGate
    private let liveKitAllowlist: LiveKitHostAllowlist
    private let connectTimeout: TimeInterval
    private let stopTimeoutInterval: TimeInterval
    private let credentialCacheTTL: TimeInterval
    private let clock: @Sendable () -> Date
    private var currentSession: (any LiveStreamSession)?
    private var eventsTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var statusObservationTask: Task<Void, Never>?
    private var cachedCredentials: CachedCredentials?

    /// Cached subscriber credentials and their wall-clock expiry.
    ///
    /// Recorded after a successful ``fetchStreamOffer`` round-trip
    /// and consumed by the next ``start()`` if it fires inside
    /// ``credentialCacheTTL``. Cleared eagerly on any path that
    /// suggests the cached value can no longer dial: server-side
    /// teardown, network-class drop, dial failure, device-client
    /// swap, or a stop that explicitly invalidates.
    private struct CachedCredentials {
        let credentials: LiveStreamCredentials
        let expiresAt: Date
    }

    public init(
        deviceClient: DeviceClient,
        authGate: @escaping AuthGate,
        liveKitAllowlist: LiveKitHostAllowlist,
        sessionFactory: @escaping @Sendable () -> any LiveStreamSession,
        eventBroker: DeviceEventBroker? = nil,
        connectTimeout: TimeInterval = LiveViewModel.connectTimeout,
        stopTimeout: TimeInterval = LiveViewModel.stopTimeout,
        credentialCacheTTL: TimeInterval = LiveViewModel.credentialCacheTTL,
        clock: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.deviceClient = deviceClient
        self.authGate = authGate
        self.liveKitAllowlist = liveKitAllowlist
        self.sessionFactory = sessionFactory
        self.connectTimeout = connectTimeout
        self.stopTimeoutInterval = stopTimeout
        self.credentialCacheTTL = credentialCacheTTL
        self.clock = clock
        if let eventBroker {
            startStatusObservation(broker: eventBroker)
        }
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

        // Clear both transient subtitle flags at the top of each
        // attempt. If the gate cancels or the network drops again
        // below, the relevant flag is re-raised; otherwise the
        // softened subtitle goes away the moment the user tries again.
        didCancelAuthGate = false
        didDropFromNetwork = false

        switch await authGate() {
        case .allowed:
            break
        case .cancelled:
            // User said no. Don't bounce them through an error banner
            // that re-prompts on dismiss — that would punish the
            // explicit decline. Return to the idle entry point, but
            // raise the transient flag so the disconnected subtitle
            // tells them the biometric prompt was cancelled (and
            // implicitly: tap Watch live again to try once more).
            didCancelAuthGate = true
            state = .disconnected
            return
        case let .denied(reason):
            state = .failed(.authenticationRequired(reason))
            return
        }

        // Cached credentials short-circuit the device round-trip and
        // the LiveKit room mint. The fast path is the dominant case
        // for the "stop, then watch again seconds later" pattern,
        // turning a 500 ms-1 s spinner into an immediate ``.connecting``.
        let credentials: LiveStreamCredentials
        if let cached = consumeFreshCachedCredentials() {
            credentials = cached
            state = .connecting(credentials)
        } else {
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

            do {
                credentials = try LiveStreamCredentials(offer: offer, allowlist: liveKitAllowlist)
            } catch {
                state = .failed(.streamOfferInvalid(error))
                await rollbackDeviceStream()
                return
            }

            // Cache the fresh credentials for a follow-up Watch live
            // tap. Population happens here (not after the LiveKit
            // dial) because the offer round-trip is the expensive
            // part the cache is meant to skip; the dial itself runs
            // every time so a re-use of the same room is what the
            // device handler sees on the second tap.
            recordCredentialsInCache(credentials)
            state = .connecting(credentials)
        }

        let session = sessionFactory()
        currentSession = session
        bindEvents(from: session)
        scheduleConnectTimeout()

        do {
            try await session.connect(using: credentials)
        } catch {
            cancelConnectTimeout()
            // The dial failed against these specific credentials —
            // re-using them on a retry would just hit the same wall.
            // Drop them so the user's next tap fetches a fresh offer.
            invalidateCredentialCache()
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
    ///
    /// The teardown is raced against a wall-clock deadline
    /// (``stopTimeout``) so a wedged LiveKit disconnect or a device
    /// that refuses to ack ``StopStreamRequest`` cannot pin the user
    /// on the disconnecting spinner indefinitely. If the deadline
    /// wins, the in-flight work is left to finish in the background
    /// and the UI returns to ``.disconnected`` immediately. The
    /// cooperative teardown's own ``tearDownSession`` clears
    /// ``currentSession`` *before* awaiting the session's disconnect,
    /// so a later ``start()`` cannot collide with a stale teardown
    /// overwriting the fresh session reference.
    public func stop() async {
        guard state.canStop else { return }
        state = .disconnecting
        cancelConnectTimeout()
        await raceTeardownAgainstStopTimeout()
        state = .disconnected
    }

    /// Run the stop-path teardown (LiveKit disconnect + best-effort
    /// ``StopStreamRequest``) and return when either the teardown
    /// completes or the ``stopTimeout`` wall-clock deadline fires,
    /// whichever is first.
    ///
    /// The teardown runs as an **unstructured** ``Task`` so a stuck
    /// ``LiveStreamSession.disconnect()`` (non-cooperative on
    /// cancellation) cannot hold ``stop()`` open past the wall-clock
    /// deadline. Using a structured ``TaskGroup`` here would defeat
    /// the whole watchdog: ``withTaskGroup`` only returns when every
    /// child task has completed, so a hung child would pin the
    /// caller regardless of ``cancelAll``.
    ///
    /// If the deadline wins, the teardown task keeps running in the
    /// background — LiveKit cleans up on its own once the network
    /// path recovers, and ``tearDownSession`` has already nulled
    /// ``currentSession`` up-front so a subsequent ``start()``
    /// cannot collide with a late-arriving assignment.
    private func raceTeardownAgainstStopTimeout() async {
        let deadline = stopTimeoutInterval
        let nanos = UInt64(max(deadline, 0) * 1_000_000_000)

        let teardownTask = Task { [weak self] in
            await self?.performStopTeardown()
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumer = OneShotResumer(continuation: continuation)
            Task {
                _ = await teardownTask.value
                resumer.resume()
            }
            Task {
                try? await Task.sleep(nanoseconds: nanos)
                resumer.resume()
            }
        }

        // Deadline-won path: signal cooperative cancellation on the
        // teardown so a checked-cancellation awaitable can exit
        // early. Non-cooperative callees (LiveKit's own disconnect
        // on some code paths) still run to completion in the
        // background — that is explicitly the contract of the
        // watchdog. When the teardown wins this cancel is a no-op.
        teardownTask.cancel()
    }

    /// The actual teardown body. Extracted from ``stop()`` so the
    /// watchdog race can wrap it in a ``TaskGroup``. Must remain
    /// idempotent against cancellation and re-entry — a second
    /// invocation while the first is still in flight would simply
    /// tear down whatever state is left.
    private func performStopTeardown() async {
        await tearDownSession()
        await rollbackDeviceStream()
    }

    /// Dismiss a `.failed` state. No-op otherwise. Also clears both
    /// transient subtitle flags so a user who lands on the error
    /// screen after a cancel-then-denial or a network-drop-then-
    /// hard-failure sequence doesn't see a stale softened subtitle
    /// once the error is dismissed.
    public func dismissError() {
        didCancelAuthGate = false
        didDropFromNetwork = false
        if case .failed = state {
            state = .disconnected
        }
    }

    /// Replace the device control channel and the unsolicited-event
    /// broker without disturbing the user-visible streaming state.
    ///
    /// Called by the host's connection-supervisor reconcile loop when
    /// a fresh transport lands against the SAME paired device — e.g.
    /// after a brief network blip. The LiveKit session is independent
    /// of the device control channel (the publisher → media-server →
    /// subscriber path does not flow through the device's app-protocol
    /// socket), so a transient supervisor swap need not throw away the
    /// active video. If LiveKit also dropped, the events binder will
    /// observe the underlying `.disconnected` event and transition
    /// to `.failed` on its own — this method does not pre-judge.
    ///
    /// The status-observation task is re-armed against the new broker.
    /// The previous broker is the caller's responsibility to ``stop()``;
    /// this method does not own its lifecycle.
    public func swapDeviceClient(
        _ newClient: DeviceClient,
        eventBroker newBroker: DeviceEventBroker,
    ) {
        deviceClient = newClient
        // Cached credentials were minted by the previous transport's
        // device handler. A swap may be transparent (same paired
        // device, fresh socket) or substantive (sign-out, re-pair to
        // a different device); we cannot tell from here. Drop the
        // cache so the next ``start()`` round-trips against the new
        // client and gets a token bound to its identity.
        invalidateCredentialCache()
        statusObservationTask?.cancel()
        statusObservationTask = nil
        startStatusObservation(broker: newBroker)
    }

    // MARK: - Test hooks

    /// Synchronously-accessible, test-only tag that identifies the
    /// session currently bound to `currentSession`. `nil` when no
    /// session exists. Used by tests to assert that `stop()` wiped
    /// the reference.
    public var hasActiveSession: Bool { currentSession != nil }

    /// Test-only: whether the VM has attached a status observation
    /// task to a broker. Tests assert this to confirm a VM
    /// constructed without a broker stays silent and a VM constructed
    /// with one does observe.
    public var isObservingStatus: Bool { statusObservationTask != nil }

    /// Test-only: whether the credential cache currently holds a
    /// non-expired entry. Tests assert this to verify population on
    /// successful start, eviction on failure paths, and expiry.
    public var hasCachedCredentials: Bool {
        guard let cached = cachedCredentials else { return false }
        return cached.expiresAt > clock()
    }

    // MARK: - Credential cache

    /// Return the cached credentials if present and unexpired; ``nil``
    /// otherwise. Lazy expiry check: a stale entry is dropped at the
    /// moment a caller asks for it so the cache never serves a value
    /// past its TTL.
    private func consumeFreshCachedCredentials() -> LiveStreamCredentials? {
        guard let cached = cachedCredentials else { return nil }
        if cached.expiresAt > clock() {
            return cached.credentials
        }
        cachedCredentials = nil
        return nil
    }

    private func recordCredentialsInCache(_ credentials: LiveStreamCredentials) {
        cachedCredentials = CachedCredentials(
            credentials: credentials,
            expiresAt: clock().addingTimeInterval(credentialCacheTTL),
        )
    }

    private func invalidateCredentialCache() {
        cachedCredentials = nil
    }

    // MARK: - Session status observation

    /// Attach a long-running observer to the broker's event fanout
    /// and translate ``StatusUpdate`` / ``SessionSummary`` into the
    /// view-facing ``sessionStatus`` value. Runs for the lifetime of
    /// the VM; exits cleanly when the broker stops (its subscription
    /// stream finishes) or when the VM is released (``[weak self]``
    /// capture lets the task exit on the next event).
    ///
    /// Intentionally not exposed as a public lifecycle method: the
    /// observation is tied to VM construction, not to the stream
    /// start / stop state machine. Having a separate "start status
    /// observation" API would let a caller forget to call it and
    /// silently leave the overlay blank; making it implicit at init
    /// means the one call site (``AppComposition/liveViewModel``) gets
    /// the wiring right for free.
    private func startStatusObservation(broker: DeviceEventBroker) {
        guard statusObservationTask == nil else { return }
        let subscription = broker.events()
        statusObservationTask = Task { [weak self] in
            for await event in subscription {
                guard !Task.isCancelled else { return }
                guard let strongSelf = self else { return }
                // ``applyStatus`` / ``applySessionEnded`` are
                // MainActor-isolated non-async methods; route through
                // ``MainActor.run`` to make the actor hop explicit and
                // keep Swift 6's optional-chain await analysis quiet.
                switch event.event {
                case let .statusUpdate(payload):
                    await MainActor.run {
                        strongSelf.applyStatus(payload)
                    }
                case .sessionSummary:
                    await MainActor.run {
                        strongSelf.applySessionEnded()
                    }
                default:
                    continue
                }
            }
        }
    }

    private func applyStatus(_ payload: Catlaser_App_V1_StatusUpdate) {
        var updated = sessionStatus
        updated.hopperLevel = payload.hopperLevel
        updated.firmwareVersion = payload.firmwareVersion
        if payload.sessionActive {
            updated.phase = .playing
            updated.activeCatCount = payload.activeCatIds.count
            // Track the first-observed timestamp on the rising edge
            // only. If we're already playing, keep the earlier
            // reading so the overlay's elapsed-time counter doesn't
            // reset on every heartbeat.
            if updated.sessionStartedAt == nil {
                updated.sessionStartedAt = clock()
            }
        } else {
            updated.phase = .idle
            updated.activeCatCount = 0
            updated.sessionStartedAt = nil
        }
        sessionStatus = updated
    }

    private func applySessionEnded() {
        // Session-summary is the edge-triggered "session just ended"
        // signal. Even if a following heartbeat hasn't landed yet, we
        // reset the overlay so the stale elapsed counter doesn't keep
        // ticking after the device has actually stopped.
        var updated = sessionStatus
        updated.phase = .idle
        updated.activeCatCount = 0
        updated.sessionStartedAt = nil
        sessionStatus = updated
    }

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
        // Claim ownership of ``currentSession`` BEFORE awaiting the
        // LiveKit-side disconnect. If the caller's ``stop()``
        // watchdog expires and a subsequent ``start()`` assigns a
        // fresh session to ``currentSession``, our slow disconnect
        // path must not later null it back out — the new session
        // would be detached from the view and the user would watch
        // a black frame where the stream should be. Capturing the
        // session locally and nulling the property up-front makes
        // this race impossible.
        guard let session = currentSession else { return }
        currentSession = nil
        await session.disconnect()
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
            // resolve. Drop the cache so a retry against this device
            // mints a fresh offer rather than re-using a token that
            // points at a compromised room.
            invalidateCredentialCache()
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
                // The server tore the room down. Cached creds point
                // at a non-existent room; the next ``start()`` must
                // request a fresh offer.
                invalidateCredentialCache()
                state = .failed(.streamDropped(message))
                await tearDownSession()
                await rollbackDeviceStream()
            case .networkFailure:
                // Network-class drops are almost always transient: the
                // app was backgrounded (iOS suspends the socket), Wi-Fi
                // roamed, cellular had a brief hiccup. Surfacing the
                // red error pane for these would make a routine
                // home-button press feel like a crash. Land in
                // ``.disconnected`` with the softened subtitle so the
                // user can tap Watch live to resume. The posterBackdrop
                // (blurred last frame) stays rendered behind the
                // disconnected pane so the transition reads as "paused"
                // rather than "broken."
                //
                // The global ``ConnectionStatusPill`` (reinstated the
                // moment the VM leaves ``.streaming``) communicates any
                // underlying transport issue — the LiveView itself does
                // not need to re-surface it here.
                //
                // Network-class drops invalidate the cache: the
                // underlying path likely changed (Wi-Fi → cellular,
                // VPN re-key) and the LiveKit room may have GC'd
                // the ICE candidate the cached token authorized.
                // Forcing a fresh offer on resume guarantees the
                // dial uses paths the server still recognises.
                invalidateCredentialCache()
                didDropFromNetwork = true
                state = .disconnected
                await tearDownSession()
                await rollbackDeviceStream()
            }
        }
    }
}

// MARK: - One-shot continuation resumer

/// Race helper for ``raceTeardownAgainstStopTimeout``. Two sibling
/// observer tasks each call ``resume()`` when their branch finishes;
/// only the first call resumes the checked continuation, the rest are
/// silent no-ops. Without this guard the continuation would trap on
/// the second ``resume`` invocation.
private final class OneShotResumer: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private let lock = NSLock()

    init(continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
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
