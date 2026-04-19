import CatLaserDevice
import CatLaserDeviceTestSupport
import CatLaserProto
import Foundation
import Testing

@testable import CatLaserPush

@Suite("PushViewModel")
struct PushViewModelTests {
    // MARK: - Fixtures

    /// Exposes deterministic push OS bridge closures for the VM.
    private actor StubOSBridge {
        enum PromptBehaviour: Sendable {
            case returning(PushAuthorizationStatus)
            case throwing(any Error)
        }

        private var status: PushAuthorizationStatus
        private var promptBehaviour: PromptBehaviour
        private(set) var promptCallCount = 0
        private(set) var registerForRemoteCallCount = 0
        private(set) var currentStatusCallCount = 0

        init(
            initial: PushAuthorizationStatus = .notDetermined,
            promptBehaviour: PromptBehaviour = .returning(.authorized),
        ) {
            self.status = initial
            self.promptBehaviour = promptBehaviour
        }

        func setStatus(_ new: PushAuthorizationStatus) {
            status = new
        }

        func setPromptBehaviour(_ new: PromptBehaviour) {
            promptBehaviour = new
        }

        func prompt() async throws -> PushAuthorizationStatus {
            promptCallCount += 1
            switch promptBehaviour {
            case let .returning(result):
                status = result
                return result
            case let .throwing(error):
                throw error
            }
        }

        func read() async -> PushAuthorizationStatus {
            currentStatusCallCount += 1
            return status
        }

        func registerForRemote() async {
            registerForRemoteCallCount += 1
        }
    }

    private static func makeConnectedClient(
        transport: InMemoryDeviceTransport,
    ) async throws -> DeviceClient {
        let client = DeviceClient(transport: transport, requestTimeout: 1.0)
        try await client.connect()
        return client
    }

    private static func makeAckingServer(
        transport: InMemoryDeviceTransport,
    ) async -> ScriptedDeviceServer {
        let server = ScriptedDeviceServer(transport: transport) { request in
            switch request.request {
            case .registerPushToken, .unregisterPushToken:
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

    private static func tokenData(byte: UInt8 = 0xAB) -> Data {
        Data(repeating: byte, count: PushToken.minimumLength)
    }

    /// Drive a VM.start(), given a bridge, wire-connected registrar,
    /// and a server.
    @MainActor
    private static func makeViewModel(
        bridge: StubOSBridge,
        registrar: PushTokenRegistrar,
    ) -> PushViewModel {
        PushViewModel(
            registrar: registrar,
            prompt: { try await bridge.prompt() },
            readAuthorization: { await bridge.read() },
            registerForRemoteNotifications: { await bridge.registerForRemote() },
        )
    }

    /// Poll `vm.state` until `predicate(state)` is true OR the
    /// deadline passes. Returns the observed state.
    @MainActor
    private static func waitForState(
        on vm: PushViewModel,
        timeout: TimeInterval = 2.0,
        _ predicate: (PushRegistrationState) -> Bool,
    ) async -> PushRegistrationState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(vm.state) {
                return vm.state
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return vm.state
    }

    // MARK: - start()

    @MainActor
    @Test
    func startWithNotDeterminedAuthKeepsStateIdle() async throws {
        let bridge = StubOSBridge(initial: .notDetermined)
        let registrar = PushTokenRegistrar()
        let vm = Self.makeViewModel(bridge: bridge, registrar: registrar)
        await vm.start()
        #expect(vm.state == .idle)
        #expect(vm.authorization == .notDetermined)
        #expect(await bridge.registerForRemoteCallCount == 0)
        vm.stop()
    }

    @MainActor
    @Test
    func startWithPreviouslyAuthorizedAutoKicksRegistration() async throws {
        // Returning user: OS already holds a grant. The VM must
        // auto-kick the APNs registration without the user having
        // to tap "Turn on" again. Enforcing this on the client side
        // is load-bearing — without it, a user who grants once and
        // restarts the app sees a misleading primer screen.
        let bridge = StubOSBridge(initial: .authorized)
        let registrar = PushTokenRegistrar()
        let vm = Self.makeViewModel(bridge: bridge, registrar: registrar)
        await vm.start()
        #expect(vm.state == .awaitingAPNsToken)
        #expect(vm.authorization == .authorized)
        #expect(await bridge.registerForRemoteCallCount == 1)
        vm.stop()
    }

    @MainActor
    @Test
    func startWithDeniedAuthGoesToDeniedState() async throws {
        let bridge = StubOSBridge(initial: .denied)
        let registrar = PushTokenRegistrar()
        let vm = Self.makeViewModel(bridge: bridge, registrar: registrar)
        await vm.start()
        #expect(vm.state == .authorizationDenied)
        #expect(vm.authorization == .denied)
        #expect(await bridge.registerForRemoteCallCount == 0)
        vm.stop()
    }

    // MARK: - requestAuthorization()

    @MainActor
    @Test
    func requestAuthorizationGrantedKicksAPNsRegistration() async throws {
        let bridge = StubOSBridge(
            initial: .notDetermined,
            promptBehaviour: .returning(.authorized),
        )
        let registrar = PushTokenRegistrar()
        let vm = Self.makeViewModel(bridge: bridge, registrar: registrar)
        await vm.start()
        await vm.requestAuthorization()
        #expect(vm.state == .awaitingAPNsToken)
        #expect(vm.authorization == .authorized)
        #expect(await bridge.promptCallCount == 1)
        #expect(await bridge.registerForRemoteCallCount == 1)
        vm.stop()
    }

    @MainActor
    @Test
    func requestAuthorizationDeniedLandsInDeniedState() async throws {
        let bridge = StubOSBridge(
            initial: .notDetermined,
            promptBehaviour: .returning(.denied),
        )
        let registrar = PushTokenRegistrar()
        let vm = Self.makeViewModel(bridge: bridge, registrar: registrar)
        await vm.start()
        await vm.requestAuthorization()
        #expect(vm.state == .authorizationDenied)
        #expect(vm.authorization == .denied)
        // The OS sheet never produced a grant — we must NOT have
        // kicked APNs registration. A regression that always called
        // the register closure would leak a pointless APNs prompt
        // to the OS.
        #expect(await bridge.registerForRemoteCallCount == 0)
        vm.stop()
    }

    @MainActor
    @Test
    func requestAuthorizationThrowingSurfacesFailure() async throws {
        struct Boom: Error {}
        let bridge = StubOSBridge(promptBehaviour: .throwing(Boom()))
        let registrar = PushTokenRegistrar()
        let vm = Self.makeViewModel(bridge: bridge, registrar: registrar)
        await vm.start()
        await vm.requestAuthorization()
        guard case .failed = vm.state else {
            Issue.record("expected .failed, got \(vm.state)")
            return
        }
        vm.stop()
    }

    @MainActor
    @Test
    func requestAuthorizationIgnoredWhileBusy() async throws {
        // Double-tap on "Turn on notifications" during the OS sheet
        // must not fire a second prompt.
        let bridge = StubOSBridge(
            initial: .notDetermined,
            promptBehaviour: .returning(.authorized),
        )
        let registrar = PushTokenRegistrar()
        let vm = Self.makeViewModel(bridge: bridge, registrar: registrar)
        await vm.start()
        // Fire two concurrently; the second must early-exit on the
        // `isBusy` gate.
        async let first: Void = vm.requestAuthorization()
        async let second: Void = vm.requestAuthorization()
        _ = await (first, second)
        // With strict in-order execution on @MainActor, first
        // completes fully before second sees the state. The
        // once-it-is-registered check guards against re-prompt.
        #expect(await bridge.promptCallCount <= 1)
        vm.stop()
    }

    // MARK: - postponeAuthorization()

    /// "Not now" on the primer must land in ``.postponed`` without
    /// touching the OS prompt. The OS grant stays ``.notDetermined``
    /// so the one-shot system sheet is still available on a later
    /// ``requestAuthorization()``.
    @MainActor
    @Test
    func postponeFromPrimerKeepsOSGrantUntouched() async throws {
        let bridge = StubOSBridge(initial: .notDetermined)
        let registrar = PushTokenRegistrar()
        let vm = Self.makeViewModel(bridge: bridge, registrar: registrar)
        await vm.start()
        #expect(vm.state == .idle)

        vm.postponeAuthorization()

        #expect(vm.state == .postponed)
        #expect(vm.authorization == .notDetermined)
        #expect(await bridge.promptCallCount == 0,
                "postpone must never invoke the OS permission prompt")
        #expect(await bridge.registerForRemoteCallCount == 0)
        vm.stop()
    }

    /// The postponed pane's "Turn on notifications" button re-opens
    /// the primer flow by calling ``requestAuthorization()`` directly.
    /// That transition must still produce the OS prompt and, on
    /// grant, kick APNs registration — identical to the primary path.
    @MainActor
    @Test
    func requestAuthorizationFromPostponedReopensPrimerFlow() async throws {
        let bridge = StubOSBridge(
            initial: .notDetermined,
            promptBehaviour: .returning(.authorized),
        )
        let registrar = PushTokenRegistrar()
        let vm = Self.makeViewModel(bridge: bridge, registrar: registrar)
        await vm.start()
        vm.postponeAuthorization()
        #expect(vm.state == .postponed)

        await vm.requestAuthorization()

        #expect(vm.state == .awaitingAPNsToken)
        #expect(vm.authorization == .authorized)
        #expect(await bridge.promptCallCount == 1)
        #expect(await bridge.registerForRemoteCallCount == 1)
        vm.stop()
    }

    /// Postpone must NOT backtrack a terminal state. A VM that is
    /// already registered, denied, or busy has no business showing
    /// the primer pane, so the method silently no-ops.
    @MainActor
    @Test
    func postponeIsNoOpOutsideIdle() async throws {
        let bridge = StubOSBridge(
            initial: .notDetermined,
            promptBehaviour: .returning(.denied),
        )
        let registrar = PushTokenRegistrar()
        let vm = Self.makeViewModel(bridge: bridge, registrar: registrar)
        await vm.start()
        await vm.requestAuthorization()
        #expect(vm.state == .authorizationDenied)

        vm.postponeAuthorization()

        #expect(vm.state == .authorizationDenied,
                "postpone must not overwrite a terminal denial state")
        vm.stop()
    }

    // MARK: - handleDidRegister / handleDidFailToRegister

    @MainActor
    @Test
    func handleDidRegisterKicksFullRoundTrip() async throws {
        let transport = InMemoryDeviceTransport()
        let client = try await Self.makeConnectedClient(transport: transport)
        let server = await Self.makeAckingServer(transport: transport)
        defer { Task { await server.stop(); await client.disconnect() } }

        let bridge = StubOSBridge(initial: .authorized)
        let registrar = PushTokenRegistrar()
        await registrar.setClient(client)
        let vm = Self.makeViewModel(bridge: bridge, registrar: registrar)
        await vm.start()
        // Forget the auto-kicked awaitingAPNsToken state and feed
        // the token manually (mirroring the AppDelegate callback).
        await vm.handleDidRegister(tokenData: Self.tokenData())
        let final = await Self.waitForState(on: vm) {
            if case .registered = $0 { return true }
            return false
        }
        if case let .registered(token) = final {
            #expect(token.hex.count == PushToken.minimumLength * 2)
        } else {
            Issue.record("expected .registered state, got \(final)")
        }
        vm.stop()
    }

    @MainActor
    @Test
    func handleDidRegisterInvalidTokenFailsClosed() async throws {
        let bridge = StubOSBridge(initial: .authorized)
        let registrar = PushTokenRegistrar()
        let vm = Self.makeViewModel(bridge: bridge, registrar: registrar)
        await vm.start()
        // 4 bytes < 32 byte minimum — registrar never reaches the
        // wire; state lands on a typed `.invalidToken` failure so
        // the banner surfaces a precise message.
        await vm.handleDidRegister(tokenData: Data([0x01, 0x02, 0x03, 0x04]))
        guard case let .failed(error) = vm.state else {
            Issue.record("expected .failed, got \(vm.state)")
            return
        }
        guard case .invalidToken = error else {
            Issue.record("expected .invalidToken, got \(error)")
            return
        }
        vm.stop()
    }

    @MainActor
    @Test
    func handleDidFailToRegisterSurfacesAPNsError() {
        struct APNsBoom: Error {
            var localizedDescription: String { "apns explosion" }
        }
        let bridge = StubOSBridge()
        let registrar = PushTokenRegistrar()
        let vm = Self.makeViewModel(bridge: bridge, registrar: registrar)
        vm.handleDidFailToRegister(error: APNsBoom())
        guard case let .failed(error) = vm.state else {
            Issue.record("expected .failed, got \(vm.state)")
            return
        }
        guard case .apnsRegistrationFailed = error else {
            Issue.record("expected .apnsRegistrationFailed, got \(error)")
            return
        }
        vm.stop()
    }

    // MARK: - Deep-link queue

    @MainActor
    @Test
    func handleDidReceiveQueuesDeepLink() {
        let bridge = StubOSBridge()
        let registrar = PushTokenRegistrar()
        let vm = Self.makeViewModel(bridge: bridge, registrar: registrar)
        vm.handleDidReceive(payload: .hopperEmpty)
        vm.handleDidReceive(payload: .newCatDetected(.init(trackIDHint: 1, confidence: 0.9)))
        #expect(vm.pendingDeepLinks == [.hopperStatus, .history])
        let first = vm.consumePendingDeepLink()
        #expect(first == .hopperStatus)
        #expect(vm.pendingDeepLinks == [.history])
        let second = vm.consumePendingDeepLink()
        #expect(second == .history)
        #expect(vm.pendingDeepLinks.isEmpty)
        #expect(vm.consumePendingDeepLink() == nil)
        vm.stop()
    }

    // MARK: - Outcome fold from registrar

    @MainActor
    @Test
    func registrarFailureFoldsIntoFailedState() async throws {
        // The VM's outcomes watcher must fold a registrar `.failed`
        // into `.failed` state. Without this fold a register error
        // would leave the VM stuck on `.registering` forever.
        let transport = InMemoryDeviceTransport()
        let client = try await Self.makeConnectedClient(transport: transport)
        let server = ScriptedDeviceServer(transport: transport) { request in
            if case .registerPushToken = request.request {
                return .error(code: 99, message: "boom")
            }
            return .silent
        }
        await server.run()
        defer { Task { await server.stop(); await client.disconnect() } }

        let bridge = StubOSBridge(initial: .authorized)
        let registrar = PushTokenRegistrar()
        await registrar.setClient(client)
        let vm = Self.makeViewModel(bridge: bridge, registrar: registrar)
        await vm.start()
        await vm.handleDidRegister(tokenData: Self.tokenData())
        let final = await Self.waitForState(on: vm) {
            if case .failed = $0 { return true }
            return false
        }
        guard case .failed = final else {
            Issue.record("expected .failed, got \(final)")
            return
        }
        vm.stop()
    }

    @MainActor
    @Test
    func registrarUnregisteredFoldsBackToIdle() async throws {
        // Sign-out path: the registrar emits `.unregistered` and
        // the VM returns to `.idle` so a fresh sign-in starts the
        // flow cleanly.
        let transport = InMemoryDeviceTransport()
        let client = try await Self.makeConnectedClient(transport: transport)
        let server = await Self.makeAckingServer(transport: transport)
        defer { Task { await server.stop(); await client.disconnect() } }

        let bridge = StubOSBridge(initial: .authorized)
        let registrar = PushTokenRegistrar()
        await registrar.setClient(client)
        let vm = Self.makeViewModel(bridge: bridge, registrar: registrar)
        await vm.start()
        await vm.handleDidRegister(tokenData: Self.tokenData())
        _ = await Self.waitForState(on: vm) {
            if case .registered = $0 { return true }
            return false
        }
        vm.handleDidReceive(payload: .hopperEmpty)
        #expect(!vm.pendingDeepLinks.isEmpty)

        await registrar.sessionDidSignOut()
        let final = await Self.waitForState(on: vm) { $0 == .idle }
        #expect(final == .idle)
        // Queued deep-links must be wiped on sign-out so the new
        // user does not inherit the prior user's routes.
        #expect(vm.pendingDeepLinks.isEmpty)
        vm.stop()
    }
}
