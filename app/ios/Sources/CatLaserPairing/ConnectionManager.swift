import CatLaserDevice
import CatLaserProto
import Foundation

/// Supervisor that keeps a live `DeviceClient` connected to the
/// paired Tailscale endpoint.
///
/// Responsibilities:
///
/// 1. Attach to the injected `NetworkPathMonitor`; hold off attempts
///    while the path is unsatisfied, and try immediately when it
///    flips to satisfied.
/// 2. Open a `DeviceClient` via the injected factory, run
///    `client.connect()`, publish `.connected(client)` on the state
///    stream when ready.
/// 3. Send a heartbeat probe (`GetStatusRequest`) every
///    `heartbeatInterval`. `heartbeatFailureCap` consecutive failures
///    force a reconnect — the client might still report "connected"
///    on paper while the underlying socket is wedged.
/// 4. React to `DeviceClient.events` closing (peer half-close,
///    transport failure) by tearing down and reconnecting.
/// 5. Exponential backoff between attempts: `initialBackoff` doubling
///    up to `maxBackoff`, with multiplicative jitter. A network path
///    satisfied event during backoff immediately retries.
/// 6. `stop()` tears everything down; the client is disconnected,
///    all tasks are cancelled, the state stream terminates.
///
/// Concurrency: a single actor serialises every state transition. All
/// side effects (client lifecycle, heartbeat probes, backoff waits,
/// path-event consumption) run as actor-attached child tasks that
/// re-enter this actor on completion. There is never more than one
/// `connectingTask` or `heartbeatTask` alive.
///
/// The manager is the single source of truth for "is the app talking
/// to the device right now" — consumers (`LiveViewModel`,
/// status-surface widgets, any future REST-to-device bridge) should
/// read the current `DeviceClient` from the `.connected` state and
/// treat any other state as "not available, wait".
public actor ConnectionManager {
    public typealias DeviceClientFactory = @Sendable (DeviceEndpoint) -> DeviceClient
    public typealias JitterSource = @Sendable (ClosedRange<Double>) -> Double
    public typealias HandshakeBuilder = @Sendable () async throws -> String

    /// Tunables for the supervisor loop. Defaults are chosen for a
    /// real iOS device on Wi-Fi with a healthy Tailscale link: 20s
    /// between heartbeat probes, 250ms initial backoff capped at 15s.
    /// Tests override every field with short values.
    ///
    /// Note: individual heartbeat probe timeouts are governed by the
    /// `DeviceClient`'s own `requestTimeout` — the caller that builds
    /// the client via `DeviceClientFactory` chooses that value. A
    /// separate per-probe timeout would double-book timeouts and
    /// leave the underlying request still in-flight on the client
    /// after we gave up on it.
    public struct Configuration: Sendable, Equatable {
        /// Time between heartbeat probes. A probe is a
        /// `GetStatusRequest` round-trip.
        public var heartbeatInterval: TimeInterval

        /// Consecutive heartbeat failures before the supervisor tears
        /// the client down. `2` with a 20s interval = ~40s plus the
        /// client's per-request timeout to detect a wedge.
        public var heartbeatFailureCap: Int

        /// First backoff after a failed connect. Doubles each
        /// subsequent failure up to `maxBackoff`.
        public var initialBackoff: TimeInterval

        /// Ceiling for the backoff ramp.
        public var maxBackoff: TimeInterval

        /// Multiplicative jitter range applied to each computed
        /// backoff duration. `0.15` → `computed * [0.85, 1.15]`.
        public var jitter: Double

        public static let `default` = Configuration(
            heartbeatInterval: 20,
            heartbeatFailureCap: 2,
            initialBackoff: 0.25,
            maxBackoff: 15,
            jitter: 0.15,
        )

        public init(
            heartbeatInterval: TimeInterval,
            heartbeatFailureCap: Int,
            initialBackoff: TimeInterval,
            maxBackoff: TimeInterval,
            jitter: Double,
        ) {
            precondition(heartbeatInterval > 0, "heartbeatInterval must be positive")
            precondition(heartbeatFailureCap >= 1, "heartbeatFailureCap must be >= 1")
            precondition(initialBackoff > 0, "initialBackoff must be positive")
            precondition(maxBackoff >= initialBackoff, "maxBackoff must be >= initialBackoff")
            precondition((0 ..< 1).contains(jitter), "jitter must be in [0, 1)")
            self.heartbeatInterval = heartbeatInterval
            self.heartbeatFailureCap = heartbeatFailureCap
            self.initialBackoff = initialBackoff
            self.maxBackoff = maxBackoff
            self.jitter = jitter
        }
    }

    // MARK: - Stored

    private let endpoint: DeviceEndpoint
    private let clientFactory: DeviceClientFactory
    private let pathMonitor: any NetworkPathMonitor
    private let configuration: Configuration
    private let clock: @Sendable () -> Date
    private let jitter: JitterSource
    /// Closure that produces the `x-device-attestation` header value
    /// threaded into `DeviceClient.connect(handshake:)` on every
    /// reconnect. Nil-permitted only for tests that use the in-memory
    /// transport and don't exercise the real handshake path.
    private let handshakeBuilder: HandshakeBuilder?

    private let stateStream: AsyncStream<ConnectionState>
    private let stateContinuation: AsyncStream<ConnectionState>.Continuation

    // Mutable lifecycle
    private var state: ConnectionState = .idle
    private var pathSatisfied: Bool = false
    private var supervisorTask: Task<Void, Never>?
    private var pathTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var eventsWatcherTask: Task<Void, Never>?
    private var wakeToken: UInt64 = 0
    private var wakeContinuation: CheckedContinuation<Void, Never>?
    private var nextTokenSeed: UInt64 = 0
    private var stopped: Bool = false
    private var attempt: Int = 0

    public init(
        endpoint: DeviceEndpoint,
        clientFactory: @escaping DeviceClientFactory,
        pathMonitor: any NetworkPathMonitor,
        handshakeBuilder: HandshakeBuilder? = nil,
        configuration: Configuration = .default,
        clock: @escaping @Sendable () -> Date = { Date() },
        jitter: @escaping JitterSource = { Double.random(in: $0) },
    ) {
        self.endpoint = endpoint
        self.clientFactory = clientFactory
        self.pathMonitor = pathMonitor
        self.handshakeBuilder = handshakeBuilder
        self.configuration = configuration
        self.clock = clock
        self.jitter = jitter

        var captured: AsyncStream<ConnectionState>.Continuation!
        self.stateStream = AsyncStream(bufferingPolicy: .unbounded) { continuation in
            captured = continuation
        }
        self.stateContinuation = captured
    }

    // MARK: - Public API

    /// Current supervisor state. Reading this races with transitions —
    /// consumers that need every transition should iterate `states`.
    public var currentState: ConnectionState { state }

    /// The paired endpoint this supervisor targets. Immutable per
    /// instance; repairing to a new endpoint requires building a new
    /// `ConnectionManager`.
    public var currentEndpoint: DeviceEndpoint { endpoint }

    /// State transitions, in order. Iterating terminates when
    /// `stop()` is called.
    public nonisolated var states: AsyncStream<ConnectionState> {
        stateStream
    }

    /// Start the supervisor. No-op after the first call. Safe to call
    /// after `stop()` only by discarding the instance and building a
    /// new one — once a supervisor has been stopped its streams are
    /// finished.
    public func start() async {
        guard supervisorTask == nil, !stopped else { return }

        let pathStream = await pathMonitor.start()
        pathTask = Task { [weak self] in
            for await event in pathStream {
                await self?.handlePathEvent(event)
            }
            await self?.handlePathStreamEnded()
        }

        supervisorTask = Task { [weak self] in
            await self?.runSupervisor()
        }
    }

    /// Tear the supervisor down. Disconnects the active client,
    /// cancels every task, finishes the state stream. Idempotent.
    public func stop() async {
        guard !stopped else { return }
        stopped = true

        // Wake any parked phase unconditionally so the supervisor
        // observes `stopped` and returns.
        wakeCurrentParked()

        supervisorTask?.cancel()
        supervisorTask = nil

        heartbeatTask?.cancel()
        heartbeatTask = nil

        eventsWatcherTask?.cancel()
        eventsWatcherTask = nil

        pathTask?.cancel()
        pathTask = nil

        if case let .connected(client) = state {
            await client.disconnect()
        }
        await pathMonitor.stop()

        transition(to: .idle)
        stateContinuation.finish()
    }

    // MARK: - Path events

    private func handlePathEvent(_ event: NetworkPathEvent) {
        switch event {
        case .satisfied:
            pathSatisfied = true
            // Wake the supervisor only if it is actually waiting on a
            // wake-up signal (waiting-for-network or backing-off).
            // During an active connection the heartbeat + events
            // watcher own failure detection; a transient Wi-Fi→LTE
            // hop should not tear a working connection down.
            switch state {
            case .waitingForNetwork, .backingOff:
                wakeCurrentParked()
            case .idle, .connecting, .connected, .failed:
                break
            }
        case .unsatisfied:
            pathSatisfied = false
            // Do NOT force-disconnect on unsatisfied — NWPathMonitor
            // reports `.unsatisfied` on every short-lived interface
            // flap (screen off, Wi-Fi roam). Let the heartbeat +
            // events watcher catch a genuinely-dead connection. We
            // only use unsatisfied to avoid *starting* new attempts.
        }
    }

    private func handlePathStreamEnded() {
        // The monitor finished its stream. Treat as "monitor no longer
        // authoritative" — the supervisor continues but will no longer
        // benefit from path hints. Do not transition state.
    }

    // MARK: - Supervisor loop

    private func runSupervisor() async {
        while !stopped, !Task.isCancelled {
            if !pathSatisfied {
                transition(to: .waitingForNetwork)
                await awaitPathChange()
                if stopped { return }
                continue
            }

            attempt += 1
            transition(to: .connecting(attempt: attempt))

            let client = clientFactory(endpoint)
            do {
                try await client.connect(handshake: handshakeBuilder)
            } catch {
                if stopped { return }
                await scheduleBackoff()
                continue
            }

            if stopped {
                await client.disconnect()
                return
            }

            // Connected. Reset attempt count for the next disconnect
            // and enter `.connected`; observe events + heartbeat.
            attempt = 0
            transition(to: .connected(client))
            startEventsWatcher(for: client)
            startHeartbeat(for: client)

            await awaitDisconnect()
            if stopped { return }
            // Dropped out of `.connected`; body already transitioned
            // us to a non-connected state. Loop around and reconnect.
        }
    }

    /// Block until `handlePathEvent(.satisfied)` fires or `stop()` is
    /// called. Returns immediately if the path is already satisfied.
    private func awaitPathChange() async {
        guard !pathSatisfied, !stopped else { return }
        _ = await park()
    }

    /// Wait until the current `.connected` session ends (events stream
    /// finished OR heartbeat cap exceeded OR stop() called).
    private func awaitDisconnect() async {
        _ = await park()
    }

    private func scheduleBackoff() async {
        let interval = computeBackoff()
        let deadline = clock().addingTimeInterval(interval)
        transition(to: .backingOff(until: deadline, attempt: attempt))
        await sleepOrResume(seconds: interval)
    }

    private func computeBackoff() -> TimeInterval {
        let base = configuration.initialBackoff
        let raw = min(base * pow(2.0, Double(max(attempt - 1, 0))), configuration.maxBackoff)
        let j = configuration.jitter
        let lo = max(raw * (1.0 - j), 0.0)
        let hi = raw * (1.0 + j)
        return max(jitter(lo ... hi), 0.0)
    }

    private func sleepOrResume(seconds: TimeInterval) async {
        let token = await park { localToken in
            let nanos = UInt64(max(seconds, 0.0) * 1_000_000_000)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: nanos)
                await self?.wake(token: localToken)
            }
        }
        _ = token
    }

    /// Suspend the supervisor on a fresh wake-token and return the
    /// token used to park. Re-entry is allowed: a previous parker's
    /// wake-attempt with a stale token is ignored.
    private func park(onTokenSet: ((UInt64) -> Void)? = nil) async -> UInt64 {
        nextTokenSeed &+= 1
        let token = nextTokenSeed
        wakeToken = token
        onTokenSet?(token)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if stopped {
                continuation.resume()
                return
            }
            wakeContinuation = continuation
        }
        return token
    }

    /// Wake the parked supervisor if its token matches. Stale tokens
    /// are silently ignored.
    private func wake(token: UInt64) {
        guard wakeToken == token else { return }
        wakeCurrentParked()
    }

    /// Wake the currently-parked supervisor unconditionally. Bumps
    /// the token so stale resumptions do not fire later.
    private func wakeCurrentParked() {
        let continuation = wakeContinuation
        wakeContinuation = nil
        wakeToken &+= 1
        continuation?.resume()
    }

    // MARK: - Heartbeat

    private func startHeartbeat(for client: DeviceClient) {
        heartbeatTask?.cancel()
        let interval = configuration.heartbeatInterval
        let cap = configuration.heartbeatFailureCap
        heartbeatTask = Task { [weak self] in
            let nanos = UInt64(interval * 1_000_000_000)
            var consecutiveFailures = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { return }
                guard let self else { return }
                let ok = await self.performHeartbeat(on: client)
                if ok {
                    consecutiveFailures = 0
                } else {
                    consecutiveFailures += 1
                    if consecutiveFailures >= cap {
                        await self.handleHeartbeatExceeded(client: client)
                        return
                    }
                }
            }
        }
    }

    private func performHeartbeat(on client: DeviceClient) async -> Bool {
        var request = Catlaser_App_V1_AppRequest()
        request.getStatus = Catlaser_App_V1_GetStatusRequest()
        do {
            _ = try await client.request(request)
            return true
        } catch {
            return false
        }
    }

    private func handleHeartbeatExceeded(client: DeviceClient) async {
        // Only act if the heartbeat loop is still associated with
        // this client. A disconnect that already happened would have
        // nulled `heartbeatTask` via `teardownConnected`.
        guard case let .connected(active) = state, active === client else { return }
        await teardownConnected(client: client)
    }

    // MARK: - Events watcher

    private func startEventsWatcher(for client: DeviceClient) {
        eventsWatcherTask?.cancel()
        let stream = client.events
        eventsWatcherTask = Task { [weak self, client] in
            for await _ in stream {
                if Task.isCancelled { return }
            }
            // End-of-stream means the DeviceClient has closed. If
            // we're still marked connected to THIS client, tear it
            // down and reconnect.
            guard let self else { return }
            await self.handleEventsStreamEnded(client: client)
        }
    }

    private func handleEventsStreamEnded(client: DeviceClient) async {
        guard case let .connected(active) = state, active === client else { return }
        await teardownConnected(client: client)
    }

    // MARK: - Teardown + reconnect trigger

    private func teardownConnected(client: DeviceClient) async {
        guard case let .connected(active) = state, active === client else { return }
        heartbeatTask?.cancel()
        heartbeatTask = nil
        eventsWatcherTask?.cancel()
        eventsWatcherTask = nil
        await client.disconnect()
        // Reset attempt so the first reconnect after a clean session
        // shows as attempt 1 again rather than continuing whatever
        // backoff ramp was in flight before the session succeeded.
        attempt = 0
        // Wake the supervisor's `awaitDisconnect` — it loops back to
        // the top and drives the next state transition itself.
        wakeCurrentParked()
    }

    // MARK: - Transitions

    private func transition(to newState: ConnectionState) {
        guard newState != state else { return }
        state = newState
        stateContinuation.yield(newState)
    }
}
