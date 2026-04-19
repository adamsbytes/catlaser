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

    /// Construct the transport. Throws
    /// :enum:`TailscaleInterfaceError.noTailscaleInterfaceAvailable`
    /// when the resolver reports no ``utun*`` interface carrying a
    /// Tailscale-shaped address — production callers
    /// (`ConnectionManager`) treat this as transient and retry with
    /// backoff rather than terminally failing the pairing.
    ///
    /// - Parameters:
    ///   - endpoint: validated tailnet address + port.
    ///   - resolver: supplies the ``utunN`` to pin the
    ///     ``NWConnection`` to. Defaults to the production
    ///     ``getifaddrs``-backed resolver; tests pass an injected
    ///     resolver so they exercise the "Tailscale down" branch
    ///     without manipulating the real network stack.
    public init(
        endpoint: DeviceEndpoint,
        resolver: any TailscaleInterfaceResolver = GetifaddrsTailscaleResolver(),
    ) throws(TailscaleInterfaceError) {
        self.endpoint = endpoint
        self.queue = DispatchQueue(
            label: "catlaser.device.transport.\(endpoint.host).\(endpoint.port)",
            qos: .userInitiated,
        )

        // Fail CLOSED if Tailscale isn't up. An unpinned NWConnection
        // against a 100.x.x.x address follows the kernel's routing
        // table; a profile-installed VPN advertising a more-specific
        // route for 100.64.0.0/10 would otherwise steer the socket
        // onto an attacker interface. Running the resolver before
        // building any NW object means we never create a
        // half-configured connection.
        let candidates = resolver.enumerate()
        guard let chosen = candidates.first else {
            // Rare but real: the user paused Tailscale or it's still
            // booting after a device restart. The supervisor treats
            // this as transient and retries.
            throw .noTailscaleInterfaceAvailable
        }

        let params = NWParameters.tcp
        // Belt-and-braces: exclude every non-utun interface type
        // explicitly. Even if `requiredInterface` is somehow
        // unrespected (OS bug, future API change), the NWConnection
        // refuses to fall back to Wi-Fi / cellular / Ethernet —
        // fail-closed is the only acceptable posture here.
        params.prohibitedInterfaceTypes = [.wifi, .cellular, .wiredEthernet, .loopback]
        // Pin to the specific utun. `requiredInterface` accepts an
        // NWInterface; we look it up by name from the current path
        // snapshot. Falling back to `requiredInterfaceType = .other`
        // alone would accept *any* non-wifi/cellular/ethernet
        // interface, which includes a second rogue VPN tunnel.
        let monitor = NWPathMonitor()
        let targetInterface = monitor.currentPath.availableInterfaces.first(where: { $0.name == chosen.name })
        monitor.cancel()
        params.requiredInterface = targetInterface
        params.requiredInterfaceType = .other

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
