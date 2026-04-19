import CatLaserProto
import Foundation
import Observation

/// Multi-consumer fanout over ``DeviceClient/events``.
///
/// ``DeviceClient`` documents its ``events`` ``AsyncStream`` as a
/// single-consumer surface: two for-await loops against it race, the
/// second loop starves, and the device-pushed event delivery becomes
/// non-deterministic. That constraint forced an earlier architecture
/// where only ``HistoryViewModel`` subscribed directly — every other
/// screen that could benefit from ``StatusUpdate`` / ``SessionSummary``
/// / ``HopperEmpty`` had no seam to observe them.
///
/// ``DeviceEventBroker`` adopts the one allowed consumer and fans the
/// events out to N subscribers:
///
/// 1. ``latestStatus``, ``latestStatusReceivedAt``,
///    ``latestSessionSummary``, ``latestHopperEmptyAt`` are published
///    as ``@Observable`` properties so SwiftUI views bind directly and
///    re-render on every device push.
/// 2. ``events()`` hands out per-subscriber ``AsyncStream`` handles for
///    event types whose consumption is flow-shaped — e.g. the
///    ``HistoryViewModel/NewCatDetected`` naming queue, where every
///    emission must reach the subscriber and be acted on (not just the
///    latest). Each call returns a fresh stream; each stream finishes
///    when the broker stops, when the per-stream consumer cancels its
///    iteration, or when the underlying device connection closes.
///
/// Lifecycle is owned by the composition: ``start()`` attaches the
/// single consumer, ``stop()`` tears it down and finishes every
/// outstanding subscription. A new ``DeviceClient`` (produced by a
/// supervisor reconnect) requires a new broker instance — the old
/// broker's ``start()`` cannot be re-armed after ``stop()``.
///
/// Threading: ``@MainActor``-isolated so view-layer observers read
/// without cross-actor hops. The internal pump task reads the device
/// stream on the cooperative pool and hops back to the main actor for
/// each emission; since SwiftUI consumes on the main actor this avoids
/// a double hop.
@MainActor
@Observable
public final class DeviceEventBroker {
    // MARK: - Observable state

    /// Most recent ``StatusUpdate`` pushed by the device. Nil until the
    /// first status lands — use ``latestStatusReceivedAt`` to tell "no
    /// status yet" apart from "status was once here but has aged out".
    public private(set) var latestStatus: Catlaser_App_V1_StatusUpdate?

    /// Wall-clock reading at which ``latestStatus`` was observed. Nil
    /// when no status has arrived. Views that render freshness
    /// indicators ("last updated 3s ago") compute the age against this.
    public private(set) var latestStatusReceivedAt: Date?

    /// Most recent ``SessionSummary`` — the post-session synopsis the
    /// device pushes on state-machine exit. Nil until the first summary
    /// lands.
    public private(set) var latestSessionSummary: Catlaser_App_V1_SessionSummary?

    /// Wall-clock reading at which ``latestSessionSummary`` was
    /// observed. Paired with the payload for views that render a
    /// "just ended" banner for a bounded window.
    public private(set) var latestSessionSummaryReceivedAt: Date?

    /// Wall-clock reading of the most recent ``HopperEmpty`` event.
    /// Nil until the device reports an empty hopper. Distinct from
    /// ``latestStatus/hopperLevel`` because the latter is a steady-state
    /// reading on a heartbeat while the former is an edge-triggered
    /// notification the product uses to drive push notifications.
    public private(set) var latestHopperEmptyAt: Date?

    // MARK: - Dependencies

    private let client: DeviceClient
    private let clock: @Sendable () -> Date

    // MARK: - Internal state

    private var pumpTask: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<Catlaser_App_V1_DeviceEvent>.Continuation] = [:]
    private var isStopped: Bool = false

    // MARK: - Init

    public init(
        client: DeviceClient,
        clock: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.client = client
        self.clock = clock
    }

    // MARK: - Lifecycle

    /// Start consuming the device client's events stream. Idempotent:
    /// repeated calls while the pump is already running are dropped
    /// on the floor. A ``start()`` after ``stop()`` is rejected — the
    /// device client's events stream finishes on disconnect and cannot
    /// be re-opened, so re-arming a stopped broker would silently
    /// consume nothing.
    public func start() {
        guard pumpTask == nil, !isStopped else { return }
        let stream = client.events
        pumpTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                // ``ingest`` is MainActor-isolated and non-async;
                // hopping via ``MainActor.run`` makes the actor
                // isolation transition explicit (so Swift 6 stops
                // warning on the optional-chained ``await self?.x``
                // shape) and guards against a nil-self no-op.
                guard let strongSelf = self else { return }
                await MainActor.run {
                    strongSelf.ingest(event)
                }
            }
            // Underlying stream finished (connection closed, actor
            // disconnected, cancellation). Route teardown through
            // the MainActor since the broker's state is isolated
            // there.
            guard let strongSelf = self else { return }
            await MainActor.run {
                strongSelf.handleStreamFinished()
            }
        }
    }

    /// Tear the broker down. Cancels the pump and finishes every
    /// outstanding ``events()`` subscription so downstream for-await
    /// loops exit cleanly. Idempotent.
    ///
    /// The underlying ``DeviceClient`` is unaffected — lifecycle of the
    /// device connection is owned by the ``ConnectionManager``.
    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        pumpTask?.cancel()
        pumpTask = nil
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll(keepingCapacity: false)
    }

    // No deinit: ``@MainActor``-isolated types cannot touch their
    // isolated state from deinit. The subscribers map and pumpTask are
    // cleared explicitly by ``stop()``; consumers that fail to call
    // stop leak at most one Task per broker (captured weakly), which
    // exits as soon as the device stream finishes.

    // MARK: - Subscription API

    /// Open a fanout subscription onto the device event stream. Each
    /// call returns an independent ``AsyncStream`` that sees every
    /// event flowing through this broker from the subscription point
    /// forward. Existing "latest X" observable properties are populated
    /// concurrently — a consumer can both watch ``latestStatus`` and
    /// iterate ``events()`` without double-handling.
    ///
    /// Buffering: ``BufferingPolicy/unbounded`` per subscriber. The
    /// device's push rate is low (status at 1–5 Hz, others sporadic)
    /// and a transient main-actor stall should not drop events —
    /// ``HistoryViewModel`` for example must not miss a
    /// ``NewCatDetected`` push because the UI was off-screen when it
    /// arrived.
    ///
    /// Cancellation: when the consumer's iteration terminates (the
    /// Task is cancelled or the for-await loop exits early) the
    /// stream's ``onTermination`` handler removes the continuation
    /// from the broker's map. A broker-level ``stop()`` finishes every
    /// outstanding continuation directly. Either path is safe; both
    /// are idempotent.
    public func events() -> AsyncStream<Catlaser_App_V1_DeviceEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Catlaser_App_V1_DeviceEvent.self,
            bufferingPolicy: .unbounded,
        )
        if isStopped {
            // Broker already torn down; hand back an empty stream that
            // finishes immediately so the consumer's for-await loop
            // exits without hanging. Registering a continuation in a
            // stopped broker would leak it past teardown.
            continuation.finish()
            return stream
        }
        let id = UUID()
        // ``onTermination`` fires on any teardown path — consumer
        // cancels its task, for-await loop breaks, the stream is
        // finished by ``stop()``. The map mutation must hop back to
        // the MainActor; the broker is the only writer.
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.removeSubscriber(id)
            }
        }
        subscribers[id] = continuation
        return stream
    }

    // MARK: - Test hooks

    /// Test-only: count of outstanding ``events()`` subscribers. Used
    /// by the broker's unit tests to assert cleanup invariants.
    public var subscriberCount: Int { subscribers.count }

    /// Test-only: whether the pump task is currently running.
    public var isPumping: Bool { pumpTask != nil }

    // MARK: - Private

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private func ingest(_ event: Catlaser_App_V1_DeviceEvent) {
        // Request-keyed responses flow through the DeviceClient's
        // correlated continuations; the unsolicited event surface (the
        // only path that reaches this pump) only carries request_id=0
        // frames. Re-assert that invariant defensively — a refactor
        // that routes a correlated response here by accident would
        // otherwise leak a request_id alongside the payload.
        guard event.requestID == 0 else { return }
        updateObservableState(with: event)
        fanout(event)
    }

    private func updateObservableState(with event: Catlaser_App_V1_DeviceEvent) {
        let now = clock()
        switch event.event {
        case let .statusUpdate(payload):
            latestStatus = payload
            latestStatusReceivedAt = now
        case let .sessionSummary(payload):
            latestSessionSummary = payload
            latestSessionSummaryReceivedAt = now
        case .hopperEmpty:
            latestHopperEmptyAt = now
        default:
            // Other unsolicited events (new-cat, diagnostic, error)
            // are flow-shaped — consumers handle them via ``events()``
            // rather than a latest-value snapshot.
            return
        }
    }

    private func fanout(_ event: Catlaser_App_V1_DeviceEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    private func handleStreamFinished() {
        // Underlying device stream is closed. Mark ourselves as
        // stopped and finish every outstanding subscriber so their
        // for-await loops exit — otherwise a consumer's task parks
        // forever on the closed stream.
        guard !isStopped else { return }
        isStopped = true
        pumpTask = nil
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll(keepingCapacity: false)
    }
}
