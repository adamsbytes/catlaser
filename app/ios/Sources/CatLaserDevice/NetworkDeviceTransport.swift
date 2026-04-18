#if canImport(Network)
import Foundation
import Network

/// `DeviceTransport` implementation backed by `NWConnection`.
///
/// On Apple platforms (iOS / macOS) this is the production transport
/// for the app-to-device TCP channel. Linux SPM test runners compile
/// everything around it but not this file — the whole module is
/// wrapped in `canImport(Network)`. Tests use
/// `CatLaserDeviceTestSupport.InMemoryDeviceTransport` instead.
///
/// Threading:
///
/// * `NWConnection` callbacks fire on the caller-supplied dispatch
///   queue. We use a private serial queue so state updates and
///   receive callbacks are linearised.
/// * `open()` / `send()` / `close()` are marked `async` but delegate
///   into continuation-wrapped NWConnection calls; concurrency is
///   serialised through an internal actor-mutable state tracker that
///   lives entirely behind this type.
/// * `receiveStream` is created once in `init` and yielded into from
///   the receive callback chain. The first consumer gets everything;
///   multiple consumers are a programmer error (the protocol says
///   "exactly one consumer").
public final class NetworkDeviceTransport: DeviceTransport, @unchecked Sendable {
    private let endpoint: DeviceEndpoint
    private let queue: DispatchQueue
    private let connection: NWConnection

    // Receive-stream plumbing. The continuation is captured in init and
    // only ever accessed from `queue`, so the @unchecked Sendable is
    // safe at this boundary.
    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    // Guards `open()` so a double-call is detected and refused.
    private let state = StateTracker()

    public init(endpoint: DeviceEndpoint) {
        self.endpoint = endpoint
        self.queue = DispatchQueue(
            label: "catlaser.device.transport.\(endpoint.host).\(endpoint.port)",
            qos: .userInitiated,
        )

        let params = NWParameters.tcp
        // No multipath; Tailscale gives us one interface and the
        // server is bound to one address. No QUIC either — the
        // Python server speaks plain TCP per spec.
        if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 30
            tcpOptions.keepaliveInterval = 15
            tcpOptions.keepaliveCount = 3
        }
        let host = NWEndpoint.Host(endpoint.host)
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            // `DeviceEndpoint.init` refuses `port == 0`, so this is
            // unreachable in practice. Fall back to a sentinel value
            // that will fail cleanly on `.start(...)`.
            self.connection = NWConnection(host: host, port: .any, using: params)
            let (stream, continuation) = Self.makeStream()
            self.stream = stream
            self.continuation = continuation
            return
        }
        self.connection = NWConnection(host: host, port: port, using: params)
        let (stream, continuation) = Self.makeStream()
        self.stream = stream
        self.continuation = continuation

        self.continuation.onTermination = { [weak self] _ in
            self?.connection.cancel()
        }
    }

    deinit {
        connection.cancel()
        continuation.finish()
    }

    public func open() async throws {
        try await state.transition(to: .opening)
        try await withCheckedThrowingContinuation { (resumption: CheckedContinuation<Void, any Error>) in
            // One-shot; flipped to true from the handler that resumes.
            let resumed = ResumptionGuard()
            connection.stateUpdateHandler = { [weak self] newState in
                guard let self else { return }
                switch newState {
                case .ready:
                    if resumed.tryConsume() {
                        resumption.resume()
                    }
                    self.startReceiveLoop()
                case let .failed(error):
                    self.continuation.finish(throwing: DeviceClientError.transport(error.debugDescription))
                    if resumed.tryConsume() {
                        resumption.resume(throwing: DeviceClientError.connectFailed(error.debugDescription))
                    }
                case let .waiting(error):
                    // "waiting" means NWConnection is retrying with
                    // backoff. Surface as a connect failure so the
                    // caller can decide to back off itself instead of
                    // silently stalling.
                    self.continuation.finish(throwing: DeviceClientError.connectFailed(error.debugDescription))
                    if resumed.tryConsume() {
                        resumption.resume(throwing: DeviceClientError.connectFailed(error.debugDescription))
                    }
                    self.connection.cancel()
                case .cancelled:
                    self.continuation.finish()
                    if resumed.tryConsume() {
                        resumption.resume(throwing: DeviceClientError.cancelled)
                    }
                case .preparing, .setup:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        await state.mark(.open)
    }

    public func send(_ data: Data) async throws {
        guard await state.isOpen else {
            throw DeviceClientError.notConnected
        }
        try await withCheckedThrowingContinuation { (resumption: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    resumption.resume(throwing: DeviceClientError.transport(error.debugDescription))
                } else {
                    resumption.resume()
                }
            })
        }
    }

    public var receiveStream: AsyncThrowingStream<Data, any Error> {
        get async { stream }
    }

    public func close() async {
        await state.mark(.closed)
        connection.cancel()
        continuation.finish()
    }

    // MARK: - Private

    private func startReceiveLoop() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024,
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.continuation.finish(throwing: DeviceClientError.transport(error.debugDescription))
                self.connection.cancel()
                return
            }
            if let data, !data.isEmpty {
                self.continuation.yield(data)
            }
            if isComplete {
                self.continuation.finish(throwing: DeviceClientError.closedByPeer)
                self.connection.cancel()
                return
            }
            // Continue reading.
            self.startReceiveLoop()
        }
    }

    private static func makeStream() -> (AsyncThrowingStream<Data, any Error>, AsyncThrowingStream<Data, any Error>.Continuation) {
        var captured: AsyncThrowingStream<Data, any Error>.Continuation!
        let stream = AsyncThrowingStream<Data, any Error>(bufferingPolicy: .unbounded) { continuation in
            captured = continuation
        }
        return (stream, captured)
    }
}

// MARK: - State tracker

/// Small actor that gates `open()`-at-most-once and lets `send()`
/// fast-fail if the caller skipped or undid the open.
private actor StateTracker {
    enum State { case idle, opening, open, closed }
    private var state: State = .idle

    func transition(to newState: State) throws(DeviceClientError) {
        switch (state, newState) {
        case (.idle, .opening):
            state = .opening
        case (.opening, .open), (.opening, .closed), (.open, .closed):
            state = newState
        case (.closed, _):
            throw .notConnected
        default:
            throw .alreadyConnected
        }
    }

    func mark(_ newState: State) {
        state = newState
    }

    var isOpen: Bool { state == .open }
}

// MARK: - Resumption guard

/// NWConnection's state handler can fire multiple times before and
/// after `.ready`. We must resume the connect continuation exactly
/// once — whichever terminal state arrives first wins.
private final class ResumptionGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false

    func tryConsume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { return false }
        consumed = true
        return true
    }
}
#endif
