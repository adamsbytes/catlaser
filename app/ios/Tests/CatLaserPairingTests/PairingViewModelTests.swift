import CatLaserAuth
import CatLaserDevice
import CatLaserDeviceTestSupport
import CatLaserPairingTestSupport
import Foundation
import Testing

@testable import CatLaserPairing

@Suite("PairingViewModel", .serialized)
@MainActor
struct PairingViewModelTests {
    /// Test pairing fixture's Ed25519 pubkey. The bytes are
    /// deterministic (0x42 × 32) and the base64url-no-pad encoding
    /// is what `PairingClient`/`PairedDevicesClient` expect on the
    /// wire.
    private static let testPublicKey = Data(repeating: 0x42, count: 32)
    private static let testPublicKeyB64URL = testPublicKey
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")

    private func makeEndpoint() throws -> DeviceEndpoint {
        try DeviceEndpoint(host: "100.64.1.7", port: 9820)
    }

    private func makeDevice() throws -> PairedDevice {
        PairedDevice(
            id: "cat-001",
            name: "Kitchen",
            endpoint: try makeEndpoint(),
            pairedAt: Date(timeIntervalSince1970: 1_712_345_678),
            devicePublicKey: Self.testPublicKey,
        )
    }

    private func makeClient(outcomes: [MockHTTPClient.Outcome]) -> (MockHTTPClient, PairingClient) {
        let http = MockHTTPClient(outcomes: outcomes)
        return (
            http,
            PairingClient(
                baseURL: URL(string: "https://api.example.com")!,
                http: signedTestClient(wrapping: http),
            ),
        )
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
            pairingAuthGate: { .allowed },
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
            pairingAuthGate: { .allowed },
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
            pairingAuthGate: { .allowed },
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
            pairingAuthGate: { .allowed },
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
            pairingAuthGate: { .allowed },
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
            "device_public_key": Self.testPublicKeyB64URL,
        ])))
        let client = PairingClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: signedTestClient(wrapping: http),
        )
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .authorized)

        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .allowed },
            clock: { Date(timeIntervalSince1970: 1_712_345_678) },
        )
        await vm.start()
        let code = try PairingCode(code: "ABCDEFGHIJKLMNOP", deviceID: "cat-001")
        await vm.submitScannedCode(code)
        // The confirmation gate parks the scan; no HTTP has fired yet.
        if case let .confirming(parked) = vm.phase {
            #expect(parked == code)
        } else {
            Issue.record("expected .confirming after scan, got \(vm.phase)")
        }
        #expect(await http.requests().isEmpty)

        await vm.confirmPairing()

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

    // MARK: - Confirmation gate

    /// The scanner's decode must NOT fire the pair exchange: it parks
    /// the code in `.confirming(code)` and waits for an explicit
    /// `confirmPairing()` tap. A probe that records HTTP traffic after
    /// a scan would see nothing.
    @Test
    func scannedCodeParksInConfirmingWithoutNetwork() async throws {
        let http = MockHTTPClient()
        // Enqueue a response that would fail the test if it were
        // consumed — every request the mock receives, it pops one
        // outcome, so an accidental pair exchange would reach this
        // response and advance the VM silently. Seeing `.confirming`
        // with no consumed outcomes is the real assertion.
        await http.enqueue(.response(.json([
            "device_id": "cat-001",
            "host": "100.64.1.7",
            "port": 9820,
            "device_public_key": Self.testPublicKeyB64URL,
        ])))
        let client = PairingClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: signedTestClient(wrapping: http),
        )
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .allowed },
        )
        await vm.start()
        let code = try PairingCode(code: "ABCDEFGHIJKLMNOP", deviceID: "cat-001")
        await vm.submitScannedCode(code)

        if case let .confirming(parked) = vm.phase {
            #expect(parked == code)
            #expect(parked.deviceID == "cat-001")
        } else {
            Issue.record("expected .confirming, got \(vm.phase)")
        }
        // No HTTP traffic: the coordination server must not hear about
        // the decoded code until the user taps "Pair".
        #expect(await http.requests().isEmpty)
        #expect(await store.snapshot() == nil)
    }

    /// Cancelling the confirmation returns to the scanner without
    /// touching the coordination server or the keychain. Regression
    /// guard for anyone who might add a "preload" call.
    @Test
    func cancelPairingConfirmationReturnsToScannerWithoutNetwork() async throws {
        let http = MockHTTPClient()
        // A queued response proves the mock would have been called —
        // the assertion is that it was NOT.
        await http.enqueue(.response(.json([
            "device_id": "cat-001",
            "host": "100.64.1.7",
            "port": 9820,
            "device_public_key": Self.testPublicKeyB64URL,
        ])))
        let client = PairingClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: signedTestClient(wrapping: http),
        )
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .allowed },
        )
        await vm.start()
        let code = try PairingCode(code: "ABCDEFGHIJKLMNOP", deviceID: "cat-001")
        await vm.submitScannedCode(code)
        await vm.cancelPairingConfirmation()

        #expect(vm.phase == .scanning)
        #expect(await http.requests().isEmpty)
        #expect(await store.snapshot() == nil)
    }

    /// `confirmPairing` from a non-`.confirming` phase must be a no-op
    /// so a stray tap after navigation cannot resurrect a stale code.
    @Test
    func confirmPairingNoOpFromNonConfirmingPhase() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.json([
            "device_id": "cat-001",
            "host": "100.64.1.7",
            "port": 9820,
            "device_public_key": Self.testPublicKeyB64URL,
        ])))
        let client = PairingClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: signedTestClient(wrapping: http),
        )
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .allowed },
        )
        await vm.start()
        // Skip the confirming hop entirely — we're still in .scanning.
        await vm.confirmPairing()
        #expect(vm.phase == .scanning)
        #expect(await http.requests().isEmpty)
    }

    /// Manual entry also parks in `.confirming` before hitting the
    /// coordination server, matching the scanner flow.
    @Test
    func manualCodeParksInConfirmingWithoutNetwork() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.json([
            "device_id": "cat-001",
            "host": "100.64.1.7",
            "port": 9820,
            "device_public_key": Self.testPublicKeyB64URL,
        ])))
        let client = PairingClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: signedTestClient(wrapping: http),
        )
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .allowed },
        )
        await vm.start()
        vm.switchToManualEntry()
        vm.setManualDraft("catlaser://pair?code=ABCDEFGHIJKLMNOP&device=cat-001")
        await vm.submitManualCode()
        if case let .confirming(parked) = vm.phase {
            #expect(parked.deviceID == "cat-001")
        } else {
            Issue.record("expected .confirming after manual submit, got \(vm.phase)")
        }
        #expect(await http.requests().isEmpty)
    }

    @Test
    func scannedCodeServerFailureSurfacesAsFailed() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.json(["message": "already claimed"], status: 409)))
        let client = PairingClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: signedTestClient(wrapping: http),
        )
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .authorized)

        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .allowed },
        )
        await vm.start()
        let code = try PairingCode(code: "ABCDEFGHIJKLMNOP", deviceID: "cat-001")
        await vm.submitScannedCode(code)
        await vm.confirmPairing()

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
            "device_public_key": Self.testPublicKeyB64URL,
        ])))
        let client = PairingClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: signedTestClient(wrapping: http),
        )
        let store = PublicInMemoryEndpointStore()
        await store.queueSaveFailure(.storage("disk full"))
        let gate = FakeCameraPermissionGate(initial: .authorized)

        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .allowed },
        )
        await vm.start()
        let code = try PairingCode(code: "ABCDEFGHIJKLMNOP", deviceID: "cat-001")
        await vm.submitScannedCode(code)
        await vm.confirmPairing()

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
            pairingAuthGate: { .allowed },
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
            pairingAuthGate: { .allowed },
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
            "device_public_key": Self.testPublicKeyB64URL,
        ])))
        let client = PairingClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: signedTestClient(wrapping: http),
        )
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .allowed },
        )
        await vm.start()
        vm.switchToManualEntry()
        vm.setManualDraft("catlaser://pair?code=ABCDEFGHIJKLMNOP&device=cat-001")
        await vm.submitManualCode()
        await vm.confirmPairing()
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
            pairingAuthGate: { .allowed },
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
            pairingAuthGate: { .allowed },
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
        let client = PairingClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: signedTestClient(wrapping: http),
        )
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: client,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .allowed },
        )
        await vm.start()
        let code = try PairingCode(code: "ABCDEFGHIJKLMNOP", deviceID: "cat-001")
        await vm.submitScannedCode(code)
        await vm.confirmPairing()
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
            pairingAuthGate: { .allowed },
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
            pairingAuthGate: { .allowed },
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
            let pubkeyB64URL = device.devicePublicKey
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return [
                "device_id": device.id,
                "device_name": name,
                "host": device.endpoint.host,
                "port": Int(device.endpoint.port),
                "paired_at": pairedAt,
                "device_public_key": pubkeyB64URL,
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
            http: signedTestClient(wrapping: http),
        )
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: pairingClient,
            pairedDevicesClient: pairedList,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .allowed },
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
            http: signedTestClient(wrapping: http),
        )
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: pairingClient,
            pairedDevicesClient: pairedList,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .allowed },
        )
        await vm.start()
        #expect(vm.phase == .scanning)
        #expect(try await store.load() == nil)
    }

    @Test
    func startAdoptsCachedDeviceOn401FromListEndpoint() async throws {
        // A 401 is an authentication failure, NOT an authoritative
        // ownership revocation. The server is saying "your bearer
        // is bad," not "this device is no longer yours." Wiping the
        // pairing on every bearer expiry would force users who had a
        // session time out to go locate the physical device and
        // generate a fresh single-use QR — a terrible UX and
        // decoupled from the actual ownership check.
        //
        // The only authoritative "not yours" signal is a 2xx list
        // that omits the device id. A 401 keeps the cached pairing
        // intact; separately the signed HTTP client fires its
        // `onSessionExpired` callback, which the composition root
        // wires to `AuthCoordinator.handleSessionExpired()` so the
        // UI can route the user to sign in again without touching
        // the keychain-held pairing.
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
            http: signedTestClient(wrapping: http),
        )
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: pairingClient,
            pairedDevicesClient: pairedList,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .allowed },
        )
        await vm.start()
        if case let .paired(loaded) = vm.phase {
            #expect(loaded == device)
        } else {
            Issue.record("expected .paired on 401 from list endpoint, got \(vm.phase)")
        }
        #expect(try await store.load() == device)
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
            http: signedTestClient(wrapping: http),
        )
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: pairingClient,
            pairedDevicesClient: pairedList,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .allowed },
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
            pairingAuthGate: { .allowed },
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
            http: signedTestClient(wrapping: http),
        )
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: pairingClient,
            pairedDevicesClient: pairedList,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .allowed },
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
            http: signedTestClient(wrapping: http),
        )
        let gate = FakeCameraPermissionGate(initial: .authorized)
        // Set a zero interval so the second call is always allowed.
        let vm = PairingViewModel(
            pairingClient: pairingClient,
            pairedDevicesClient: pairedList,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .allowed },
            reverifyInterval: 0,
        )
        await vm.start()
        await vm.reverifyOwnershipIfNeeded()
        #expect(vm.phase == .scanning)
        #expect(try await store.load() == nil)
    }

    @Test
    func reverifyOwnershipIfNeededKeepsPairingOn401() async throws {
        // The post-adoption reverify path must treat a 401 as
        // indeterminate exactly like the `start()` path. Otherwise a
        // scene-foreground event that fires after a sub-minute session
        // expiry would wipe the pairing the user just legitimately
        // established. The session-expiry UX lives in the auth
        // coordinator (via `onSessionExpired` → `sessionDidExpire`);
        // the pairing module's job is to keep the device record alive.
        let device = try makeDevice()
        let store = PublicInMemoryEndpointStore(initial: device)
        let (_, pairingClient) = makeClient(outcomes: [])
        let http = MockHTTPClient(outcomes: [
            // First call (start) confirms ownership.
            .response(makePairedListResponse(for: [device])),
            // Second call (manual reverify) returns 401.
            .response(HTTPResponse.json(
                ["ok": false, "error": ["code": "SESSION_REQUIRED", "message": "expired"]],
                status: 401,
            )),
        ])
        let pairedList = PairedDevicesClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: signedTestClient(wrapping: http),
        )
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: pairingClient,
            pairedDevicesClient: pairedList,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .allowed },
            reverifyInterval: 0,
        )
        await vm.start()
        await vm.reverifyOwnershipIfNeeded()
        if case let .paired(loaded) = vm.phase {
            #expect(loaded == device)
        } else {
            Issue.record("expected .paired after 401 reverify, got \(vm.phase)")
        }
        #expect(try await store.load() == device)
        if let m = vm.currentConnectionManager {
            await m.stop()
        }
    }

    @Test
    func reverifyOwnershipKeepsPairingWhenBearerStoreEmpty() async throws {
        // The other half of the 401 story: if the SignedHTTPClient
        // short-circuits with `.missingBearerToken` (store read
        // returned nil), the pairing module must still treat it as
        // indeterminate. Historically this path coalesced with the
        // server's 401 into a single `.missingSession` signal that
        // wiped the keychain; the fix keeps the pairing and lets the
        // auth coordinator drive the re-sign-in UX.
        let device = try makeDevice()
        let store = PublicInMemoryEndpointStore(initial: device)
        let (_, pairingClient) = makeClient(outcomes: [])
        // Signed client reads the (empty) bearer store and throws
        // `AuthError.missingBearerToken` BEFORE issuing any HTTP call.
        // `signedTestClientWithoutBearer` is a companion helper that
        // wires an empty-session store into the signed wrapper so the
        // pre-wire check fires.
        let pairedList = PairedDevicesClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: signedTestClientWithoutBearer(),
        )
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: pairingClient,
            pairedDevicesClient: pairedList,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .allowed },
        )
        await vm.start()
        if case let .paired(loaded) = vm.phase {
            #expect(loaded == device)
        } else {
            Issue.record(
                "expected .paired when bearer store is empty (indeterminate), got \(vm.phase)",
            )
        }
        #expect(try await store.load() == device)
        if let m = vm.currentConnectionManager {
            await m.stop()
        }
    }

    // MARK: - Server-confirmed unpair on terminal AUTH_REVOKED (Finding 1)

    /// SECURITY-CRITICAL: When the supervisor declares
    /// `.failed(.authRevoked)`, the keychain pairing is wiped ONLY
    /// after the coordination server's authoritative paired-devices
    /// list confirms the revocation. A forged AUTH_REVOKED frame
    /// from a tunnel-internal MitM (the only attacker model that can
    /// reach the post-handshake AUTH_REVOKED gate) cannot wipe the
    /// pairing as long as the server still recognises it.
    ///
    /// This test simulates the supervisor-side terminal auth-revoked
    /// signal directly (via the `@testable`-internal
    /// `unpairAfterRevocation` entry point, bypassing the full
    /// `ConnectionManager` round-trip) and asserts the keychain
    /// survives when the server responds with the device still in
    /// the list.
    @Test
    func authRevokedSurvivesWhenServerStillReportsOwnership() async throws {
        let device = try makeDevice()
        let store = PublicInMemoryEndpointStore(initial: device)
        let (_, pairingClient) = makeClient(outcomes: [])
        // Server's paired list still contains the device — refuse the
        // wipe even though the device-side wire signal demanded it.
        let http = MockHTTPClient(outcomes: [
            // First call: start() ownership check confirms.
            .response(makePairedListResponse(for: [device])),
            // Second call: post-revocation confirmation also
            // confirms (server hasn't caught up, OR the AUTH_REVOKED
            // was forged by an in-tunnel attacker).
            .response(makePairedListResponse(for: [device])),
        ])
        let pairedList = PairedDevicesClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: signedTestClient(wrapping: http),
        )
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: pairingClient,
            pairedDevicesClient: pairedList,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .allowed },
            reverifyInterval: 0,
        )
        await vm.start()
        // VM is now `.paired(device)` — drive the auth-revoked unpair
        // path directly. The internal entry consults the server; the
        // mock returns "still owned" so the keychain row MUST stay.
        await vm.unpairAfterRevocation()
        #expect(try await store.load() == device,
                "server says still-owned: keychain pairing must survive a forged AUTH_REVOKED")
        if case .paired = vm.phase {
            // expected
        } else {
            Issue.record("phase should remain .paired when server confirms ownership; got \(vm.phase)")
        }
    }

    /// Companion to the above: when the server's paired list omits
    /// the device id, the wipe goes through. This is the legitimate-
    /// revocation path — both wire signal AND authoritative server
    /// state agree.
    @Test
    func authRevokedWipesWhenServerConfirmsRevocation() async throws {
        let device = try makeDevice()
        let store = PublicInMemoryEndpointStore(initial: device)
        let (_, pairingClient) = makeClient(outcomes: [])
        let http = MockHTTPClient(outcomes: [
            // start() ownership check confirms.
            .response(makePairedListResponse(for: [device])),
            // Post-revocation confirmation: device is gone.
            .response(makePairedListResponse(for: [])),
        ])
        let pairedList = PairedDevicesClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: signedTestClient(wrapping: http),
        )
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: pairingClient,
            pairedDevicesClient: pairedList,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .allowed },
            reverifyInterval: 0,
        )
        await vm.start()
        await vm.unpairAfterRevocation()
        #expect(try await store.load() == nil,
                "server confirms revocation: keychain row must be wiped")
        #expect(vm.phase == .scanning,
                "phase should advance to scanner after a confirmed revocation; got \(vm.phase)")
    }

    /// When the server check is indeterminate (network down, 5xx,
    /// session expired, attestation failure), the keychain pairing
    /// MUST survive. The supervisor has terminated; the user can
    /// retry by relaunching, at which point `start()` re-runs the
    /// ownership check with a fresh attempt.
    @Test
    func authRevokedSurvivesWhenServerCheckIsIndeterminate() async throws {
        let device = try makeDevice()
        let store = PublicInMemoryEndpointStore(initial: device)
        let (_, pairingClient) = makeClient(outcomes: [])
        let http = MockHTTPClient(outcomes: [
            // start() ownership check confirms.
            .response(makePairedListResponse(for: [device])),
            // Post-revocation confirmation: server fails (5xx).
            .response(HTTPResponse.json(
                ["ok": false, "error": ["code": "INTERNAL", "message": "boom"]],
                status: 500,
            )),
        ])
        let pairedList = PairedDevicesClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: signedTestClient(wrapping: http),
        )
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: pairingClient,
            pairedDevicesClient: pairedList,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .allowed },
            reverifyInterval: 0,
        )
        await vm.start()
        await vm.unpairAfterRevocation()
        #expect(try await store.load() == device,
                "server check indeterminate: keychain pairing must survive")
    }

    /// The defensive bottom of the stack: if no
    /// `PairedDevicesClient` is wired (unusual in production but
    /// possible in test/migration setups), the server check resolves
    /// to `.indeterminate` and the pairing survives. The alternative
    /// — defaulting to "wipe" when no server check is possible —
    /// would let any forged AUTH_REVOKED frame succeed in
    /// denying-of-pairing on a misconfigured composition.
    @Test
    func authRevokedSurvivesWhenNoPairedDevicesClientWired() async throws {
        let device = try makeDevice()
        let store = PublicInMemoryEndpointStore(initial: device)
        let (_, pairingClient) = makeClient(outcomes: [])
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: pairingClient,
            pairedDevicesClient: nil, // <-- no client wired
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .allowed },
        )
        await vm.start()
        await vm.unpairAfterRevocation()
        #expect(try await store.load() == device,
                "missing pairedDevicesClient resolves to .indeterminate; pairing must survive")
    }

    // MARK: - Pairing-confirmation gate (Finding 5)

    /// SECURITY-CRITICAL: `confirmPairing` MUST consult the
    /// user-presence gate BEFORE issuing the HTTP exchange that
    /// adds a device to the user's account. A momentarily-unlocked
    /// phone whose `GatedBearerTokenStore` idle window is fresh
    /// would otherwise let an opportunistic attacker scan a malicious
    /// QR and silently pair the user's account to an
    /// attacker-controlled device.
    ///
    /// This test wires a gate that records every invocation and
    /// returns `.cancelled`; on cancel, NO HTTP call must fire and
    /// the VM must stay parked in `.confirming(code)` so the user
    /// can re-confirm if it was their cancellation.
    @Test
    func confirmPairingSkipsExchangeWhenGateCancels() async throws {
        let http = MockHTTPClient()
        let pairingClient = PairingClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: signedTestClient(wrapping: http),
        )
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let gateCalls = GateInvocationCounter()
        let vm = PairingViewModel(
            pairingClient: pairingClient,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: {
                await gateCalls.increment()
                return .cancelled
            },
        )
        await vm.start()
        let code = try PairingCode(code: "ABCDEFGHIJKLMNOP", deviceID: "cat-001")
        await vm.submitScannedCode(code)
        await vm.confirmPairing()
        // Gate WAS called (we didn't bypass it).
        #expect(await gateCalls.count == 1,
                "gate must be invoked exactly once per confirmPairing")
        // No HTTP fired.
        #expect(await http.requests().isEmpty,
                "cancelled gate must skip the wire exchange entirely")
        // Phase is parked in `.confirming` so the user can re-confirm.
        if case let .confirming(parked) = vm.phase {
            #expect(parked == code)
        } else {
            Issue.record("expected .confirming after cancelled gate, got \(vm.phase)")
        }
    }

    /// Companion: when the gate denies (biometric unavailable,
    /// lockout, anything not a deliberate cancel), the VM MUST surface
    /// a typed failure rather than silently default-allowing the
    /// exchange.
    @Test
    func confirmPairingSurfacesFailureWhenGateDenies() async throws {
        let http = MockHTTPClient()
        let pairingClient = PairingClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: signedTestClient(wrapping: http),
        )
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let vm = PairingViewModel(
            pairingClient: pairingClient,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: { .denied("biometric unavailable") },
        )
        await vm.start()
        let code = try PairingCode(code: "ABCDEFGHIJKLMNOP", deviceID: "cat-001")
        await vm.submitScannedCode(code)
        await vm.confirmPairing()
        // No HTTP fired.
        #expect(await http.requests().isEmpty)
        // VM lands on .failed(.attestation(...)).
        if case let .failed(error) = vm.phase, case let .attestation(reason) = error {
            #expect(reason.contains("biometric unavailable"))
        } else {
            Issue.record("expected .failed(.attestation) after denied gate, got \(vm.phase)")
        }
    }

    /// Happy path: gate returns `.allowed`, exchange proceeds, VM
    /// reaches `.paired`. Confirms the gate is positioned BEFORE
    /// the HTTP call (we observe the gate count first, then the
    /// exchange-success outcome).
    @Test
    func confirmPairingProceedsWhenGateAllows() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.json([
            "device_id": "cat-001",
            "device_name": "Kitchen",
            "host": "100.64.1.7",
            "port": 9820,
            "device_public_key": Self.testPublicKeyB64URL,
        ])))
        let pairingClient = PairingClient(
            baseURL: URL(string: "https://api.example.com")!,
            http: signedTestClient(wrapping: http),
        )
        let store = PublicInMemoryEndpointStore()
        let gate = FakeCameraPermissionGate(initial: .authorized)
        let gateCalls = GateInvocationCounter()
        let vm = PairingViewModel(
            pairingClient: pairingClient,
            store: store,
            permissionGate: gate,
            connectionManagerFactory: makeFactory(),
            pairingAuthGate: {
                await gateCalls.increment()
                return .allowed
            },
            clock: { Date(timeIntervalSince1970: 1_712_345_678) },
        )
        await vm.start()
        let code = try PairingCode(code: "ABCDEFGHIJKLMNOP", deviceID: "cat-001")
        await vm.submitScannedCode(code)
        await vm.confirmPairing()
        #expect(await gateCalls.count == 1)
        if case let .paired(device) = vm.phase {
            #expect(device.id == "cat-001")
        } else {
            Issue.record("expected .paired after allowed gate, got \(vm.phase)")
        }
        // The HTTP exchange ran (gate was a precondition, not a
        // bypass).
        #expect(await http.requests().count == 1)
        if let m = vm.currentConnectionManager {
            await m.stop()
        }
    }
}

/// Sendable counter for tests that need to observe how many times
/// the pairing gate closure fired. Captured into the `@Sendable`
/// closure by reference.
private actor GateInvocationCounter {
    private(set) var count: Int = 0
    func increment() { count += 1 }
}
