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

    /// A permissive gate that always allows — used by every test that
    /// does not specifically exercise the pre-stream auth gate. Making
    /// this explicit means the tests that DO exercise the gate are
    /// obviously different.
    private nonisolated static let allowingGate: LiveViewModel.AuthGate = { .allowed }

    /// LiveKit allowlist every happy-path test uses. The scripted
    /// server returns a `livekit.test` URL, so the allowlist matches
    /// exactly that host. Tests that exercise the allowlist itself
    /// (e.g. offers pointing at a different host) override this.
    private static func testAllowlist(
        hosts: [String] = ["livekit.test"],
    ) -> LiveKitHostAllowlist {
        // swiftlint:disable:next force_try
        try! LiveKitHostAllowlist(hosts: hosts)
    }

    /// Build a connected device client + the mock session + VM.
    /// `serverHandler` scripts the device side of the TCP channel.
    private func makeHarness(
        serverHandler: @escaping @Sendable (Catlaser_App_V1_AppRequest) -> ScriptedDeviceServer.Response,
        authGate: @escaping LiveViewModel.AuthGate = LiveViewModelTests.allowingGate,
        allowlist: LiveKitHostAllowlist = LiveViewModelTests.testAllowlist(),
    ) async throws -> (LiveViewModel, MockLiveStreamSession, ScriptedDeviceServer, DeviceClient) {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport, requestTimeout: 2.0)
        let server = ScriptedDeviceServer(transport: transport, handler: serverHandler)
        try await client.connect()
        await server.run()
        let session = MockLiveStreamSession()
        let vm = LiveViewModel(
            deviceClient: client,
            authGate: authGate,
            liveKitAllowlist: allowlist,
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
        let vm = LiveViewModel(
            deviceClient: client,
            authGate: Self.allowingGate,
            liveKitAllowlist: Self.testAllowlist(),
            sessionFactory: { MockLiveStreamSession() },
        )
        #expect(vm.state == .disconnected)
        #expect(vm.state.canStart)
        #expect(!vm.state.canStop)
        #expect(!vm.state.isBusy)
        #expect(vm.sessionStatus.phase == .unknown)
        #expect(!vm.isObservingStatus)
    }

    // MARK: - Session status observation

    @Test
    func sessionStatusUnknownWithoutBroker() async throws {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport)
        let vm = LiveViewModel(
            deviceClient: client,
            authGate: Self.allowingGate,
            liveKitAllowlist: Self.testAllowlist(),
            sessionFactory: { MockLiveStreamSession() },
        )
        #expect(vm.sessionStatus.phase == .unknown)
        #expect(vm.sessionStatus.sessionStartedAt == nil)
        #expect(!vm.isObservingStatus)
    }

    @Test
    func sessionStatusMovesToPlayingOnStatusUpdate() async throws {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport, requestTimeout: 2.0)
        try await client.connect()
        let broker = DeviceEventBroker(
            client: client,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        broker.start()
        let vm = LiveViewModel(
            deviceClient: client,
            authGate: Self.allowingGate,
            liveKitAllowlist: Self.testAllowlist(),
            sessionFactory: { MockLiveStreamSession() },
            eventBroker: broker,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        defer {
            Task {
                broker.stop()
                await client.disconnect()
                await transport.close()
            }
        }

        #expect(vm.isObservingStatus)

        var status = Catlaser_App_V1_StatusUpdate()
        status.sessionActive = true
        status.activeCatIds = ["cat-a", "cat-b"]
        status.hopperLevel = .ok
        status.firmwareVersion = "1.2.3"
        var event = Catlaser_App_V1_DeviceEvent()
        event.statusUpdate = status
        try transport.deliver(event: event)

        await eventually { vm.sessionStatus.phase == .playing }

        #expect(vm.sessionStatus.phase == .playing)
        #expect(vm.sessionStatus.activeCatCount == 2)
        #expect(vm.sessionStatus.hopperLevel == .ok)
        #expect(vm.sessionStatus.firmwareVersion == "1.2.3")
        #expect(vm.sessionStatus.sessionStartedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test
    func sessionStatusStableOnRepeatedPlayingStatus() async throws {
        // The session-started timestamp is a rising-edge observation;
        // a subsequent heartbeat with session_active=true must NOT
        // reset the timestamp, otherwise the overlay's elapsed
        // counter would bounce back to zero every heartbeat.
        let clockSeq = LockedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport, requestTimeout: 2.0)
        try await client.connect()
        let broker = DeviceEventBroker(client: client, clock: { clockSeq.now })
        broker.start()
        let vm = LiveViewModel(
            deviceClient: client,
            authGate: Self.allowingGate,
            liveKitAllowlist: Self.testAllowlist(),
            sessionFactory: { MockLiveStreamSession() },
            eventBroker: broker,
            clock: { clockSeq.now },
        )
        defer {
            Task {
                broker.stop()
                await client.disconnect()
                await transport.close()
            }
        }

        var status = Catlaser_App_V1_StatusUpdate()
        status.sessionActive = true
        var event = Catlaser_App_V1_DeviceEvent()
        event.statusUpdate = status
        try transport.deliver(event: event)
        await eventually { vm.sessionStatus.phase == .playing }
        let firstStart = vm.sessionStatus.sessionStartedAt
        #expect(firstStart == Date(timeIntervalSince1970: 1_700_000_000))

        // Second heartbeat, later wall-clock, still session_active.
        clockSeq.advance(by: 5)
        try transport.deliver(event: event)
        try await Task.sleep(nanoseconds: 60_000_000)
        #expect(vm.sessionStatus.sessionStartedAt == firstStart)
    }

    @Test
    func sessionStatusResetsOnSessionSummary() async throws {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport, requestTimeout: 2.0)
        try await client.connect()
        let broker = DeviceEventBroker(client: client)
        broker.start()
        let vm = LiveViewModel(
            deviceClient: client,
            authGate: Self.allowingGate,
            liveKitAllowlist: Self.testAllowlist(),
            sessionFactory: { MockLiveStreamSession() },
            eventBroker: broker,
        )
        defer {
            Task {
                broker.stop()
                await client.disconnect()
                await transport.close()
            }
        }

        var status = Catlaser_App_V1_StatusUpdate()
        status.sessionActive = true
        var statusEvent = Catlaser_App_V1_DeviceEvent()
        statusEvent.statusUpdate = status
        try transport.deliver(event: statusEvent)
        await eventually { vm.sessionStatus.phase == .playing }

        var summary = Catlaser_App_V1_SessionSummary()
        summary.durationSec = 120
        var summaryEvent = Catlaser_App_V1_DeviceEvent()
        summaryEvent.sessionSummary = summary
        try transport.deliver(event: summaryEvent)

        await eventually { vm.sessionStatus.phase == .idle }
        #expect(vm.sessionStatus.sessionStartedAt == nil)
        #expect(vm.sessionStatus.activeCatCount == 0)
    }

    @Test
    func sessionStatusHopperLevelTracksLatestStatus() async throws {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport, requestTimeout: 2.0)
        try await client.connect()
        let broker = DeviceEventBroker(client: client)
        broker.start()
        let vm = LiveViewModel(
            deviceClient: client,
            authGate: Self.allowingGate,
            liveKitAllowlist: Self.testAllowlist(),
            sessionFactory: { MockLiveStreamSession() },
            eventBroker: broker,
        )
        defer {
            Task {
                broker.stop()
                await client.disconnect()
                await transport.close()
            }
        }

        var status = Catlaser_App_V1_StatusUpdate()
        status.sessionActive = false
        status.hopperLevel = .low
        var event = Catlaser_App_V1_DeviceEvent()
        event.statusUpdate = status
        try transport.deliver(event: event)

        await eventually { vm.sessionStatus.hopperLevel == .low }
        #expect(vm.sessionStatus.phase == .idle)
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

    /// A stream offer whose host is NOT in the app's allowlist must
    /// be refused at the VM level without dialing LiveKit. Guards
    /// against a compromised device steering the subscriber dial at
    /// an attacker-controlled host.
    @Test
    func offerWithHostOutsideAllowlistMapsToStreamOfferInvalid() async throws {
        let (vm, session, server, client) = try await makeHarness(
            serverHandler: { request in
                switch request.request {
                case .startStream:
                    // Well-formed WSS URL but the host isn't what the
                    // app is configured to trust.
                    return self.validOfferResponse(
                        url: "wss://attacker.example",
                        token: "any",
                    )
                case .stopStream:
                    var event = Catlaser_App_V1_DeviceEvent()
                    event.statusUpdate = Catlaser_App_V1_StatusUpdate()
                    return .reply(event)
                default:
                    return .error(code: 2, message: "unknown")
                }
            },
            // Only `livekit.test` is trusted. Any other host must fail.
            allowlist: Self.testAllowlist(hosts: ["livekit.test"]),
        )
        defer {
            Task {
                await server.stop()
                await client.disconnect()
            }
        }

        await vm.start()
        guard case let .failed(error) = vm.state,
              case let .streamOfferInvalid(credError) = error,
              case let .hostNotAllowed(host) = credError
        else {
            Issue.record("expected .failed(.streamOfferInvalid(.hostNotAllowed)), got \(vm.state)")
            return
        }
        #expect(host == "attacker.example")
        // Session must not have been dialed — allowlist check runs
        // before `session.connect` is reached.
        #expect(await session.connectCount == 0)
        #expect(!vm.hasActiveSession)
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
        let vm = LiveViewModel(
            deviceClient: client,
            authGate: Self.allowingGate,
            liveKitAllowlist: Self.testAllowlist(),
            sessionFactory: { session },
        )
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
        let vm = LiveViewModel(
            deviceClient: client,
            authGate: Self.allowingGate,
            liveKitAllowlist: Self.testAllowlist(),
            sessionFactory: { session },
        )
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
        let vm = LiveViewModel(
            deviceClient: client,
            authGate: Self.allowingGate,
            liveKitAllowlist: Self.testAllowlist(),
            sessionFactory: { session },
        )
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
        let vm = LiveViewModel(
            deviceClient: client,
            authGate: Self.allowingGate,
            liveKitAllowlist: Self.testAllowlist(),
            sessionFactory: { MockLiveStreamSession() },
        )
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
            authGate: Self.allowingGate,
            liveKitAllowlist: Self.testAllowlist(),
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

    // MARK: - Pre-stream auth gate

    /// A cancel from the user-presence gate returns the VM silently to
    /// `.disconnected` without touching the device TCP channel — a
    /// probe that records device traffic after a cancelled prompt
    /// would reveal nothing.
    @Test
    func authGateCancelledReturnsToDisconnectedAndSkipsDevice() async throws {
        let handlerCalled = LockedBool()
        let (vm, session, server, client) = try await makeHarness(
            serverHandler: { _ in
                handlerCalled.set(true)
                return .error(code: 2, message: "unexpected request")
            },
            authGate: { .cancelled },
        )
        defer {
            Task {
                await server.stop()
                await client.disconnect()
            }
        }

        await vm.start()
        #expect(vm.state == .disconnected)
        #expect(await session.connectCount == 0)
        #expect(handlerCalled.get() == false)
        #expect(!vm.hasActiveSession)
    }

    /// A `denied` result from the gate lands on
    /// `.failed(.authenticationRequired)` and never touches the device
    /// or the LiveKit session.
    @Test
    func authGateDeniedSurfacesAuthenticationRequired() async throws {
        let handlerCalled = LockedBool()
        let (vm, session, server, client) = try await makeHarness(
            serverHandler: { _ in
                handlerCalled.set(true)
                return .error(code: 2, message: "unexpected request")
            },
            authGate: { .denied("biometric unavailable") },
        )
        defer {
            Task {
                await server.stop()
                await client.disconnect()
            }
        }

        await vm.start()
        if case let .failed(.authenticationRequired(reason)) = vm.state {
            #expect(reason == "biometric unavailable")
        } else {
            Issue.record("expected .failed(.authenticationRequired), got \(vm.state)")
        }
        #expect(await session.connectCount == 0)
        #expect(handlerCalled.get() == false)
        #expect(!vm.hasActiveSession)
    }

    /// The gate runs on every `start()` — a prior `.allowed` must not
    /// cache the user-presence decision and bypass the gate on the
    /// next tap. Regression guard against a future refactor that
    /// introduces a "first time only" shortcut.
    @Test
    func authGateRunsOnEveryStart() async throws {
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

        let counter = GateCallCounter()
        let collector = SessionCollector()
        let vm = LiveViewModel(
            deviceClient: client,
            authGate: { counter.nextOutcome() },
            liveKitAllowlist: Self.testAllowlist(),
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

        // First start: gate allows, stream starts.
        await vm.start()
        collector.latest().emitStreaming(trackID: "t-0")
        await eventually { vm.state == .streaming(MockTrack(id: "t-0")) }
        await vm.stop()
        await eventually { vm.state == .disconnected }

        // Second start: gate is asked again, and denies this time.
        await vm.start()
        if case .failed(.authenticationRequired) = vm.state {
            // Good.
        } else {
            Issue.record("expected .failed(.authenticationRequired) on second start, got \(vm.state)")
        }

        #expect(counter.count == 2)
        #expect(collector.count == 1) // no session created on the denied run
    }

    // MARK: - Connect watchdog + publisher-identity mismatch

    /// A silent LiveKit hang (connect returns but no `.streaming` event)
    /// used to wedge the UI on the spinner forever. The VM now arms a
    /// wall-clock watchdog on every `.connecting` entry; firing transitions
    /// to `.failed(.streamConnectTimeout)` and rolls back the device
    /// stream. This test drives the mock into `manual`-connect mode,
    /// waits past a tight deadline, and asserts the failure lands.
    @Test
    func connectTimeoutFiresWhenStreamingEventNeverArrives() async throws {
        let session = MockLiveStreamSession()
        await session.setConnectBehavior(.manual)
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport, requestTimeout: 2.0)
        let server = ScriptedDeviceServer(transport: transport, handler: { request in
            switch request.request {
            case .startStream: return self.validOfferResponse()
            case .stopStream:
                var event = Catlaser_App_V1_DeviceEvent()
                event.statusUpdate = Catlaser_App_V1_StatusUpdate()
                return .reply(event)
            default: return .error(code: 2, message: "unknown")
            }
        })
        try await client.connect()
        await server.run()
        let vm = LiveViewModel(
            deviceClient: client,
            authGate: Self.allowingGate,
            liveKitAllowlist: Self.testAllowlist(),
            sessionFactory: { session },
            connectTimeout: 0.2,
        )

        // Start returns once the mock session's connect completes; with
        // `manual` the connect itself will stall, so we race it against
        // the watchdog.
        let startTask = Task { await vm.start() }

        await eventually { vm.state == .failed(.streamConnectTimeout) }
        if case .failed(.streamConnectTimeout) = vm.state {
            // good
        } else {
            Issue.record("expected .failed(.streamConnectTimeout), got \(vm.state)")
        }

        // Unblock the manual connect so `start` can complete.
        await session.finishManualConnect(success: true)
        _ = await startTask.value
    }

    /// An impostor with publish grants joins the LiveKit room. Its
    /// `participant.identity` does not match
    /// `catlaser-device-<slug>`. The VM must transition to
    /// `.failed(.unexpectedPublisher)` — NOT sit silently on the
    /// spinner, NOT render the impostor's track.
    @Test
    func unexpectedPublisherEventFailsTheStream() async throws {
        let (vm, session, _, _) = try await makeHarness { request in
            switch request.request {
            case .startStream: return self.validOfferResponse()
            case .stopStream:
                var event = Catlaser_App_V1_DeviceEvent()
                event.statusUpdate = Catlaser_App_V1_StatusUpdate()
                return .reply(event)
            default: return .error(code: 2, message: "unknown")
            }
        }
        await session.setConnectBehavior(.succeed)
        await vm.start()
        // Emit a stray-publisher event the production
        // `LiveKitStreamSession.Delegate` would yield on identity
        // mismatch. The VM's event loop observes it and must lift
        // it into a terminal `.failed(.unexpectedPublisher)` state.
        session.emitUnexpectedPublisher(identity: "attacker")

        await eventually {
            if case let .failed(error) = vm.state,
               case .unexpectedPublisher = error {
                return true
            }
            return false
        }
        if case let .failed(error) = vm.state,
           case let .unexpectedPublisher(identity) = error {
            #expect(identity == "attacker")
        } else {
            Issue.record("expected .failed(.unexpectedPublisher), got \(vm.state)")
        }
    }

    // MARK: - swapDeviceClient (same-device reconnect)

    /// A supervisor reconnect on the SAME paired device produces a
    /// fresh ``DeviceClient``. The VM must accept the swap WITHOUT
    /// tearing the active stream down — the user is mid-watch and a
    /// momentary network blip should not yank the video. This test
    /// drives the VM to ``.streaming``, swaps in a new client + new
    /// broker, and asserts the streaming state survives.
    @Test
    func swapDeviceClientPreservesStreamingState() async throws {
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
        await vm.start()
        session.emitStreaming(trackID: "t-1")
        await eventually { vm.state == .streaming(MockTrack(id: "t-1")) }

        // Build a fresh client and broker, mirroring what the
        // composition would supply on a same-device reconnect.
        let newTransport = InMemoryDeviceTransport()
        let newClient = DeviceClient(transport: newTransport, requestTimeout: 2.0)
        try await newClient.connect()
        let newBroker = DeviceEventBroker(client: newClient)
        newBroker.start()
        defer {
            Task {
                newBroker.stop()
                await newClient.disconnect()
                await newTransport.close()
            }
        }

        vm.swapDeviceClient(newClient, eventBroker: newBroker)

        // Streaming state preserved across the swap. The previously-
        // attached LiveKit session is the same instance — nothing
        // about the LiveKit subscription is tied to the device-control
        // socket, so a transient transport rebuild does not interrupt
        // the video.
        if case let .streaming(track) = vm.state {
            #expect(track.trackID == "t-1")
        } else {
            Issue.record("expected .streaming preserved across swap, got \(vm.state)")
        }
        #expect(vm.hasActiveSession)
        #expect(vm.isObservingStatus)
    }

    /// After ``swapDeviceClient``, status updates must arrive via the
    /// NEW broker — pushing on the OLD broker no longer mutates the
    /// VM. Two failure modes to catch: the VM still subscribed to the
    /// old broker (would respond to old pushes) or no broker at all
    /// (would respond to neither). Drive both halves explicitly.
    @Test
    func swapDeviceClientReBindsStatusObservationToNewBroker() async throws {
        let oldTransport = InMemoryDeviceTransport()
        let oldClient = DeviceClient(transport: oldTransport, requestTimeout: 2.0)
        try await oldClient.connect()
        let oldBroker = DeviceEventBroker(client: oldClient)
        oldBroker.start()

        let vm = LiveViewModel(
            deviceClient: oldClient,
            authGate: Self.allowingGate,
            liveKitAllowlist: Self.testAllowlist(),
            sessionFactory: { MockLiveStreamSession() },
            eventBroker: oldBroker,
        )

        let newTransport = InMemoryDeviceTransport()
        let newClient = DeviceClient(transport: newTransport, requestTimeout: 2.0)
        try await newClient.connect()
        let newBroker = DeviceEventBroker(client: newClient)
        newBroker.start()

        defer {
            Task {
                oldBroker.stop()
                newBroker.stop()
                await oldClient.disconnect()
                await newClient.disconnect()
                await oldTransport.close()
                await newTransport.close()
            }
        }

        vm.swapDeviceClient(newClient, eventBroker: newBroker)
        #expect(vm.isObservingStatus)

        // Push on the OLD transport. A correctly-rebound VM should
        // ignore this — its observation task was cancelled when the
        // swap re-bound to the new broker.
        var oldStatus = Catlaser_App_V1_StatusUpdate()
        oldStatus.sessionActive = true
        oldStatus.activeCatIds = ["should-be-ignored"]
        var oldEvent = Catlaser_App_V1_DeviceEvent()
        oldEvent.statusUpdate = oldStatus
        try oldTransport.deliver(event: oldEvent)
        // Brief settle window — if the old subscription were still
        // active the phase would have flipped by now.
        try await Task.sleep(nanoseconds: 60_000_000)
        #expect(vm.sessionStatus.phase == .unknown)

        // Push on the NEW transport. The VM must observe this one.
        var newStatus = Catlaser_App_V1_StatusUpdate()
        newStatus.sessionActive = true
        newStatus.activeCatIds = ["new-cat"]
        newStatus.hopperLevel = .ok
        var newEvent = Catlaser_App_V1_DeviceEvent()
        newEvent.statusUpdate = newStatus
        try newTransport.deliver(event: newEvent)

        await eventually { vm.sessionStatus.phase == .playing }
        #expect(vm.sessionStatus.activeCatCount == 1)
    }

    /// After ``swapDeviceClient``, subsequent device round-trips
    /// (issued by user actions like ``stop``) must go to the NEW
    /// client. The old client's transport sees zero traffic from this
    /// VM after the swap.
    @Test
    func swapDeviceClientRoutesSubsequentRequestsToNewClient() async throws {
        let (vm, session, oldServer, oldClient) = try await makeHarness { request in
            switch request.request {
            case .startStream: return self.validOfferResponse()
            case .stopStream:
                var event = Catlaser_App_V1_DeviceEvent()
                event.statusUpdate = Catlaser_App_V1_StatusUpdate()
                return .reply(event)
            default: return .error(code: 2, message: "unknown")
            }
        }
        await vm.start()
        session.emitStreaming(trackID: "t-1")
        await eventually { vm.state == .streaming(MockTrack(id: "t-1")) }

        // Build a fresh transport that observes its own request
        // arrivals. The new server's handler increments a counter on
        // each StopStream so the test can assert the routing.
        let newTransport = InMemoryDeviceTransport()
        let newClient = DeviceClient(transport: newTransport, requestTimeout: 2.0)
        let newStopFlag = LockedBool()
        let newServer = ScriptedDeviceServer(transport: newTransport, handler: { request in
            switch request.request {
            case .stopStream:
                newStopFlag.set(true)
                var event = Catlaser_App_V1_DeviceEvent()
                event.statusUpdate = Catlaser_App_V1_StatusUpdate()
                return .reply(event)
            default: return .error(code: 2, message: "unknown")
            }
        })
        try await newClient.connect()
        await newServer.run()
        let newBroker = DeviceEventBroker(client: newClient)
        newBroker.start()
        defer {
            Task {
                newBroker.stop()
                await newServer.stop()
                await newClient.disconnect()
                await oldServer.stop()
                await oldClient.disconnect()
            }
        }

        vm.swapDeviceClient(newClient, eventBroker: newBroker)

        await vm.stop()
        await eventually { vm.state == .disconnected }

        // The user's Stop tap after the swap landed on the NEW client.
        #expect(newStopFlag.get() == true)
    }

    /// `canStop` must hold while the VM is still busy, so a user whose
    /// stream is hanging mid-connect can back out. Gating stop on
    /// `.streaming` alone used to trap the user behind a disabled
    /// button whenever the connect stalled.
    @Test
    func canStopHoldsDuringConnectingAndRequestingOffer() async throws {
        // `.requestingOffer` and `.connecting` both need to accept
        // `.stop()`. The equality-only assertion here is a structural
        // check against the enum surface, not against a live VM.
        #expect(LiveViewState.requestingOffer.canStop)
        // We need a sample LiveStreamCredentials; the exact contents
        // don't matter for the canStop getter.
        let allowlist = Self.testAllowlist()
        var offer = Catlaser_App_V1_StreamOffer()
        offer.livekitURL = "wss://livekit.test"
        offer.subscriberToken = "tok"
        let creds = try LiveStreamCredentials(offer: offer, allowlist: allowlist)
        #expect(LiveViewState.connecting(creds).canStop)
        #expect(!LiveViewState.disconnected.canStop)
        #expect(!LiveViewState.disconnecting.canStop)
    }
}

/// Scriptable gate: returns the next outcome from a preset sequence,
/// counting the total number of calls. Allows a test to assert the
/// VM asked for permission exactly N times and in the right order.
final class GateCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func nextOutcome() -> LiveAuthGateOutcome {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls == 1 ? .allowed : .denied("simulated")
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
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

/// Lock-guarded advanceable clock for tests that want an observable
/// "time passed" between scripted deliveries. Captured by the clock
/// closures on the broker / VM so both read the same `now`.
final class LockedClock: @unchecked Sendable {
    private var current: Date
    private let lock = NSLock()

    init(_ initial: Date) {
        self.current = initial
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}
