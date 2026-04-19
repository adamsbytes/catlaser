import CatLaserDevice
import CatLaserDeviceTestSupport
import CatLaserProto
import Foundation
import Testing

@testable import CatLaserPush

@Suite("PushTokenRegistrar")
struct PushTokenRegistrarTests {
    // MARK: - Fixtures

    private static func makeClient(
        transport: InMemoryDeviceTransport,
    ) async throws -> DeviceClient {
        let client = DeviceClient(transport: transport, requestTimeout: 1.0)
        try await client.connect()
        return client
    }

    private static func makeToken(_ byte: UInt8 = 0xAB) throws -> PushToken {
        try PushToken(rawBytes: Data(repeating: byte, count: PushToken.minimumLength))
    }

    /// Scripted server that captures every request and replies with
    /// a successful ``PushTokenAck``. Used by the happy-path tests.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var registers: [Catlaser_App_V1_RegisterPushTokenRequest] = []
        private var unregisters: [Catlaser_App_V1_UnregisterPushTokenRequest] = []

        func recordRegister(_ req: Catlaser_App_V1_RegisterPushTokenRequest) {
            lock.lock(); defer { lock.unlock() }
            registers.append(req)
        }

        func recordUnregister(_ req: Catlaser_App_V1_UnregisterPushTokenRequest) {
            lock.lock(); defer { lock.unlock() }
            unregisters.append(req)
        }

        var registerCount: Int {
            lock.lock(); defer { lock.unlock() }
            return registers.count
        }

        var unregisterCount: Int {
            lock.lock(); defer { lock.unlock() }
            return unregisters.count
        }

        var lastRegisteredToken: String? {
            lock.lock(); defer { lock.unlock() }
            return registers.last?.token
        }

        var lastRegisteredPlatform: Catlaser_App_V1_PushPlatform? {
            lock.lock(); defer { lock.unlock() }
            return registers.last?.platform
        }

        var lastUnregisteredToken: String? {
            lock.lock(); defer { lock.unlock() }
            return unregisters.last?.token
        }
    }

    private static func makeAckingServer(
        transport: InMemoryDeviceTransport,
        recorder: Recorder,
    ) async -> ScriptedDeviceServer {
        let server = ScriptedDeviceServer(transport: transport) { request in
            switch request.request {
            case let .registerPushToken(register):
                recorder.recordRegister(register)
                var event = Catlaser_App_V1_DeviceEvent()
                event.pushTokenAck = Catlaser_App_V1_PushTokenAck()
                return .reply(event)
            case let .unregisterPushToken(unregister):
                recorder.recordUnregister(unregister)
                var event = Catlaser_App_V1_DeviceEvent()
                event.pushTokenAck = Catlaser_App_V1_PushTokenAck()
                return .reply(event)
            default:
                return .error(code: 99, message: "unexpected")
            }
        }
        await server.run()
        return server
    }

    /// Sink that drains ``PushTokenRegistrar.outcomes`` into a bounded
    /// FIFO queue. One instance per test so the registrar's async
    /// stream is only iterated by a SINGLE consumer (the documented
    /// contract for ``AsyncStream``) — each test's ``next()`` call
    /// pops from the queue without ever re-subscribing.
    ///
    /// The earlier implementation called ``makeAsyncIterator()`` on
    /// every ``next()``, producing two or more concurrent iterators
    /// under Swift Testing's parallel scheduler. On Linux + Swift 6.3
    /// the second iterator would park indefinitely, deadlocking the
    /// enclosing ``withTaskGroup`` because cancelling the sleep-timeout
    /// task still left the iterator task waiting for a value that
    /// would never reach it.
    ///
    /// Construction is a two-step dance: ``init`` stores the stream,
    /// and ``start()`` launches the single consumer Task once the
    /// caller has an actor-isolated reference. Doing both in ``init``
    /// would require capturing `self` in a Task from a nonisolated
    /// initialiser — Swift 6 rejects that because the Task body runs
    /// before ``self`` is fully formed from the isolation's
    /// perspective.
    private actor OutcomeSink {
        private let stream: AsyncStream<PushTokenRegistrar.Outcome>
        private var buffered: [PushTokenRegistrar.Outcome] = []
        private var waiter: CheckedContinuation<PushTokenRegistrar.Outcome?, Never>?
        private var consumerTask: Task<Void, Never>?
        private var finished = false

        init(stream: AsyncStream<PushTokenRegistrar.Outcome>) {
            self.stream = stream
        }

        /// Start the single consumer Task. Idempotent — a second
        /// call is a no-op.
        func start() {
            guard consumerTask == nil else { return }
            consumerTask = Task { [weak self] in
                guard let ownedStream = await self?.stream else { return }
                for await outcome in ownedStream {
                    if Task.isCancelled { return }
                    await self?.handle(outcome)
                }
                await self?.markFinished()
            }
        }

        func stop() {
            consumerTask?.cancel()
            consumerTask = nil
            let w = waiter
            waiter = nil
            w?.resume(returning: nil)
        }

        func next(within timeout: TimeInterval = 2.0) async -> PushTokenRegistrar.Outcome? {
            if !buffered.isEmpty {
                return buffered.removeFirst()
            }
            if finished { return nil }
            // Race the continuation against a bounded timeout. We
            // bind the continuation under actor isolation so a late-
            // arriving outcome cannot double-resume it; the timeout
            // task goes through ``expireWaiter`` which checks the
            // waiter identity before resuming.
            let nanos = UInt64(timeout * 1_000_000_000)
            return await withCheckedContinuation { (continuation: CheckedContinuation<PushTokenRegistrar.Outcome?, Never>) in
                waiter = continuation
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: nanos)
                    await self?.expireWaiter()
                }
            }
        }

        // MARK: - Private

        private func handle(_ outcome: PushTokenRegistrar.Outcome) {
            if let w = waiter {
                waiter = nil
                w.resume(returning: outcome)
                return
            }
            buffered.append(outcome)
        }

        private func markFinished() {
            finished = true
            let w = waiter
            waiter = nil
            w?.resume(returning: nil)
        }

        private func expireWaiter() {
            // Actor-serialised: at most one waiter is live. If it is
            // still set, the timeout fired first — resume with nil.
            // If it is already nil, the outcome landed first and the
            // continuation was resumed; nothing to do.
            guard let w = waiter else { return }
            waiter = nil
            w.resume(returning: nil)
        }
    }

    // MARK: - Happy paths

    @Test
    func registersTokenAfterSetClientAndSetToken() async throws {
        let transport = InMemoryDeviceTransport()
        let client = try await Self.makeClient(transport: transport)
        let recorder = Recorder()
        let server = await Self.makeAckingServer(transport: transport, recorder: recorder)
        defer { Task { await server.stop(); await client.disconnect() } }

        let registrar = PushTokenRegistrar()
        let sink = OutcomeSink(stream: registrar.outcomes)
        await sink.start()
        defer { Task { await sink.stop() } }
        await registrar.setClient(client)
        let token = try Self.makeToken()
        await registrar.setToken(token)

        let outcome = await sink.next()
        #expect(outcome == .registered(token: token))
        #expect(recorder.registerCount == 1)
        #expect(recorder.lastRegisteredToken == token.hex)
        #expect(recorder.lastRegisteredPlatform == .apns)
    }

    @Test
    func settingSameTokenIsNoOp() async throws {
        let transport = InMemoryDeviceTransport()
        let client = try await Self.makeClient(transport: transport)
        let recorder = Recorder()
        let server = await Self.makeAckingServer(transport: transport, recorder: recorder)
        defer { Task { await server.stop(); await client.disconnect() } }

        let registrar = PushTokenRegistrar()
        let sink = OutcomeSink(stream: registrar.outcomes)
        await sink.start()
        defer { Task { await sink.stop() } }
        await registrar.setClient(client)
        let token = try Self.makeToken()
        await registrar.setToken(token)
        _ = await sink.next()
        #expect(recorder.registerCount == 1)

        // Identical token — must not produce a second wire call.
        await registrar.setToken(token)
        // Give the actor a scheduling tick so a buggy impl that
        // fired a second register has a chance to reach the wire.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(recorder.registerCount == 1)
    }

    @Test
    func changedTokenFiresReRegister() async throws {
        let transport = InMemoryDeviceTransport()
        let client = try await Self.makeClient(transport: transport)
        let recorder = Recorder()
        let server = await Self.makeAckingServer(transport: transport, recorder: recorder)
        defer { Task { await server.stop(); await client.disconnect() } }

        let registrar = PushTokenRegistrar()
        let sink = OutcomeSink(stream: registrar.outcomes)
        await sink.start()
        defer { Task { await sink.stop() } }
        await registrar.setClient(client)
        let first = try Self.makeToken(0x01)
        await registrar.setToken(first)
        _ = await sink.next()

        let second = try Self.makeToken(0x02)
        await registrar.setToken(second)
        let outcome = await sink.next()
        #expect(outcome == .registered(token: second))
        #expect(recorder.registerCount == 2)
        #expect(recorder.lastRegisteredToken == second.hex)
    }

    @Test
    func newClientTriggersReRegister() async throws {
        // Simulates ``ConnectionManager`` producing a fresh
        // ``DeviceClient`` after a drop + reconnect. The cached
        // token must re-register against the new client identity.
        let recorder = Recorder()
        let registrar = PushTokenRegistrar()
        let sink = OutcomeSink(stream: registrar.outcomes)
        await sink.start()
        defer { Task { await sink.stop() } }
        let token = try Self.makeToken()

        // First client.
        let transport1 = InMemoryDeviceTransport()
        let client1 = try await Self.makeClient(transport: transport1)
        let server1 = await Self.makeAckingServer(transport: transport1, recorder: recorder)
        await registrar.setClient(client1)
        await registrar.setToken(token)
        _ = await sink.next()
        #expect(recorder.registerCount == 1)

        // Supervisor tears the first client down and hands over a
        // brand-new one — a fresh actor identity, even if the
        // endpoint is unchanged.
        await registrar.setClient(nil)
        await server1.stop()
        await client1.disconnect()

        let transport2 = InMemoryDeviceTransport()
        let client2 = try await Self.makeClient(transport: transport2)
        let server2 = await Self.makeAckingServer(transport: transport2, recorder: recorder)
        defer { Task { await server2.stop(); await client2.disconnect() } }
        await registrar.setClient(client2)

        let outcome = await sink.next()
        #expect(outcome == .registered(token: token))
        #expect(recorder.registerCount == 2,
                "a fresh client must trigger a fresh register even for an unchanged token")
    }

    @Test
    func settingSameClientIsNoOp() async throws {
        let transport = InMemoryDeviceTransport()
        let client = try await Self.makeClient(transport: transport)
        let recorder = Recorder()
        let server = await Self.makeAckingServer(transport: transport, recorder: recorder)
        defer { Task { await server.stop(); await client.disconnect() } }

        let registrar = PushTokenRegistrar()
        let sink = OutcomeSink(stream: registrar.outcomes)
        await sink.start()
        defer { Task { await sink.stop() } }
        await registrar.setClient(client)
        await registrar.setToken(try Self.makeToken())
        _ = await sink.next()

        // Second `setClient` with the SAME client — no-op.
        await registrar.setClient(client)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(recorder.registerCount == 1)
    }

    // MARK: - Unregister paths

    @Test
    func sessionDidSignOutUnregistersAndWipesCache() async throws {
        let transport = InMemoryDeviceTransport()
        let client = try await Self.makeClient(transport: transport)
        let recorder = Recorder()
        let server = await Self.makeAckingServer(transport: transport, recorder: recorder)
        defer { Task { await server.stop(); await client.disconnect() } }

        let registrar = PushTokenRegistrar()
        let sink = OutcomeSink(stream: registrar.outcomes)
        await sink.start()
        defer { Task { await sink.stop() } }
        await registrar.setClient(client)
        let token = try Self.makeToken()
        await registrar.setToken(token)
        _ = await sink.next()
        #expect(recorder.registerCount == 1)

        await registrar.sessionDidSignOut()
        // Drain the .unregistered outcome before the assertions —
        // the actor is single-threaded, so by the time we pop the
        // outcome the wire call has completed.
        let outcome = await sink.next()
        #expect(outcome == .unregistered)
        #expect(recorder.unregisterCount == 1)
        #expect(recorder.lastUnregisteredToken == token.hex)

        // Post sign-out, a setToken with the SAME token value must
        // re-register (cache was wiped).
        await registrar.setToken(token)
        let reregistered = await sink.next()
        #expect(reregistered == .registered(token: token))
        #expect(recorder.registerCount == 2)
    }

    @Test
    func sessionDidSignOutWithNoRegisteredTokenStillEmitsOutcome() async {
        // Sign-out called BEFORE any token was registered must still
        // signal observers so the VM leaves any half-state it might
        // be in.
        let registrar = PushTokenRegistrar()
        let sink = OutcomeSink(stream: registrar.outcomes)
        await sink.start()
        defer { Task { await sink.stop() } }
        await registrar.sessionDidSignOut()
        let outcome = await sink.next()
        #expect(outcome == .unregistered)
    }

    @Test
    func sessionDidExpireIsNoOp() async throws {
        // 401 from the coordination server means "re-auth required",
        // NOT "user gave up on push". Must NOT wipe the cached token.
        let transport = InMemoryDeviceTransport()
        let client = try await Self.makeClient(transport: transport)
        let recorder = Recorder()
        let server = await Self.makeAckingServer(transport: transport, recorder: recorder)
        defer { Task { await server.stop(); await client.disconnect() } }

        let registrar = PushTokenRegistrar()
        let sink = OutcomeSink(stream: registrar.outcomes)
        await sink.start()
        defer { Task { await sink.stop() } }
        await registrar.setClient(client)
        let token = try Self.makeToken()
        await registrar.setToken(token)
        _ = await sink.next()

        await registrar.sessionDidExpire()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(recorder.unregisterCount == 0)
        #expect(recorder.registerCount == 1)

        // Setting the same token must still be a no-op — the cache
        // is intact.
        await registrar.setToken(token)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(recorder.registerCount == 1)
    }

    // MARK: - Failure paths

    @Test
    func wireFailureSurfacesTypedError() async throws {
        let transport = InMemoryDeviceTransport()
        let client = try await Self.makeClient(transport: transport)
        let server = ScriptedDeviceServer(transport: transport) { request in
            if case .registerPushToken = request.request {
                return .error(code: 99, message: "boom")
            }
            return .silent
        }
        await server.run()
        defer { Task { await server.stop(); await client.disconnect() } }

        let registrar = PushTokenRegistrar()
        let sink = OutcomeSink(stream: registrar.outcomes)
        await sink.start()
        defer { Task { await sink.stop() } }
        await registrar.setClient(client)
        await registrar.setToken(try Self.makeToken())
        let outcome = await sink.next()
        #expect(outcome == .failed(.deviceError(code: 99, message: "boom")))
    }

    @Test
    func failedRegisterRetriesOnNextSetToken() async throws {
        // After a typed failure the registrar must NOT cache the
        // token — the next setToken (even with the same value)
        // re-issues the register so a transient server fault
        // recovers cleanly.
        let recorder = Recorder()
        let transport = InMemoryDeviceTransport()
        let client = try await Self.makeClient(transport: transport)
        let attemptCount = AttemptCount()
        let server = ScriptedDeviceServer(transport: transport) { request in
            if case let .registerPushToken(reg) = request.request {
                recorder.recordRegister(reg)
                if attemptCount.bump() == 1 {
                    return .error(code: 99, message: "transient")
                }
                var event = Catlaser_App_V1_DeviceEvent()
                event.pushTokenAck = Catlaser_App_V1_PushTokenAck()
                return .reply(event)
            }
            return .silent
        }
        await server.run()
        defer { Task { await server.stop(); await client.disconnect() } }

        let registrar = PushTokenRegistrar()
        let sink = OutcomeSink(stream: registrar.outcomes)
        await sink.start()
        defer { Task { await sink.stop() } }
        await registrar.setClient(client)
        let token = try Self.makeToken()
        await registrar.setToken(token)
        let first = await sink.next()
        #expect(first == .failed(.deviceError(code: 99, message: "transient")))

        // Caller fires `retry()` — the token cache was not pinned.
        await registrar.retry()
        let second = await sink.next()
        #expect(second == .registered(token: token))
        #expect(recorder.registerCount == 2)
    }

    @Test
    func wrongEventKindSurfacesAsTypedError() async throws {
        // A server that replies with a status_update instead of a
        // push_token_ack would break the client's contract silently.
        // The registrar must surface a typed ``wrongEventKind``.
        let transport = InMemoryDeviceTransport()
        let client = try await Self.makeClient(transport: transport)
        let server = ScriptedDeviceServer(transport: transport) { request in
            if case .registerPushToken = request.request {
                var event = Catlaser_App_V1_DeviceEvent()
                event.statusUpdate = Catlaser_App_V1_StatusUpdate()
                return .reply(event)
            }
            return .silent
        }
        await server.run()
        defer { Task { await server.stop(); await client.disconnect() } }

        let registrar = PushTokenRegistrar()
        let sink = OutcomeSink(stream: registrar.outcomes)
        await sink.start()
        defer { Task { await sink.stop() } }
        await registrar.setClient(client)
        await registrar.setToken(try Self.makeToken())
        let outcome = await sink.next()
        guard case let .failed(error) = outcome else {
            Issue.record("expected .failed outcome, got \(String(describing: outcome))")
            return
        }
        guard case .wrongEventKind = error else {
            Issue.record("expected .wrongEventKind, got \(error)")
            return
        }
    }
}

private final class AttemptCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
