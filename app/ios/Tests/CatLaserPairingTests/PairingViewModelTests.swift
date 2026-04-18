import CatLaserAuth
import CatLaserDevice
import CatLaserDeviceTestSupport
import CatLaserPairing
import CatLaserPairingTestSupport
import Foundation
import Testing

@Suite("PairingViewModel", .serialized)
@MainActor
struct PairingViewModelTests {
    private func makeEndpoint() throws -> DeviceEndpoint {
        try DeviceEndpoint(host: "100.64.1.7", port: 9820)
    }

    private func makeDevice() throws -> PairedDevice {
        PairedDevice(
            id: "cat-001",
            name: "Kitchen",
            endpoint: try makeEndpoint(),
            pairedAt: Date(timeIntervalSince1970: 1_712_345_678),
        )
    }

    private func makeClient(outcomes: [MockHTTPClient.Outcome]) -> (MockHTTPClient, PairingClient) {
        let http = MockHTTPClient(outcomes: outcomes)
        return (http, PairingClient(baseURL: URL(string: "https://api.example.com")!, http: http))
    }

    private func makeFactory() -> @Sendable (PairedDevice) -> ConnectionManager {
        { device in
            let transport = InMemoryDeviceTransport()
            let client = DeviceClient(transport: transport)
            _ = client
            return ConnectionManager(
                endpoint: device.endpoint,
                clientFactory: { _ in DeviceClient(transport: InMemoryDeviceTransport()) },
                pathMonitor: FakeNetworkPathMonitor(currentAtStart: .unsatisfied),
                configuration: ConnectionManager.Configuration(
                    heartbeatInterval: 60,
                    heartbeatFailureCap: 10,
                    initialBackoff: 60,
                    maxBackoff: 60,
                    jitter: 0,
                ),
            )
        }
    }

    // MARK: - start()

    @Test
    func startWithoutPersistedDeviceAdvancesToScanningWhenAuthorized() async throws {
        let (_, client) = makeClient(outcomes: [])
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
        )
        await vm.start()
        #expect(vm.phase == .scanning)
    }

    @Test
    func startWithoutPersistedDeviceAsksForPermissionWhenNotDetermined() async throws {
        let (_, client) = makeClient(outcomes: [])
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .notDetermined)
        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
        )
        await vm.start()
        #expect(vm.phase == .needsCameraPermission(.notDetermined))
    }

    @Test
    func startWithPersistedDeviceJumpsToPaired() async throws {
        let device = try makeDevice()
        let store = PublicInMemoryEndpointStore(initial: device)
        let (_, client) = makeClient(outcomes: [])
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
        )
        await vm.start()
        if case let .paired(loaded) = vm.phase {
            #expect(loaded == device)
        } else {
            Issue.record("expected .paired, got \(vm.phase)")
        }
        if let m = vm.currentConnectionManager {
            await m.stop()
        }
    }

    // MARK: - permission

    @Test
    func requestCameraPermissionAdvancesToScanningOnAuthorize() async throws {
        let (_, client) = makeClient(outcomes: [])
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .notDetermined)
        await gate.queuePostPromptStatus(.authorized)
        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
        )
        await vm.start()
        #expect(vm.phase == .needsCameraPermission(.notDetermined))
        await vm.requestCameraPermission()
        #expect(vm.phase == .scanning)
    }

    @Test
    func requestCameraPermissionStaysOnPermissionScreenOnDeny() async throws {
        let (_, client) = makeClient(outcomes: [])
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .notDetermined)
        await gate.queuePostPromptStatus(.denied)
        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
        )
        await vm.start()
        await vm.requestCameraPermission()
        #expect(vm.phase == .needsCameraPermission(.denied))
    }

    // MARK: - submitScannedCode

    @Test
    func scannedCodeExchangesAndPersists() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.json([
            "device_id": "cat-001",
            "device_name": "Kitchen",
            "host": "100.64.1.7",
            "port": 9820,
        ])))
        let client = PairingClient(baseURL: URL(string: "https://api.example.com")!, http: http)
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .authorized)

        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            clock: { Date(timeIntervalSince1970: 1_712_345_678) },
        )
        await vm.start()
        let code = try PairingCode(code: "ABCDEFGHIJKLMNOP", deviceID: "cat-001")
        await vm.submitScannedCode(code)

        if case let .paired(device) = vm.phase {
            #expect(device.id == "cat-001")
        } else {
            Issue.record("expected .paired, got \(vm.phase)")
        }
        let persisted = await store.snapshot()
        #expect(persisted?.id == "cat-001")

        if let m = vm.currentConnectionManager {
            await m.stop()
        }
    }

    @Test
    func scannedCodeServerFailureSurfacesAsFailed() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.json(["message": "already claimed"], status: 409)))
        let client = PairingClient(baseURL: URL(string: "https://api.example.com")!, http: http)
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .authorized)

        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
        )
        await vm.start()
        let code = try PairingCode(code: "ABCDEFGHIJKLMNOP", deviceID: "cat-001")
        await vm.submitScannedCode(code)

        if case let .failed(error) = vm.phase {
            if case .codeAlreadyUsed = error {
                // good
            } else {
                Issue.record("expected .codeAlreadyUsed, got \(error)")
            }
        } else {
            Issue.record("expected .failed, got \(vm.phase)")
        }
        #expect(await store.snapshot() == nil)
    }

    @Test
    func scannedCodeStorageFailureSurfacesAsFailed() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.json([
            "device_id": "cat-001",
            "host": "100.64.1.7",
            "port": 9820,
        ])))
        let client = PairingClient(baseURL: URL(string: "https://api.example.com")!, http: http)
        let store = PublicInMemoryEndpointStore()
        await store.queueSaveFailure(.storage("disk full"))
        let gate = FakeCameraPermissionGate(initial: .authorized)

        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
        )
        await vm.start()
        let code = try PairingCode(code: "ABCDEFGHIJKLMNOP", deviceID: "cat-001")
        await vm.submitScannedCode(code)

        if case .failed = vm.phase {
            // good
        } else {
            Issue.record("expected .failed, got \(vm.phase)")
        }
    }

    @Test
    func scannedCodeIgnoredWhileBusy() async throws {
        let (_, client) = makeClient(outcomes: [])
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
        )
        // Pretend we're mid-check; scan should drop on the floor.
        let code = try PairingCode(code: "ABCDEFGHIJKLMNOP", deviceID: "cat-001")
        // phase is .checkingExisting by default
        await vm.submitScannedCode(code)
        #expect(vm.phase == .checkingExisting)
    }

    // MARK: - manual entry

    @Test
    func manualEntryRejectsInvalidCode() async throws {
        let (_, client) = makeClient(outcomes: [])
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
        )
        await vm.start()
        vm.switchToManualEntry()
        vm.setManualDraft("not a url")
        await vm.submitManualCode()
        if case let .failed(error) = vm.phase {
            if case .invalidCode = error {
                // good
            } else {
                Issue.record("expected .invalidCode, got \(error)")
            }
        } else {
            Issue.record("expected .failed, got \(vm.phase)")
        }
    }

    @Test
    func manualEntryAcceptsValidCodeAndExchanges() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.json([
            "device_id": "cat-001",
            "host": "100.64.1.7",
            "port": 9820,
        ])))
        let client = PairingClient(baseURL: URL(string: "https://api.example.com")!, http: http)
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
        )
        await vm.start()
        vm.switchToManualEntry()
        vm.setManualDraft("catlaser://pair?code=ABCDEFGHIJKLMNOP&device=cat-001")
        await vm.submitManualCode()
        if case .paired = vm.phase {
            // good
        } else {
            Issue.record("expected .paired, got \(vm.phase)")
        }
        if let m = vm.currentConnectionManager {
            await m.stop()
        }
    }

    // MARK: - unpair

    @Test
    func unpairWipesStoreAndReturnsToScanner() async throws {
        let device = try makeDevice()
        let store = PublicInMemoryEndpointStore(initial: device)
        let (_, client) = makeClient(outcomes: [])
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
        )
        await vm.start()
        #expect({
            if case .paired = vm.phase { return true }
            return false
        }())

        await vm.unpair()
        #expect(vm.phase == .scanning)
        #expect(await store.snapshot() == nil)
    }

    // MARK: - dismissError

    @Test
    func dismissErrorWithStoredDeviceGoesBackToPaired() async throws {
        // Scenario: user was paired, attempted to unpair, but the
        // store.delete() call threw. The VM lands in `.failed` while
        // the store still holds the row. Tapping "dismiss" should
        // restore the paired state rather than dropping the user
        // into the scanner.
        let device = try makeDevice()
        let store = PublicInMemoryEndpointStore(initial: device)
        await store.queueDeleteFailure(.storage("disk full"))

        let (_, client) = makeClient(outcomes: [])
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
        )
        await vm.start()
        // start → .paired(device)

        await vm.unpair()
        // unpair hits the queued delete failure → phase = .failed,
        // but the device is still in the store.
        if case .failed = vm.phase {
            // good
        } else {
            Issue.record("expected .failed after delete-failure, got \(vm.phase)")
        }

        await store.clearInjectedFailures()
        await vm.dismissError()
        if case .paired = vm.phase {
            // good
        } else {
            Issue.record("expected .paired after dismiss, got \(vm.phase)")
        }
        if let m = vm.currentConnectionManager {
            await m.stop()
        }
    }

    @Test
    func dismissErrorWithoutStoredDeviceGoesToScanner() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.json(["message": "not found"], status: 404)))
        let client = PairingClient(baseURL: URL(string: "https://api.example.com")!, http: http)
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
        )
        await vm.start()
        let code = try PairingCode(code: "ABCDEFGHIJKLMNOP", deviceID: "cat-001")
        await vm.submitScannedCode(code)
        await vm.dismissError()
        #expect(vm.phase == .scanning)
    }

    // MARK: - corrupted store load

    @Test
    func startFailsToFailedOnCorruptedStoreRow() async throws {
        let (_, client) = makeClient(outcomes: [])
        let store = PublicInMemoryEndpointStore()
        await store.queueLoadFailure(.storage("decode failed"))
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
        )
        await vm.start()
        if case .failed = vm.phase {
            // good
        } else {
            Issue.record("expected .failed, got \(vm.phase)")
        }
    }

    // MARK: - switchToScanner re-checks permission

    @Test
    func switchToScannerFromManualEntryRechecksPermission() async throws {
        let (_, client) = makeClient(outcomes: [])
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
        )
        await vm.start()
        vm.switchToManualEntry()

        await gate.setResting(.denied)
        await vm.switchToScanner()

        #expect(vm.phase == .needsCameraPermission(.denied))
    }
}
