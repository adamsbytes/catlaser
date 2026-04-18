import CatLaserDevice
import CatLaserDeviceTestSupport
import CatLaserPairing
import CatLaserPairingTestSupport
import CatLaserProto
import Foundation
import Testing

@Suite("ConnectionManager", .serialized)
struct ConnectionManagerTests {
    // MARK: - Fixture

    private func makeEndpoint() throws -> DeviceEndpoint {
        try DeviceEndpoint(host: "100.64.1.7", port: 9820)
    }

    /// Tight configuration so the suite completes in seconds, not
    /// tens of seconds. Real-world tunables live in
    /// `ConnectionManager.Configuration.default`; this file exists
    /// because the real defaults would make the suite take tens of
    /// seconds to exercise the heartbeat and backoff paths.
    private func makeConfig(
        heartbeatInterval: TimeInterval = 0.05,
        heartbeatFailureCap: Int = 2,
        initialBackoff: TimeInterval = 0.02,
        maxBackoff: TimeInterval = 0.1,
    ) -> ConnectionManager.Configuration {
        ConnectionManager.Configuration(
            heartbeatInterval: heartbeatInterval,
            heartbeatFailureCap: heartbeatFailureCap,
            initialBackoff: initialBackoff,
            maxBackoff: maxBackoff,
            jitter: 0.0,
        )
    }

    /// Scripted factory: maintain a shared list of transports the
    /// factory dispenses in order. Tests pull the transport to reply
    /// on it, then observe the next state.
    private final class ScriptedFactory: @unchecked Sendable {
        private let lock = NSLock()
        private var transports: [InMemoryDeviceTransport] = []
        private var nextIndex: Int = 0

        func enqueue(_ transport: InMemoryDeviceTransport) {
            lock.lock(); defer { lock.unlock() }
            transports.append(transport)
        }

        /// Closure-friendly factory.
        func factory() -> ConnectionManager.DeviceClientFactory {
            { [self] _ in
                let transport = self.takeNext()
                return DeviceClient(transport: transport, requestTimeout: 2.0)
            }
        }

        private func takeNext() -> InMemoryDeviceTransport {
            lock.lock(); defer { lock.unlock() }
            if nextIndex < transports.count {
                let t = transports[nextIndex]
                nextIndex += 1
                return t
            }
            // Out of scripted transports — create a fresh one so the
            // test surfaces "connected but no one answering" instead
            // of a crash.
            let t = InMemoryDeviceTransport()
            transports.append(t)
            nextIndex = transports.count
            return t
        }

        func transportAt(_ index: Int) -> InMemoryDeviceTransport? {
            lock.lock(); defer { lock.unlock() }
            return index < transports.count ? transports[index] : nil
        }

        var dispensed: Int {
            lock.lock(); defer { lock.unlock() }
            return nextIndex
        }
    }

    // MARK: - Helpers

    /// Wait for a specific connection-state predicate on the supervisor
    /// within a time budget, to avoid race-y polling in tests.
    private func waitForState(
        _ predicate: @Sendable @escaping (ConnectionState) -> Bool,
        on manager: ConnectionManager,
        timeout: TimeInterval = 3.0,
    ) async -> ConnectionState? {
        let deadline = Date().addingTimeInterval(timeout)
        let stream = manager.states
        let stateTask = Task<ConnectionState?, Never> {
            for await next in stream {
                if predicate(next) { return next }
                if Date() > deadline { return nil }
            }
            return nil
        }
        defer { stateTask.cancel() }
        return await withTaskCancellationHandler {
            await stateTask.value
        } onCancel: {
            stateTask.cancel()
        }
    }

    /// Reply to a single heartbeat (GetStatusRequest) that the
    /// supervisor sends on the given transport.
    private func replyToHeartbeat(
        on transport: InMemoryDeviceTransport,
        timeout: TimeInterval = 1.0,
    ) async throws {
        let outgoing = try await transport.nextAppRequest(timeout: timeout)
        var reply = Catlaser_App_V1_DeviceEvent()
        reply.statusUpdate = Catlaser_App_V1_StatusUpdate()
        reply.requestID = outgoing.requestID
        try transport.deliver(event: reply)
    }

    // MARK: - Tests

    @Test
    func startsConnectsAndReachesConnected() async throws {
        let script = ScriptedFactory()
        let transport = InMemoryDeviceTransport()
        script.enqueue(transport)

        let monitor = FakeNetworkPathMonitor(currentAtStart: .satisfied)
        let manager = ConnectionManager(
            endpoint: try makeEndpoint(),
            clientFactory: script.factory(),
            pathMonitor: monitor,
            configuration: makeConfig(),
        )
        await manager.start()
        let connected = await waitForState({
            if case .connected = $0 { return true }
            return false
        }, on: manager)
        #expect(connected != nil)

        await manager.stop()
    }

    @Test
    func staysInWaitingForNetworkUntilPathSatisfied() async throws {
        let script = ScriptedFactory()
        script.enqueue(InMemoryDeviceTransport())

        let monitor = FakeNetworkPathMonitor(currentAtStart: .unsatisfied)
        let manager = ConnectionManager(
            endpoint: try makeEndpoint(),
            clientFactory: script.factory(),
            pathMonitor: monitor,
            configuration: makeConfig(),
        )
        await manager.start()

        let waiting = await waitForState({
            $0 == .waitingForNetwork
        }, on: manager, timeout: 1.0)
        #expect(waiting == .waitingForNetwork)
        #expect(script.dispensed == 0)

        // Now let the network come up; we should connect.
        await monitor.emit(.satisfied)
        let connected = await waitForState({
            if case .connected = $0 { return true }
            return false
        }, on: manager, timeout: 3.0)
        #expect(connected != nil)
        #expect(script.dispensed >= 1)

        await manager.stop()
    }

    @Test
    func reconnectsAfterPeerHalfClose() async throws {
        let script = ScriptedFactory()
        let first = InMemoryDeviceTransport()
        let second = InMemoryDeviceTransport()
        script.enqueue(first)
        script.enqueue(second)

        let monitor = FakeNetworkPathMonitor(currentAtStart: .satisfied)
        let manager = ConnectionManager(
            endpoint: try makeEndpoint(),
            clientFactory: script.factory(),
            pathMonitor: monitor,
            configuration: makeConfig(heartbeatInterval: 2.0), // slow — avoid interfering
        )
        await manager.start()

        _ = await waitForState({
            if case .connected = $0 { return true }
            return false
        }, on: manager)

        // Drop the peer — manager should reconnect with the second
        // transport.
        first.finishPeer()

        // Wait for second connection.
        let secondConnected = await waitForState({
            if case let .connected(client) = $0 {
                // Need to distinguish by identity — we can't directly,
                // but the second transport only delivers to the
                // second client.
                _ = client
                return true
            }
            return false
        }, on: manager, timeout: 3.0)
        _ = secondConnected
        #expect(script.dispensed >= 2)

        await manager.stop()
    }

    @Test
    func heartbeatFailureTriggersReconnect() async throws {
        let script = ScriptedFactory()
        let first = InMemoryDeviceTransport()
        let second = InMemoryDeviceTransport()
        script.enqueue(first)
        script.enqueue(second)

        let monitor = FakeNetworkPathMonitor(currentAtStart: .satisfied)
        let manager = ConnectionManager(
            endpoint: try makeEndpoint(),
            clientFactory: script.factory(),
            pathMonitor: monitor,
            configuration: makeConfig(
                heartbeatInterval: 0.05,
                heartbeatFailureCap: 1,
                initialBackoff: 0.02,
                maxBackoff: 0.05,
            ),
        )
        await manager.start()

        _ = await waitForState({
            if case .connected = $0 { return true }
            return false
        }, on: manager)

        // Silently drop all heartbeats on the first transport.
        // After the cap the supervisor tears down and opens the
        // second.
        _ = await waitForState({
            // Wait until second transport is dispensed.
            _ = $0
            return script.dispensed >= 2
        }, on: manager, timeout: 3.0)
        #expect(script.dispensed >= 2)

        await manager.stop()
    }

    @Test
    func backoffReattemptsAfterConnectFailure() async throws {
        // Use a factory that returns transports that fail `open()`
        // on the first attempt and succeed on the second.
        let failingTransport = FailOnOpenTransport()
        let workingTransport = InMemoryDeviceTransport()

        let failCount = AtomicInt()
        let factory: ConnectionManager.DeviceClientFactory = { _ in
            if failCount.incrementAndGet() == 1 {
                return DeviceClient(transport: failingTransport, requestTimeout: 1.0)
            } else {
                return DeviceClient(transport: workingTransport, requestTimeout: 1.0)
            }
        }

        let monitor = FakeNetworkPathMonitor(currentAtStart: .satisfied)
        let manager = ConnectionManager(
            endpoint: try DeviceEndpoint(host: "100.64.1.7", port: 9820),
            clientFactory: factory,
            pathMonitor: monitor,
            configuration: makeConfig(
                heartbeatInterval: 5.0, // don't interfere
                heartbeatFailureCap: 2,
                initialBackoff: 0.02,
                maxBackoff: 0.1,
            ),
        )
        await manager.start()

        let connected = await waitForState({
            if case .connected = $0 { return true }
            return false
        }, on: manager, timeout: 3.0)
        #expect(connected != nil)

        await manager.stop()
    }

    @Test
    func networkChangeWakesBackoffImmediately() async throws {
        let failingTransport = FailOnOpenTransport()
        let workingTransport = InMemoryDeviceTransport()

        let failCount = AtomicInt()
        let factory: ConnectionManager.DeviceClientFactory = { _ in
            if failCount.incrementAndGet() == 1 {
                return DeviceClient(transport: failingTransport, requestTimeout: 1.0)
            } else {
                return DeviceClient(transport: workingTransport, requestTimeout: 1.0)
            }
        }

        let monitor = FakeNetworkPathMonitor(currentAtStart: .satisfied)
        let manager = ConnectionManager(
            endpoint: try DeviceEndpoint(host: "100.64.1.7", port: 9820),
            clientFactory: factory,
            pathMonitor: monitor,
            configuration: makeConfig(
                heartbeatInterval: 5.0,
                heartbeatFailureCap: 2,
                initialBackoff: 10.0, // long — would stall without path kick
                maxBackoff: 10.0,
            ),
        )
        await manager.start()

        // Wait for backoff state to appear.
        _ = await waitForState({
            if case .backingOff = $0 { return true }
            return false
        }, on: manager, timeout: 3.0)

        // Kick the network; supervisor should retry immediately.
        await monitor.emit(.satisfied)

        let connected = await waitForState({
            if case .connected = $0 { return true }
            return false
        }, on: manager, timeout: 3.0)
        #expect(connected != nil)

        await manager.stop()
    }

    @Test
    func stopFromConnectedTearsDownClient() async throws {
        let script = ScriptedFactory()
        let transport = InMemoryDeviceTransport()
        script.enqueue(transport)

        let monitor = FakeNetworkPathMonitor(currentAtStart: .satisfied)
        let manager = ConnectionManager(
            endpoint: try makeEndpoint(),
            clientFactory: script.factory(),
            pathMonitor: monitor,
            configuration: makeConfig(heartbeatInterval: 5.0),
        )
        await manager.start()

        let state = await waitForState({
            if case .connected = $0 { return true }
            return false
        }, on: manager)
        guard case let .connected(client) = state ?? .idle else {
            Issue.record("never reached connected")
            return
        }

        await manager.stop()

        // After stop, client.isConnected must be false.
        let isConnected = await client.isConnected
        #expect(!isConnected)
    }

    @Test
    func stopWhileWaitingForNetworkIsClean() async throws {
        let script = ScriptedFactory()
        script.enqueue(InMemoryDeviceTransport())
        let monitor = FakeNetworkPathMonitor(currentAtStart: .unsatisfied)
        let manager = ConnectionManager(
            endpoint: try makeEndpoint(),
            clientFactory: script.factory(),
            pathMonitor: monitor,
            configuration: makeConfig(),
        )
        await manager.start()
        _ = await waitForState({ $0 == .waitingForNetwork }, on: manager, timeout: 1.0)
        await manager.stop()

        // After stop, currentState should be .idle.
        let current = await manager.currentState
        #expect(current == .idle)
    }

    @Test
    func sendsHeartbeatProbe() async throws {
        let script = ScriptedFactory()
        let transport = InMemoryDeviceTransport()
        script.enqueue(transport)

        let monitor = FakeNetworkPathMonitor(currentAtStart: .satisfied)
        let manager = ConnectionManager(
            endpoint: try makeEndpoint(),
            clientFactory: script.factory(),
            pathMonitor: monitor,
            configuration: makeConfig(
                heartbeatInterval: 0.05,
                heartbeatFailureCap: 10,
                initialBackoff: 0.02,
                maxBackoff: 0.05,
            ),
        )
        await manager.start()

        _ = await waitForState({
            if case .connected = $0 { return true }
            return false
        }, on: manager)

        // Reply to one heartbeat probe — proves the supervisor is
        // actually sending probes on the wire, not just pretending.
        try await replyToHeartbeat(on: transport, timeout: 1.0)

        await manager.stop()
    }

    @Test
    func doubleStartIsIdempotent() async throws {
        let script = ScriptedFactory()
        script.enqueue(InMemoryDeviceTransport())

        let monitor = FakeNetworkPathMonitor(currentAtStart: .satisfied)
        let manager = ConnectionManager(
            endpoint: try makeEndpoint(),
            clientFactory: script.factory(),
            pathMonitor: monitor,
            configuration: makeConfig(),
        )
        await manager.start()
        await manager.start()
        _ = await waitForState({
            if case .connected = $0 { return true }
            return false
        }, on: manager)
        // Only one transport was dispensed despite the double start.
        #expect(script.dispensed == 1)
        await manager.stop()
    }
}

// MARK: - Test doubles

private final class AtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0

    func incrementAndGet() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

/// Transport whose `open()` always throws, used to test the
/// supervisor's backoff+retry path.
private final class FailOnOpenTransport: DeviceTransport, @unchecked Sendable {
    private let continuationStream: (AsyncThrowingStream<Data, any Error>, AsyncThrowingStream<Data, any Error>.Continuation)
    init() {
        var captured: AsyncThrowingStream<Data, any Error>.Continuation!
        let stream = AsyncThrowingStream<Data, any Error>(bufferingPolicy: .unbounded) { continuation in
            captured = continuation
        }
        self.continuationStream = (stream, captured)
    }

    func open() async throws {
        throw DeviceClientError.connectFailed("simulated")
    }

    func send(_: Data) async throws {
        throw DeviceClientError.notConnected
    }

    var receiveStream: AsyncThrowingStream<Data, any Error> {
        get async { continuationStream.0 }
    }

    func close() async {
        continuationStream.1.finish()
    }
}
