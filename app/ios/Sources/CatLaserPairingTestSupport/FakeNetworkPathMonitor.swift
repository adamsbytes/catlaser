import CatLaserPairing
import Foundation

/// Scriptable `NetworkPathMonitor` for `ConnectionManagerTests`.
///
/// Tests obtain the monitor, pass it to `ConnectionManager.init`,
/// then drive transitions via `emit(_:)`. The first emission is
/// `currentAtStart` — defaulting to `.satisfied` so the supervisor
/// kicks a connect on start without further prompting.
public actor FakeNetworkPathMonitor: NetworkPathMonitor {
    public let currentAtStart: NetworkPathEvent
    private var continuation: AsyncStream<NetworkPathEvent>.Continuation?
    private var stopped: Bool = false

    public init(currentAtStart: NetworkPathEvent = .satisfied) {
        self.currentAtStart = currentAtStart
    }

    public func start() async -> AsyncStream<NetworkPathEvent> {
        let (stream, continuation) = AsyncStream<NetworkPathEvent>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        continuation.yield(currentAtStart)
        if stopped { continuation.finish() }
        return stream
    }

    public func stop() async {
        stopped = true
        continuation?.finish()
        continuation = nil
    }

    /// Push an event to the supervisor. A no-op if `start()` hasn't
    /// run yet or `stop()` has been called.
    public func emit(_ event: NetworkPathEvent) {
        continuation?.yield(event)
    }
}
