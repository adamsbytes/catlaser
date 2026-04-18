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

    // MARK: - ownership re-verification (#4)

    private func makePairedListResponse(for devices: [PairedDevice]) -> HTTPResponse {
        let entries: [[String: Any]] = devices.map { device in
            let pairedAt = ISO8601DateFormatter().string(from: device.pairedAt)
            let name: Any = device.name.isEmpty ? NSNull() : device.name
            return [
                "device_id": device.id,
                "device_name": name,
                "host": device.endpoint.host,
                "port": Int(device.endpoint.port),
                "paired_at": pairedAt,
            ]
        }
        return HTTPResponse.json(["ok": true, "data": ["devices": entries]])
    }

    @Test
    func startWithPersistedDeviceAdoptsWhenServerConfirmsOwnership() async throws {
        // The happy path after the ownership-re-check was wired: the
        // cached pairing is still active server-side, so the VM
        // transitions to `.paired` and bind the connection manager
        // just like before. This test pins the behavior so a later
        // tightening (e.g. hard-fail on any HTTP error) doesn't
        // regress the cached-claim re-adoption silently.
        let device = try makeDevice()
        let store = PublicInMemoryEndpointStore(initial: device)
        let (_, pairingClient) = makeClient(outcomes: [])
        let http = MockHTTPClient(outcomes: [
            .response(makePairedListResponse(for: [device])),
        ])
        let pairedList = PairedDevicesClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: http,
        )
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: pairingClient,
            pairedDevicesClient: pairedList,
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

    @Test
    func startWipesPersistedDeviceWhenServerReportsRevocation() async throws {
        // The primary guarantee behind fix #4: a cached pairing that
        // the server has superseded (revoked via a re-pair by another
        // user) must not survive launch. The VM wipes the Keychain
        // row and routes the user back to the scanner.
        let device = try makeDevice()
        let store = PublicInMemoryEndpointStore(initial: device)
        let (_, pairingClient) = makeClient(outcomes: [])
        let http = MockHTTPClient(outcomes: [
            .response(makePairedListResponse(for: [])),
        ])
        let pairedList = PairedDevicesClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: http,
        )
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: pairingClient,
            pairedDevicesClient: pairedList,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
        )
        await vm.start()
        #expect(vm.phase == .scanning)
        #expect(try await store.load() == nil)
    }

    @Test
    func startWipesPersistedDeviceOn401FromListEndpoint() async throws {
        // A 401 on the re-check means the server no longer has a
        // session for this bearer. That's the same authoritative
        // "you don't own anything" answer as an empty list — wipe
        // and route to re-pair (which will itself route to sign-in
        // because the bearer is invalid).
        let device = try makeDevice()
        let store = PublicInMemoryEndpointStore(initial: device)
        let (_, pairingClient) = makeClient(outcomes: [])
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse.json(
                ["ok": false, "error": ["code": "SESSION_REQUIRED", "message": "expired"]],
                status: 401,
            )),
        ])
        let pairedList = PairedDevicesClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: http,
        )
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: pairingClient,
            pairedDevicesClient: pairedList,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
        )
        await vm.start()
        #expect(vm.phase == .scanning)
        #expect(try await store.load() == nil)
    }

    @Test
    func startAdoptsCachedDeviceWhenListEndpointErrors() async throws {
        // Network failures and 5xx are NOT authoritative — they mean
        // "we don't know." Wiping the Keychain on a flaky-network
        // launch would be a terrible UX (user loses their pairing
        // because their tailnet hit a transient DNS issue). The VM
        // must fail open: adopt the cached pairing and retry on the
        // next reverify window.
        let device = try makeDevice()
        let store = PublicInMemoryEndpointStore(initial: device)
        let (_, pairingClient) = makeClient(outcomes: [])
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse.json(
                ["ok": false, "error": ["code": "INTERNAL", "message": "boom"]],
                status: 503,
            )),
        ])
        let pairedList = PairedDevicesClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: http,
        )
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: pairingClient,
            pairedDevicesClient: pairedList,
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
        #expect(try await store.load() == device)
        if let m = vm.currentConnectionManager {
            await m.stop()
        }
    }

    @Test
    func startAdoptsCachedDeviceWhenNoPairedDevicesClientWired() async throws {
        // Backwards compatibility for construction sites (and tests)
        // that don't plumb the list client. The VM must adopt the
        // cached pairing unconditionally rather than treating the
        // missing client as "nothing owned." Tests that exercise
        // non-re-verification behavior rely on this.
        let device = try makeDevice()
        let store = PublicInMemoryEndpointStore(initial: device)
        let (_, pairingClient) = makeClient(outcomes: [])
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: pairingClient,
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

    @Test
    func reverifyOwnershipIfNeededHonorsCadence() async throws {
        // The VM must only fire a reverify request once per
        // `reverifyInterval`; a scene-foreground storm must not burn
        // an attested request per event. This test asserts that a
        // follow-up call within the interval is a no-op.
        let device = try makeDevice()
        let store = PublicInMemoryEndpointStore(initial: device)
        let (_, pairingClient) = makeClient(outcomes: [])
        let http = MockHTTPClient(outcomes: [
            .response(makePairedListResponse(for: [device])),
            .response(makePairedListResponse(for: [device])),
        ])
        let pairedList = PairedDevicesClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: http,
        )
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: pairingClient,
            pairedDevicesClient: pairedList,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            reverifyInterval: 60,
        )
        await vm.start()
        // First call already fired during `start()`.
        #expect(await http.requests().count == 1)
        // A second immediate call must NOT burn another attested
        // request.
        await vm.reverifyOwnershipIfNeeded()
        #expect(await http.requests().count == 1)
        if let m = vm.currentConnectionManager {
            await m.stop()
        }
    }

    @Test
    func reverifyOwnershipIfNeededWipesWhenServerRevokes() async throws {
        let device = try makeDevice()
        let store = PublicInMemoryEndpointStore(initial: device)
        let (_, pairingClient) = makeClient(outcomes: [])
        let http = MockHTTPClient(outcomes: [
            // First call (start) confirms ownership.
            .response(makePairedListResponse(for: [device])),
            // Second call (manual reverify after interval) reports
            // revocation.
            .response(makePairedListResponse(for: [])),
        ])
        let pairedList = PairedDevicesClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: http,
        )
        let gate = FakeCameraPermissionGate(initial: .authorized)
        // Set a zero interval so the second call is always allowed.
        let vm = PairingViewModel(
            pairingClient: pairingClient,
            pairedDevicesClient: pairedList,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            reverifyInterval: 0,
        )
        await vm.start()
        await vm.reverifyOwnershipIfNeeded()
        #expect(vm.phase == .scanning)
        #expect(try await store.load() == nil)
    }
}
