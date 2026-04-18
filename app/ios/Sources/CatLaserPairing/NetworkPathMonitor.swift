import Foundation

/// Path-level reachability signal for the connection supervisor.
///
/// Emits one event per observed transition between "offline" and
/// "online". The supervisor uses these to cancel exponential backoff
/// early — a Wi-Fi drop that recovers in 8 seconds should reconnect
/// immediately on recovery, not wait out a 30-second backoff.
///
/// ## Events
///
/// * `.satisfied` — an interface reports a usable path (Wi-Fi, cellular,
///   Ethernet, Tailscale). Duplicate satisfied events ARE emitted when
///   the path changes (e.g. switching from Wi-Fi to cellular); the
///   supervisor treats each as a reconnect opportunity.
/// * `.unsatisfied` — no usable path. The supervisor stops retrying
///   until the next `.satisfied` arrives.
///
/// The initial state is NOT inferred — `start()` is expected to emit
/// the current state as its first event so the supervisor does not
/// have to poll.
public protocol NetworkPathMonitor: Sendable {
    /// Start monitoring and return the event stream. Called exactly
    /// once per monitor instance. Calling twice is a programmer
    /// error; implementations SHOULD fail loudly (precondition /
    /// fatalError) rather than silently return a stale stream.
    func start() async -> AsyncStream<NetworkPathEvent>

    /// Tear the monitor down. Idempotent. Causes the stream from
    /// `start()` to finish.
    func stop() async
}

public enum NetworkPathEvent: Sendable, Equatable {
    case satisfied
    case unsatisfied
}

#if canImport(Network)
import Network

/// `NWPathMonitor`-backed implementation.
///
/// `NWPathMonitor` delivers its updates on a caller-supplied dispatch
/// queue; a dedicated serial queue linearises them. The stream is
/// created in `start()` with an unbounded buffer so a burst of path
/// changes while the consumer is slow does not drop events.
public final class SystemNetworkPathMonitor: NetworkPathMonitor, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "catlaser.pairing.network-path", qos: .utility)
    private let state = MonitorState()

    public init() {}

    public func start() async -> AsyncStream<NetworkPathEvent> {
        let (stream, continuation) = AsyncStream<NetworkPathEvent>.makeStream(bufferingPolicy: .unbounded)
        let installed = await state.install(continuation: continuation)
        guard installed else {
            // Already started — the second call is a bug. Return a
            // fresh empty stream so the caller does not deadlock.
            continuation.finish()
            return stream
        }
        monitor.pathUpdateHandler = { path in
            let event: NetworkPathEvent = (path.status == .satisfied) ? .satisfied : .unsatisfied
            continuation.yield(event)
        }
        monitor.start(queue: queue)
        return stream
    }

    public func stop() async {
        let continuation = await state.finish()
        continuation?.finish()
        monitor.cancel()
    }

    private actor MonitorState {
        private var continuation: AsyncStream<NetworkPathEvent>.Continuation?
        private var started = false

        func install(continuation: AsyncStream<NetworkPathEvent>.Continuation) -> Bool {
            guard !started else { return false }
            started = true
            self.continuation = continuation
            return true
        }

        func finish() -> AsyncStream<NetworkPathEvent>.Continuation? {
            let c = continuation
            continuation = nil
            return c
        }
    }
}
#endif
