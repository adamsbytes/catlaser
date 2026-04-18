import CatLaserDevice
import CatLaserDeviceTestSupport
import CatLaserProto
import Foundation
import Testing

@testable import CatLaserLive

@MainActor
@Suite("LiveViewModel")
struct LiveViewModelTests {
    // MARK: - Helpers

    /// Build a connected device client + the mock session + VM.
    /// `serverHandler` scripts the device side of the TCP channel.
    private func makeHarness(
        serverHandler: @escaping @Sendable (Catlaser_App_V1_AppRequest) -> ScriptedDeviceServer.Response,
    ) async throws -> (LiveViewModel, MockLiveStreamSession, ScriptedDeviceServer, DeviceClient) {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport, requestTimeout: 2.0)
        let server = ScriptedDeviceServer(transport: transport, handler: serverHandler)
        try await client.connect()
        await server.run()
        let session = MockLiveStreamSession()
        let vm = LiveViewModel(
            deviceClient: client,
            sessionFactory: { session },
        )
        return (vm, session, server, client)
    }

    nonisolated func validOfferResponse(url: String = "wss://livekit.test", token: String = "tok-xyz") -> ScriptedDeviceServer.Response {
        var offer = Catlaser_App_V1_StreamOffer()
        offer.livekitURL = url
        offer.subscriberToken = token
        var event = Catlaser_App_V1_DeviceEvent()
        event.streamOffer = offer
        return .reply(event)
    }

    /// Wait up to ~1 second for `predicate()` to hold. Let's the VM's
    /// event-loop task observe a streaming/disconnected event pushed
    /// by the mock session without polling.
    private func eventually(_ predicate: () -> Bool, timeout: TimeInterval = 1.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Initial state

    @Test
    func initialStateIsDisconnected() async throws {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport)
        let vm = LiveViewModel(deviceClient: client, sessionFactory: { MockLiveStreamSession() })
        #expect(vm.state == .disconnected)
        #expect(vm.state.canStart)
        #expect(!vm.state.canStop)
        #expect(!vm.state.isBusy)
    }

    // MARK: - Happy path

    @Test
    func connectFlow_RequestingOffer_Connecting_Streaming() async throws {
        let (vm, session, server, client) = try await makeHarness { request in
            switch request.request {
            case .startStream: return self.validOfferResponse()
            default: return .error(code: 2, message: "unknown")
            }
        }
        defer {
            Task {
                await server.stop()
                await client.disconnect()
            }
        }

        // start() returns only after both (a) device round-trip and
        // (b) session.connect have resolved. The mock's `.succeed`
        // behavior returns immediately, so the VM is settled on
        // `.connecting(credentials)` when start() returns.
        await vm.start()
        if case .connecting = vm.state {
            // Expected.
        } else {
            Issue.record("expected .connecting, got \(vm.state)")
        }

        // Now simulate the LiveKit subscription resolving.
        session.emitStreaming(trackID: "t-1")
        await eventually { vm.state == .streaming(MockTrack(id: "t-1")) }
        if case let .streaming(track) = vm.state {
            #expect(track.trackID == "t-1")
        } else {
            Issue.record("expected .streaming, got \(vm.state)")
        }
        #expect(await session.connectCount == 1)
        #expect(vm.hasActiveSession)
    }

    // MARK: - Stop

    @Test
    func stopTearsDownSessionAndReturnsToDisconnected() async throws {
        var stopReceived = false
        let stopFlag = LockedBool()

        let (vm, session, server, client) = try await makeHarness { request in
            switch request.request {
            case .startStream: return self.validOfferResponse()
            case .stopStream:
                stopFlag.set(true)
                var event = Catlaser_App_V1_DeviceEvent()
                event.statusUpdate = Catlaser_App_V1_StatusUpdate()
                return .reply(event)
            default: return .error(code: 2, message: "unknown")
            }
        }
        defer {
            Task {
                await server.stop()
                await client.disconnect()
            }
        }

        await vm.start()
        session.emitStreaming(trackID: "t-1")
        await eventually { vm.state == .streaming(MockTrack(id: "t-1")) }

        await vm.stop()
        await eventually { vm.state == .disconnected }
        stopReceived = stopFlag.get()

        #expect(vm.state == .disconnected)
        #expect(await session.disconnectCount >= 1)
        #expect(!vm.hasActiveSession)
        #expect(stopReceived == true)
    }

    // MARK: - Device returns DeviceError

    @Test
    func deviceErrorSurfacesAsFailed() async throws {
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .startStream:
                return .error(code: 3, message: "streaming not configured")
            default:
                return .error(code: 2, message: "unknown")
            }
        }
        defer {
            Task {
                await server.stop()
                await client.disconnect()
            }
        }

        await vm.start()
        if case let .failed(.deviceError(code, message)) = vm.state {
            #expect(code == 3)
            #expect(message == "streaming not configured")
        } else {
            Issue.record("expected .failed(.deviceError), got \(vm.state)")
        }
    }

    // MARK: - Wrong oneof

    @Test
    func wrongEventBranchMapsToInternalFailure() async throws {
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .startStream:
                var event = Catlaser_App_V1_DeviceEvent()
                event.statusUpdate = Catlaser_App_V1_StatusUpdate()
                return .reply(event)
            default:
                return .error(code: 2, message: "unknown")
            }
        }
        defer {
            Task {
                await server.stop()
                await client.disconnect()
            }
        }

        await vm.start()
        if case .failed(.internalFailure) = vm.state {
            // Good.
        } else {
            Issue.record("expected .failed(.internalFailure), got \(vm.state)")
        }
    }

    // MARK: - Invalid offer

    @Test
    func invalidOfferMapsToStreamOfferInvalid() async throws {
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .startStream:
                // Empty URL — `LiveStreamCredentials.init(offer:)` refuses.
                return self.validOfferResponse(url: "", token: "xyz")
            case .stopStream:
                var event = Catlaser_App_V1_DeviceEvent()
                event.statusUpdate = Catlaser_App_V1_StatusUpdate()
                return .reply(event)
            default:
                return .error(code: 2, message: "unknown")
            }
        }
        defer {
            Task {
                await server.stop()
                await client.disconnect()
            }
        }

        await vm.start()
        if case .failed(.streamOfferInvalid) = vm.state {
            // Good.
        } else {
            Issue.record("expected .failed(.streamOfferInvalid), got \(vm.state)")
        }
    }

    // MARK: - LiveKit connect failure

    @Test
    func liveKitFailureMapsToStreamConnectFailed() async throws {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport, requestTimeout: 2.0)
        let server = ScriptedDeviceServer(transport: transport) { request in
            switch request.request {
            case .startStream: return self.validOfferResponse()
            case .stopStream:
                var event = Catlaser_App_V1_DeviceEvent()
                event.statusUpdate = Catlaser_App_V1_StatusUpdate()
                return .reply(event)
            default: return .error(code: 2, message: "unknown")
            }
        }
        try await client.connect()
        await server.run()
        let session = MockLiveStreamSession()
        await session.setConnectBehavior(.fail(MockError.forcedFailure))
        let vm = LiveViewModel(deviceClient: client, sessionFactory: { session })
        defer {
            Task {
                await server.stop()
                await client.disconnect()
            }
        }

        await vm.start()
        if case .failed(.streamConnectFailed) = vm.state {
            // Good.
        } else {
            Issue.record("expected .failed(.streamConnectFailed), got \(vm.state)")
        }
        #expect(!vm.hasActiveSession)
    }

    // MARK: - Not-connected

    @Test
    func startWithoutOpenClientReportsNotConnected() async throws {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport, requestTimeout: 1.0)
        // Note: not calling connect().
        let session = MockLiveStreamSession()
        let vm = LiveViewModel(deviceClient: client, sessionFactory: { session })
        await vm.start()
        #expect(vm.state == .failed(.notConnected))
        #expect(await session.connectCount == 0)
    }

    // MARK: - Reentrancy

    @Test
    func doubleStartDropsTheSecondCall() async throws {
        let (vm, session, server, client) = try await makeHarness { request in
            switch request.request {
            case .startStream: return self.validOfferResponse()
            default: return .error(code: 2, message: "unknown")
            }
        }
        defer {
            Task {
                await server.stop()
                await client.disconnect()
            }
        }

        await session.setConnectBehavior(.manual)
        async let first: Void = vm.start()
        // Second call races but must be a no-op — canStart flips to
        // false the moment the first call enters `.requestingOffer`.
        await eventually { vm.state != .disconnected }
        await vm.start()
        await session.finishManualConnect(success: true)
        await first

        #expect(await session.connectCount == 1)
    }

    @Test
    func stopFromDisconnectedIsNoOp() async {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport)
        let session = MockLiveStreamSession()
        let vm = LiveViewModel(deviceClient: client, sessionFactory: { session })
        await vm.stop()
        #expect(vm.state == .disconnected)
        #expect(await session.disconnectCount == 0)
    }

    // MARK: - Unsolicited disconnects

    @Test
    func serverSideDropTransitionsToFailed() async throws {
        let (vm, session, server, client) = try await makeHarness { request in
            switch request.request {
            case .startStream: return self.validOfferResponse()
            case .stopStream:
                var event = Catlaser_App_V1_DeviceEvent()
                event.statusUpdate = Catlaser_App_V1_StatusUpdate()
                return .reply(event)
            default: return .error(code: 2, message: "unknown")
            }
        }
        defer {
            Task {
                await server.stop()
                await client.disconnect()
            }
        }

        await vm.start()
        session.emitStreaming(trackID: "t-1")
        await eventually { vm.state == .streaming(MockTrack(id: "t-1")) }

        session.emit(disconnectReason: .serverClosed("room ended"))
        await eventually {
            if case .failed(.streamDropped) = vm.state { true } else { false }
        }
        if case .failed(.streamDropped) = vm.state {
            // Good.
        } else {
            Issue.record("expected .failed(.streamDropped), got \(vm.state)")
        }
        #expect(!vm.hasActiveSession)
    }

    @Test
    func networkDropTransitionsToFailedNetworkFailure() async throws {
        let (vm, session, server, client) = try await makeHarness { request in
            switch request.request {
            case .startStream: return self.validOfferResponse()
            case .stopStream:
                var event = Catlaser_App_V1_DeviceEvent()
                event.statusUpdate = Catlaser_App_V1_StatusUpdate()
                return .reply(event)
            default: return .error(code: 2, message: "unknown")
            }
        }
        defer {
            Task {
                await server.stop()
                await client.disconnect()
            }
        }

        await vm.start()
        session.emitStreaming(trackID: "t-1")
        await eventually { vm.state == .streaming(MockTrack(id: "t-1")) }

        session.emit(disconnectReason: .networkFailure("wifi gone"))
        await eventually {
            if case .failed(.networkFailure) = vm.state { true } else { false }
        }
        if case .failed(.networkFailure) = vm.state {
            // Good.
        } else {
            Issue.record("expected .failed(.networkFailure), got \(vm.state)")
        }
    }

    // MARK: - dismissError + retry

    @Test
    func dismissErrorReturnsToDisconnected() async throws {
        let (vm, _, server, client) = try await makeHarness { _ in
            .error(code: 5, message: "boom")
        }
        defer {
            Task {
                await server.stop()
                await client.disconnect()
            }
        }
        await vm.start()
        guard case .failed = vm.state else {
            Issue.record("expected .failed, got \(vm.state)")
            return
        }
        vm.dismissError()
        #expect(vm.state == .disconnected)
    }

    @Test
    func dismissErrorIsNoOpFromNonFailed() {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport)
        let vm = LiveViewModel(deviceClient: client, sessionFactory: { MockLiveStreamSession() })
        vm.dismissError()
        #expect(vm.state == .disconnected)
    }

    // MARK: - Multiple cycles

    @Test
    func repeatedStartStopCyclesDoNotLeak() async throws {
        // Match production semantics: every `start()` gets a fresh
        // `LiveStreamSession` (a LiveKit `Room` is single-use). We
        // collect each new session in a box so the test can emit
        // events on the one currently wired to the VM.
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport, requestTimeout: 2.0)
        let server = ScriptedDeviceServer(transport: transport) { request in
            switch request.request {
            case .startStream: return self.validOfferResponse()
            case .stopStream:
                var event = Catlaser_App_V1_DeviceEvent()
                event.statusUpdate = Catlaser_App_V1_StatusUpdate()
                return .reply(event)
            default: return .error(code: 2, message: "unknown")
            }
        }
        try await client.connect()
        await server.run()

        let collector = SessionCollector()
        let vm = LiveViewModel(
            deviceClient: client,
            sessionFactory: {
                let session = MockLiveStreamSession()
                collector.add(session)
                return session
            },
        )
        defer {
            Task {
                await server.stop()
                await client.disconnect()
            }
        }

        for cycle in 0 ..< 3 {
            await vm.start()
            let session = collector.latest()
            session.emitStreaming(trackID: "t-\(cycle)")
            await eventually { vm.state == .streaming(MockTrack(id: "t-\(cycle)")) }
            await vm.stop()
            await eventually { vm.state == .disconnected }
        }

        #expect(collector.count == 3)
        for session in collector.all() {
            #expect(await session.connectCount == 1)
            #expect(await session.disconnectCount >= 1)
        }
    }
}

/// Thread-safe collector for `MockLiveStreamSession` instances created
/// by a sessionFactory closure. Used by the multi-cycle reuse test.
final class SessionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [MockLiveStreamSession] = []

    func add(_ session: MockLiveStreamSession) {
        lock.lock()
        defer { lock.unlock() }
        sessions.append(session)
    }

    func latest() -> MockLiveStreamSession {
        lock.lock()
        defer { lock.unlock() }
        return sessions.last!
    }

    func all() -> [MockLiveStreamSession] {
        lock.lock()
        defer { lock.unlock() }
        return sessions
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }
}

/// Tiny locked-bool helper used where tests need to observe a flag
/// toggled from inside a scripted server handler closure.
final class LockedBool: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()

    func set(_ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
