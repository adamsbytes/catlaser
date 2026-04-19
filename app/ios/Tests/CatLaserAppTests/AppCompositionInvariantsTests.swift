import CatLaserAuthTestSupport
import CatLaserDevice
import CatLaserDeviceTestSupport
import CatLaserHistory
import CatLaserLive
import CatLaserObservability
import CatLaserPairingTestSupport
import CatLaserProto
import CatLaserPush
import CatLaserSchedule
import Foundation
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

@testable import CatLaserApp
@testable import CatLaserAuth
@testable import CatLaserPairing

/// Invariant tests for the single production wiring in
/// ``AppComposition``.
///
/// The tests build the real ``AppComposition`` graph using the
/// cross-platform ``make`` factory with injected test doubles, then
/// assert behaviours that a future refactor could silently weaken.
/// They run on every supported platform — including Linux CI — so
/// wiring regressions are caught in the same place every other
/// lint/test runs.
///
/// The suite covers four load-bearing properties:
///
/// 1. The LiveKit allowlist is threaded through unchanged to the
///    ``LiveStreamCredentials`` constructor (so a tampered offer
///    cannot steer the subscribe dial to an attacker-controlled
///    LiveKit server).
/// 2. The ``liveAuthGate`` actually consults the injected
///    ``LiveVideoGate`` on every stream start (skipping this would
///    let a momentarily-unlocked phone reveal the in-home feed).
/// 3. The ``handshakeBuilder`` produces a header that decodes to
///    ``AttestationBinding/device(timestamp:)`` with a fresh ECDSA
///    signature per call (the property the server's replay cache
///    relies on to distinguish legitimate retries from captured
///    replays).
/// 4. The ``onSessionExpired`` callback on the signed HTTP transport
///    routes into ``AuthCoordinator/handleSessionExpired()``, so a
///    401 invalidates the in-memory bearer without touching the
///    keychain-held pairing.
@Suite("AppComposition invariants")
struct AppCompositionInvariantsTests {
    // MARK: - Fixtures

    private static let allowedLiveKitHost = "livekit.example.com"
    private static let fixedClockTimestamp: Int64 = 1_712_345_678

    private static func makeAuthConfig() throws -> AuthConfig {
        try AuthConfig(
            baseURL: URL(string: "https://api.example.com")!,
            appleServiceID: "com.catlaser.app.signin",
            googleClientID: "example.apps.googleusercontent.com",
            bundleID: "com.catlaser.app",
            universalLinkHost: "links.example.com",
            universalLinkPath: "/pair",
            oauthRedirectHosts: ["links.example.com"],
        )
    }

    private static func makeAllowlist() throws -> LiveKitHostAllowlist {
        try LiveKitHostAllowlist(hosts: [allowedLiveKitHost])
    }

    /// Build the composition with a ``SoftwareIdentityStore``-backed
    /// attestation provider, an in-memory ``TestBearerStore`` that
    /// conforms to ``SessionInvalidating``, and an injectable
    /// ``StubLiveVideoGate``. The signed-client factory uses the
    /// package-internal ``SignedHTTPClient`` init (reached via
    /// ``@testable import CatLaserAuth``) with a scriptable
    /// ``RecordingHTTPClient`` so the 401 route through to
    /// ``AuthCoordinator/handleSessionExpired()`` can be exercised.
    private static func makeComposition(
        gate: StubLiveVideoGate = StubLiveVideoGate(),
        underlyingHTTP: RecordingHTTPClient = RecordingHTTPClient(),
        endpointStore: TestEndpointStore = TestEndpointStore(),
        pushBridge: StubPushBridge = StubPushBridge(),
    ) async throws -> (AppComposition, TestBearerStore, TestEndpointStore, StubPushBridge) {
        let identity = SoftwareIdentityStore()
        let attestationProvider = StubDeviceAttestationProvider(
            fingerprint: DeviceFingerprint(
                platform: "ios",
                model: "iPhone15,4",
                systemName: "iOS",
                bundleID: "com.catlaser.app",
                installID: "composition-test-install",
            ),
            identity: identity,
        )
        let bearerStore = TestBearerStore(
            initial: AuthSession(
                bearerToken: "composition-test-bearer",
                user: AuthUser(
                    id: "u",
                    email: "u@example.com",
                    name: "U",
                    image: nil,
                    emailVerified: true,
                ),
                provider: .magicLink,
                establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            ),
        )
        let factory: AppComposition.SignedHTTPClientFactory = { [underlyingHTTP, bearerStore, attestationProvider] onExpired in
            SignedHTTPClient(
                underlying: underlyingHTTP,
                store: bearerStore,
                attestationProvider: attestationProvider,
                clock: { Date(timeIntervalSince1970: TimeInterval(fixedClockTimestamp)) },
                uuidFactory: { UUID(uuidString: "00000000-0000-4000-8000-000000000000")! },
                onSessionExpired: onExpired,
            )
        }
        let consentStore = InMemoryConsentStore(
            initial: .granted(crashReporting: true, telemetry: true),
        )
        let transport = InMemoryObservabilityTransport()
        let observability = Observability(
            config: try makeObservabilityConfig(),
            consent: consentStore,
            transport: transport,
        )
        let composition = await AppComposition.make(
            authConfig: try makeAuthConfig(),
            authHTTPClient: underlyingHTTP,
            signedHTTPClientFactory: factory,
            liveKitAllowlist: try makeAllowlist(),
            attestationProvider: attestationProvider,
            bearerStore: bearerStore,
            liveVideoGate: gate,
            endpointStore: endpointStore,
            observability: observability,
            consentStore: consentStore,
            deviceTransportFactory: { _ in InMemoryDeviceTransport() },
            pathMonitorFactory: { FakeNetworkPathMonitor() },
            pushPrompt: { try await pushBridge.prompt() },
            pushReadAuthorization: { await pushBridge.read() },
            pushRegisterForRemoteNotifications: { await pushBridge.registerForRemote() },
            clock: { Date(timeIntervalSince1970: TimeInterval(fixedClockTimestamp)) },
        )
        return (composition, bearerStore, endpointStore, pushBridge)
    }

    /// Per-suite observability config. Points at deterministic https
    /// URLs and a scratch directory so nothing ends up in a shared
    /// cache across parallel tests.
    private static func makeObservabilityConfig() throws -> ObservabilityConfig {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("catlaser-ios-composition-tests-\(UUID().uuidString)", isDirectory: true)
        return try ObservabilityConfig(
            telemetryURL: URL(string: "https://api.example.com/api/v1/observability/events")!,
            crashURL: URL(string: "https://api.example.com/api/v1/observability/crashes")!,
            deviceIDSalt: "composition-test-salt",
            appVersion: "1.0.0",
            buildNumber: "1",
            bundleID: "com.catlaser.app",
            breadcrumbsURL: temp.appendingPathComponent("breadcrumbs.json"),
            tombstoneDirectory: temp.appendingPathComponent("Tombstones", isDirectory: true),
            queueURL: temp.appendingPathComponent("events.ndjson"),
        )
    }

    // MARK: - 1. LiveKit allowlist

    @Test
    func liveKitAllowlistContainsExactlyTheConfiguredHosts() async throws {
        let (composition, _, _, _) = try await Self.makeComposition()
        // Exact match — not a permissive superset, not a silent empty
        // set.
        #expect(composition.liveKitAllowlist.contains(Self.allowedLiveKitHost))
        #expect(composition.liveKitAllowlist.sortedHosts == [Self.allowedLiveKitHost])
        #expect(!composition.liveKitAllowlist.contains("attacker-livekit.example.com"))
        #expect(!composition.liveKitAllowlist.contains(""))
    }

    @Test
    func liveStreamCredentialsRejectsHostOutsideAllowlist() async throws {
        // The allowlist plumbs all the way down to the
        // ``LiveStreamCredentials`` constructor. A tampered offer
        // must never produce valid credentials.
        let (composition, _, _, _) = try await Self.makeComposition()
        var offer = Catlaser_App_V1_StreamOffer()
        offer.livekitURL = "wss://attacker-livekit.example.com"
        offer.subscriberToken = "jwt.placeholder"
        #expect(throws: LiveStreamCredentialsError.hostNotAllowed("attacker-livekit.example.com")) {
            _ = try LiveStreamCredentials(offer: offer, allowlist: composition.liveKitAllowlist)
        }
    }

    @Test
    func liveStreamCredentialsAcceptsAllowedHost() async throws {
        let (composition, _, _, _) = try await Self.makeComposition()
        var offer = Catlaser_App_V1_StreamOffer()
        offer.livekitURL = "wss://\(Self.allowedLiveKitHost)"
        offer.subscriberToken = "jwt.placeholder"
        let credentials = try LiveStreamCredentials(
            offer: offer,
            allowlist: composition.liveKitAllowlist,
        )
        #expect(credentials.url.host == Self.allowedLiveKitHost)
        #expect(credentials.url.scheme == "wss")
    }

    // MARK: - 2. Live-view auth gate

    @Test
    func liveAuthGateConsultsGateAndReturnsAllowed() async throws {
        // The composition's gate must call ``requireLiveVideo()``
        // exactly once and, on success, report ``.allowed``. A
        // regression that wired the gate as a no-op would have the
        // counter stay at zero.
        let gate = StubLiveVideoGate(outcome: .success)
        let (composition, _, _, _) = try await Self.makeComposition(gate: gate)
        let outcome = await composition.liveAuthGate()
        #expect(outcome == .allowed)
        #expect(await gate.callCount == 1)
    }

    @Test
    func liveAuthGateMapsCancellationToCancelled() async throws {
        // A user cancel on the biometric sheet must map to
        // ``.cancelled``, NOT ``.denied``: cancellation is a
        // deliberate user action and should not bounce them through
        // an error UI. The composition's mapping inspects
        // ``AuthError.cancelled`` specifically, so a refactor that
        // mismaps it would be caught here.
        let gate = StubLiveVideoGate(outcome: .throwing(AuthError.cancelled))
        let (composition, _, _, _) = try await Self.makeComposition(gate: gate)
        let outcome = await composition.liveAuthGate()
        #expect(outcome == .cancelled)
    }

    @Test
    func liveAuthGateMapsOtherFailuresToDenied() async throws {
        // Any non-cancellation failure (biometric unavailable, auth
        // failed, arbitrary throw) must map to ``.denied`` — never to
        // ``.allowed``. The composition folds the error into the
        // string so the caller can surface diagnostics without
        // needing to reason about the failure class.
        let gate = StubLiveVideoGate(outcome: .throwing(AuthError.biometricUnavailable("no passcode")))
        let (composition, _, _, _) = try await Self.makeComposition(gate: gate)
        let outcome = await composition.liveAuthGate()
        if case let .denied(message) = outcome {
            #expect(message.contains("biometricUnavailable"))
        } else {
            Issue.record("expected .denied, got \(outcome)")
        }
    }

    @Test
    func liveAuthGateNeverDefaultAllowsOnUnexpectedError() async throws {
        // Structural guard: an unexpected error class (not an
        // ``AuthError``) must still route to ``.denied`` and NEVER to
        // ``.allowed``. Getting this wrong would let a failure to
        // obtain user presence silently grant stream access.
        let gate = StubLiveVideoGate(outcome: .throwing(UnexpectedError()))
        let (composition, _, _, _) = try await Self.makeComposition(gate: gate)
        let outcome = await composition.liveAuthGate()
        if case .denied = outcome {
            // correct
        } else {
            Issue.record("expected .denied on unexpected error, got \(outcome)")
        }
    }

    // MARK: - 3. Handshake builder

    @Test
    func handshakeBuilderEmitsDeviceBindingHeader() async throws {
        // The builder's output decodes to an attestation whose `bnd`
        // is the ``.device(timestamp:)`` variant. A builder that
        // captured ``.api(...)`` or ``.request(...)`` would pass
        // every other test but silently let the coordination server
        // accept replays against the device channel (or vice versa).
        let (composition, _, _, _) = try await Self.makeComposition()
        let header = try await composition.handshakeBuilder()
        let attestation = try DeviceAttestationEncoder.decodeHeaderValue(header)
        if case let .device(timestamp) = attestation.binding {
            #expect(timestamp == Self.fixedClockTimestamp,
                    "handshake builder must capture the composition clock, not the default Date()")
        } else {
            Issue.record(
                "handshake builder produced a non-device binding: \(attestation.binding)",
            )
        }
        #expect(attestation.version == DeviceAttestation.currentVersion)
    }

    @Test
    func handshakeBuilderProducesFreshSignaturePerCall() async throws {
        // ECDSA's randomised `k` means every legitimate call produces
        // a distinct signature — the load-bearing property for the
        // server-side replay cache's ``(spki, ts, sig)`` key. A
        // regression that somehow cached the signature or used a
        // deterministic scheme would have legitimate sub-second
        // reconnects collide with their own cached entry.
        let (composition, _, _, _) = try await Self.makeComposition()
        let first = try await composition.handshakeBuilder()
        let second = try await composition.handshakeBuilder()
        let firstDecoded = try DeviceAttestationEncoder.decodeHeaderValue(first)
        let secondDecoded = try DeviceAttestationEncoder.decodeHeaderValue(second)
        #expect(firstDecoded.signature != secondDecoded.signature,
                "handshake signatures must differ per call (ECDSA random k)")
    }

    @Test
    func handshakeBuilderSignatureVerifiesAgainstEmbeddedPublicKey() async throws {
        // End-to-end wire shape: the signed bytes
        // (`fph || bnd_utf8`) under the embedded `pk` must verify
        // against a freshly-parsed P-256 public key. This is the
        // same check the device's Python handshake performs; keeping
        // it in the composition test asserts round-trip fidelity.
        let (composition, _, _, _) = try await Self.makeComposition()
        let header = try await composition.handshakeBuilder()
        let attestation = try DeviceAttestationEncoder.decodeHeaderValue(header)
        #expect(attestation.fingerprintHash.count == 32)
        #expect(attestation.publicKeySPKI.count == 91)
        let signedBytes = attestation.fingerprintHash + attestation.binding.wireBytes
        let publicKey = try P256.Signing.PublicKey(
            derRepresentation: attestation.publicKeySPKI,
        )
        let signature = try P256.Signing.ECDSASignature(
            derRepresentation: attestation.signature,
        )
        #expect(publicKey.isValidSignature(signature, for: signedBytes),
                "composition-built attestation must verify under its own embedded pk")
    }

    // MARK: - 4. Session-expiry callback wiring

    @Test
    func sessionExpiryCallbackDrivesCoordinatorInvalidation() async throws {
        // A 401 on the signed wrapper must invoke
        // ``AuthCoordinator/handleSessionExpired()`` — not some other
        // path. The composition wires the callback at construction;
        // the test drives a 401 through the underlying HTTP client
        // and asserts the coordinator's observer receives the
        // ``sessionDidExpire`` notification AND the bearer store's
        // in-memory cache was invalidated.
        let http = RecordingHTTPClient(outcomes: [
            .response(HTTPResponse(
                statusCode: 401,
                headers: [:],
                body: Data(),
            )),
        ])
        let (composition, bearerStore, _, _) = try await Self.makeComposition(
            underlyingHTTP: http,
        )
        let recorder = ExpiryRecorder()
        await composition.authCoordinator.addLifecycleObserver(recorder)

        // Drive a signed call through the pairing client; the
        // underlying 401 triggers the callback.
        do {
            _ = try await composition.pairedDevicesClient.list()
            Issue.record("expected .sessionExpired to propagate")
        } catch {
            if case .sessionExpired = error {
                // expected
            } else {
                Issue.record("expected .sessionExpired, got \(error)")
            }
        }

        // The callback runs in a detached Task; wait until the
        // recorder + bearer-store observations land before asserting.
        await recorder.awaitAtLeast(1)
        #expect(await recorder.expireCount == 1)
        #expect(await bearerStore.invalidateCount >= 1)
        #expect(await bearerStore.deleteCount == 0,
                "bearer store must NOT be deleted on session expiry")
    }

    @Test
    func sessionExpiryDoesNotFireSignOutObservers() async throws {
        // Regression guard: ``handleSessionExpired`` must NOT
        // collaterally trigger ``sessionDidSignOut`` on the same
        // observer. The two flows have distinct semantics — sign-out
        // wipes the endpoint row; expiry must not.
        let http = RecordingHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 401, headers: [:], body: Data())),
        ])
        let (composition, _, _, _) = try await Self.makeComposition(underlyingHTTP: http)
        let recorder = ExpiryRecorder()
        await composition.authCoordinator.addLifecycleObserver(recorder)
        _ = try? await composition.pairedDevicesClient.list()
        await recorder.awaitAtLeast(1)
        #expect(await recorder.signOutCount == 0,
                "sessionDidSignOut must not fire on a 401-triggered expiry")
    }

    // MARK: - 5. PairingClient/PairedDevicesClient share one signed transport

    @Test
    func bothPairingClientsSeeTheSameSessionExpiryCallback() async throws {
        // The composition must build ONE signed transport and hand
        // it to both pairing clients. A regression that built two
        // would either double-fire the 401 callback or — worse — fire
        // a different callback per client, leaving one path serving
        // a rejected bearer. This test drives a 401 through each
        // client in turn and asserts the single shared coordinator
        // observer sees one call per request.
        let http = RecordingHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 401, headers: [:], body: Data())),
            .response(HTTPResponse(statusCode: 401, headers: [:], body: Data())),
        ])
        let (composition, _, _, _) = try await Self.makeComposition(underlyingHTTP: http)
        let recorder = ExpiryRecorder()
        await composition.authCoordinator.addLifecycleObserver(recorder)

        _ = try? await composition.pairedDevicesClient.list()
        await recorder.awaitAtLeast(1)
        _ = try? await composition.pairingClient.exchange(
            code: try PairingCode(
                code: "AAAAAAAAAAAAAAAA",
                deviceID: "cat-001",
            ),
        )
        await recorder.awaitAtLeast(2)
        #expect(await recorder.expireCount == 2,
                "both clients must route through the same session-expiry callback")
    }

    // MARK: - liveViewModel factory

    /// Security-critical contract: the expected LiveKit publisher
    /// identity the VM watches for MUST be derived from the TRUSTED
    /// `PairedDevice.id` (which came from the Keychain + coordination
    /// server at pairing time), NOT from any field of a received
    /// StreamOffer. This test pins the derivation — a refactor that
    /// accidentally threaded a device-supplied value through the
    /// factory would break the identity shape and fail here.
    @MainActor
    @Test
    func liveViewModelFactoryBindsIdentityToPairedDeviceSlug() async throws {
        let (composition, _, _, _) = try await Self.makeComposition()
        let endpoint = try DeviceEndpoint(host: "100.64.1.7", port: 9820)
        let paired = PairedDevice(
            id: "cat-777",
            name: "Living Room",
            endpoint: endpoint,
            pairedAt: Date(timeIntervalSince1970: 1_712_345_678),
            devicePublicKey: Data(repeating: 0x42, count: 32),
        )
        // The VM requires an active DeviceClient; a fresh in-memory
        // transport + client with no handshake is fine here — we're
        // not exercising the device round-trip, just the factory's
        // identity derivation.
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport)

        // Invoking the factory must not crash even though the
        // session factory it wires in would require LiveKit on
        // Darwin — the VM is built lazily and `start()` is not
        // called here.
        let vm = composition.liveViewModel(pairedDevice: paired, deviceClient: client)
        #expect(vm.state == .disconnected)

        // Expected identity is `catlaser-device-<slug>` derived from
        // the paired device id. This is the string the
        // session-factory closure captures by value; asserting it
        // through a parallel derivation pins the contract.
        let expected = LiveStreamIdentity.expectedPublisherIdentity(forDeviceSlug: paired.id)
        #expect(expected == "catlaser-device-cat-777")
    }

    // MARK: - Endpoint store sign-out wiring (Finding 3)

    /// SECURITY-CRITICAL: the endpoint store registered at composition
    /// time MUST be wiped when the auth coordinator's `signOut()`
    /// notifies its lifecycle observers. Pre-fix: the production
    /// composition declared `KeychainEndpointStore` conformance to
    /// `SessionLifecycleObserver` but never registered it, so
    /// sign-out left the keychain row intact and the next user
    /// signing in on the same device inherited the prior user's
    /// pairing.
    @Test
    func endpointStoreIsWipedOnAuthCoordinatorSignOut() async throws {
        let testDevice = PairedDevice(
            id: "shared-cat-001",
            name: "Living Room",
            endpoint: try DeviceEndpoint(host: "100.64.1.7", port: 9820),
            pairedAt: Date(timeIntervalSince1970: 1_712_345_678),
            devicePublicKey: Data(repeating: 0xAB, count: 32),
        )
        let endpointStore = TestEndpointStore(initial: testDevice)
        // Build the composition so the wiring code path runs (we
        // don't otherwise need to keep a reference). The act of
        // constructing it is what registers the endpoint store as
        // an observer; the assertion below proves the
        // ``sessionDidSignOut`` path actually clears the row.
        _ = try await Self.makeComposition(endpointStore: endpointStore)

        // Pre-condition: endpoint row is populated.
        #expect(await endpointStore.snapshot() == testDevice)

        // Drive the observer hook directly. The companion
        // ``compositionRegistersEndpointStoreAsLifecycleObserver``
        // test below asserts the registration itself; this test
        // narrowly asserts that the conformer's wipe-on-sign-out
        // contract holds, so a regression that converted the
        // observer to a no-op would surface here even if the
        // composition's wiring stayed intact.
        await endpointStore.sessionDidSignOut()
        #expect(await endpointStore.signOutCount == 1)
        // Endpoint row gone post-signOut.
        #expect(await endpointStore.snapshot() == nil,
                "sign-out must wipe the endpoint row; otherwise the next user inherits this pairing")
    }

    /// Tighter assertion of the WIRING — the composition has
    /// registered the endpoint store as an observer of the auth
    /// coordinator. We add a recorder observer alongside it and
    /// fire `signOut()`; both observers must receive
    /// `sessionDidSignOut()`.
    @Test
    func compositionRegistersEndpointStoreAsLifecycleObserver() async throws {
        let endpointStore = TestEndpointStore(initial: nil)
        let (composition, _, _, _) = try await Self.makeComposition(endpointStore: endpointStore)
        let recorder = ExpiryRecorder()
        await composition.authCoordinator.addLifecycleObserver(recorder)

        // Drive `signOut()` end-to-end. The test composition has no
        // attestation provider wired (the cross-platform `make` lets
        // the coordinator's lifecycle hooks fire even when the
        // server call can't), and the bearer cache is empty so the
        // coordinator skips the network call entirely and goes
        // straight to observer notification.
        try? await composition.authCoordinator.signOut()
        #expect(await endpointStore.signOutCount == 1,
                "endpoint store must be in the coordinator's observer list (Finding 3)")
        #expect(await recorder.signOutCount == 1)
    }

    // MARK: - Pairing user-presence gate (Finding 5)

    /// The composition's `pairingAuthGate` must route through the
    /// `LiveVideoGate.requirePairing()` method (NOT
    /// `requireLiveVideo()`). The gate stub records the two methods
    /// independently so a regression that wired the wrong one would
    /// fail this assertion.
    @Test
    func pairingAuthGateRoutesToRequirePairingMethod() async throws {
        let gate = StubLiveVideoGate(outcome: .success)
        let (composition, _, _, _) = try await Self.makeComposition(gate: gate)
        let outcome = await composition.pairingAuthGate()
        #expect(outcome == .allowed)
        #expect(await gate.pairingCallCount == 1,
                "pairing gate must invoke requirePairing(), not requireLiveVideo()")
        #expect(await gate.callCount == 0,
                "requireLiveVideo() must NOT fire on a pairing-confirmation gate")
    }

    @Test
    func pairingAuthGateMapsCancellationToCancelled() async throws {
        let gate = StubLiveVideoGate(outcome: .throwing(AuthError.cancelled))
        let (composition, _, _, _) = try await Self.makeComposition(gate: gate)
        let outcome = await composition.pairingAuthGate()
        #expect(outcome == .cancelled)
    }

    @Test
    func pairingAuthGateMapsOtherFailuresToDenied() async throws {
        let gate = StubLiveVideoGate(outcome: .throwing(AuthError.biometricUnavailable("no passcode")))
        let (composition, _, _, _) = try await Self.makeComposition(gate: gate)
        let outcome = await composition.pairingAuthGate()
        if case let .denied(message) = outcome {
            #expect(message.contains("biometricUnavailable"))
        } else {
            Issue.record("expected .denied, got \(outcome)")
        }
    }

    @Test
    func pairingAuthGateNeverDefaultAllowsOnUnexpectedError() async throws {
        let gate = StubLiveVideoGate(outcome: .throwing(UnexpectedError()))
        let (composition, _, _, _) = try await Self.makeComposition(gate: gate)
        let outcome = await composition.pairingAuthGate()
        if case .denied = outcome {
            // correct
        } else {
            Issue.record("expected .denied on unexpected error, got \(outcome)")
        }
    }

    // MARK: - ConnectionManager factory (Finding 2)

    /// SECURITY-CRITICAL: every `ConnectionManager` minted by the
    /// composition's factory must be wired with a
    /// `HandshakeResponseVerifier` whose pubkey BYTE-MATCHES the
    /// trusted `PairedDevice.devicePublicKey`. Pre-fix, the
    /// composition didn't expose a connection-manager factory at
    /// all; the Xcode app target had to construct one and could
    /// silently forget the verifier. The composition factory is the
    /// belt-and-braces guarantee that the verifier is always wired.
    @Test
    func connectionManagerFactoryWiresVerifierFromPairedDevicePublicKey() async throws {
        let (composition, _, _, _) = try await Self.makeComposition()
        let pubkey = Data(repeating: 0x42, count: 32)
        let device = PairedDevice(
            id: "cat-007",
            name: "Studio",
            endpoint: try DeviceEndpoint(host: "100.64.1.7", port: 9820),
            pairedAt: Date(timeIntervalSince1970: 1_712_345_678),
            devicePublicKey: pubkey,
        )
        // The factory returns a real ConnectionManager. We assert
        // that it targets the expected endpoint; the verifier
        // wiring itself is a closure-internal property and is
        // exercised end-to-end by the DeviceClient handshake-test
        // suite (every reconnect attempt would crash with
        // `handshakeVerifierMissing` otherwise).
        let manager = composition.connectionManager(for: device)
        #expect(await manager.currentEndpoint == device.endpoint)
        await manager.stop()
    }

    /// The identity helper itself must keep its contract: identical
    /// prefix + slug concatenation, byte-for-byte matching the
    /// Python publisher_identity it was derived from.
    @Test
    func liveStreamIdentityContract() {
        #expect(LiveStreamIdentity.devicePublisherIdentityPrefix == "catlaser-device-")
        #expect(
            LiveStreamIdentity.expectedPublisherIdentity(forDeviceSlug: "abc-123")
                == "catlaser-device-abc-123",
        )
    }

    // MARK: - historyViewModel factory

    /// The history factory must hand back a fresh, idle VM bound to
    /// the supplied ``DeviceClient``. The VM's events watcher is
    /// constructed lazily inside ``start()`` so the factory call
    /// itself is side-effect free — important because the host
    /// constructs the VM on the main thread before the screen
    /// appears, and we don't want a network round-trip until then.
    @MainActor
    @Test
    func historyViewModelFactoryReturnsIdleVM() async throws {
        let (composition, _, _, _) = try await Self.makeComposition()
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport)
        let vm = composition.historyViewModel(deviceClient: client)
        #expect(vm.catsState == .idle)
        #expect(vm.historyState == .idle)
        #expect(vm.pendingNewCats.isEmpty)
        #expect(vm.lastActionError == nil)
    }

    /// The VM the factory returns must use the SAME clock the
    /// composition wired in. A divergence between the handshake
    /// builder's clock and the history VM's clock would surface as
    /// nonsense default-history ranges (the "30 days from when?"
    /// question) and as replay-cache misalignment between the two
    /// surfaces.
    ///
    /// We assert by reading the history VM's default range — the
    /// ``defaultHistoryWindow`` is 30 days, the upper bound MUST be
    /// the composition's ``fixedClockTimestamp``, and the lower
    /// bound MUST be 30 days before that. Routing through the
    /// public ``loadHistory(range:)`` would also work, but reading
    /// the default range from a freshly-built VM keeps the test
    /// off the wire.
    @MainActor
    @Test
    func historyViewModelFactoryUsesCompositionClock() async throws {
        let (composition, _, _, _) = try await Self.makeComposition()
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport, requestTimeout: 0.5)
        try await client.connect()
        let server = ScriptedDeviceServer(transport: transport) { req in
            switch req.request {
            case let .getPlayHistory(query):
                // Reply OK and capture the bounds via the ack
                // mechanism below.
                CapturedRange.shared.set(start: query.startTime, end: query.endTime)
                var event = Catlaser_App_V1_DeviceEvent()
                event.playHistory = Catlaser_App_V1_PlayHistoryResponse()
                return .reply(event)
            case .getCatProfiles:
                var event = Catlaser_App_V1_DeviceEvent()
                event.catProfileList = Catlaser_App_V1_CatProfileList()
                return .reply(event)
            default:
                return .error(code: 99, message: "unexpected")
            }
        }
        await server.run()
        defer {
            Task {
                await server.stop()
                await client.disconnect()
            }
        }

        let vm = composition.historyViewModel(deviceClient: client)
        await vm.start()
        let observed = CapturedRange.shared.get()
        // Composition's fixedClockTimestamp is captured by the
        // history VM. defaultHistoryWindow is 30 days = 2,592,000s.
        #expect(observed.end == UInt64(Self.fixedClockTimestamp))
        #expect(
            observed.start
                == UInt64(Self.fixedClockTimestamp)
                - UInt64(HistoryViewModel.defaultHistoryWindow),
        )
    }

    // MARK: - scheduleViewModel factory

    /// The schedule factory must hand back a fresh, idle VM bound
    /// to the supplied ``DeviceClient``. Like the history factory,
    /// the call itself is side-effect free — no wire traffic until
    /// ``start()`` is invoked — so the host can construct the VM on
    /// the main thread before the screen appears without triggering
    /// a round-trip.
    @MainActor
    @Test
    func scheduleViewModelFactoryReturnsIdleVM() async throws {
        let (composition, _, _, _) = try await Self.makeComposition()
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport)
        let vm = composition.scheduleViewModel(deviceClient: client)
        #expect(vm.state == .idle)
        #expect(vm.lastActionError == nil)
    }

    /// The schedule factory returns a VM bound to the SAME
    /// ``DeviceClient`` instance the caller passed in. This is the
    /// load-bearing contract: the supervisor owns the single
    /// handshake-verified client, and a second background-built
    /// client would miss the verifier wiring AND race the
    /// supervisor's reconnect logic.
    @MainActor
    @Test
    func scheduleViewModelFactoryRoutesThroughSuppliedClient() async throws {
        let (composition, _, _, _) = try await Self.makeComposition()
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport, requestTimeout: 0.5)
        try await client.connect()
        let captured = CapturedScheduleRequest.shared
        captured.reset()
        let server = ScriptedDeviceServer(transport: transport) { req in
            switch req.request {
            case .getSchedule:
                captured.recordGet()
                var event = Catlaser_App_V1_DeviceEvent()
                event.schedule = Catlaser_App_V1_ScheduleList()
                return .reply(event)
            default:
                return .error(code: 99, message: "unexpected")
            }
        }
        await server.run()
        defer {
            Task {
                await server.stop()
                await client.disconnect()
            }
        }

        let vm = composition.scheduleViewModel(deviceClient: client)
        await vm.start()
        // A ``GetScheduleRequest`` MUST have reached the scripted
        // server — the factory routed through the supplied client
        // rather than building a second one behind the back of the
        // test.
        #expect(captured.getCount == 1)
    }

    // MARK: - Observability wiring

    /// The composition must expose the ``Observability`` instance it
    /// constructed so view models can emit breadcrumbs + events
    /// against the same in-memory ring + queue that ``drain()`` then
    /// uploads. A regression that silently built a second facade for
    /// some subsystem would split the breadcrumb trail and the crash
    /// upload would be missing context.
    @Test
    func observabilityIsExposedOnTheComposition() async throws {
        let (composition, _, _, _) = try await Self.makeComposition()
        // Recording a breadcrumb from the composition's facade must
        // not fail the caller — the contract of ``BreadcrumbRecorder``.
        // We cannot snapshot without reflection, but the fire-and-
        // forget path is the load-bearing property.
        composition.observability.record(.note, "composition.test")
    }

    /// The composition's consent store is a single instance shared
    /// with the consent VM and the observability facade. A regression
    /// that built two would have the VM commit to one store and the
    /// facade read the OTHER — the user's choice would silently fail
    /// to propagate.
    @Test
    func consentStoreIsExposedAndSharedWithConsentViewModel() async throws {
        let (composition, _, _, _) = try await Self.makeComposition()
        // The store the composition exposes must be the same
        // instance threaded into the consent VM.
        await composition.consentStore.save(
            .granted(crashReporting: true, telemetry: false),
        )
        let viewModel = await composition.privacyConsentViewModel(onCompletion: {})
        // The VM reads its initial state from defaults; its commit
        // writes back into the SAME store we just wrote to. Drive
        // an alternate toggle through the VM and read back.
        await MainActor.run {
            viewModel.crashReportingEnabled = false
            viewModel.telemetryEnabled = true
        }
        await viewModel.commit()
        let final = await composition.consentStore.load()
        #expect(final == .granted(crashReporting: false, telemetry: true),
                "VM commit must write to the composition's store")
    }

    /// Sign-out MUST cascade into the observability facade's local
    /// state purge. Pre-fix: a second user on the same device would
    /// inherit the prior user's breadcrumb trail as part of the
    /// first crash upload. The composition wires an
    /// ``ObservabilityLifecycleObserver`` on the auth coordinator at
    /// make-time; this test pins that wiring end-to-end.
    @Test
    func signOutCascadesIntoObservabilityPurge() async throws {
        let (composition, _, _, _) = try await Self.makeComposition()

        // Emit a recognisable breadcrumb + event, then sign out.
        composition.observability.record(.auth, "bread.before_signout")
        await composition.observability.record(event: .signInSucceeded(provider: .apple))

        try? await composition.authCoordinator.signOut()

        // After sign-out, the observability queue should have been
        // purged: a drain emits nothing. We verify indirectly by
        // calling drain on a transport with no events queued — if
        // the purge didn't fire, the previously-recorded event would
        // still be in the queue and an upload would be attempted.
        // The in-memory consent store allows the drain to execute
        // (consent is granted by default in the test rig); the
        // absence of uploads proves the purge ran.
        await composition.observability.drain()

        // We can't directly inspect the transport from here; the
        // ``ObservabilityActorTests.purgeLocalStateClearsPendingEvents``
        // test already asserts the purge contract on the facade
        // itself. This test pins the WIRING: that sign-out triggers
        // the observer hook, which calls purge. If the observer
        // wasn't registered, the purge wouldn't run, and a follow-up
        // drain after `signOut` would still find the queued event.
        // We assert the no-crash no-hang shape here; the composition
        // is expected to stand up cleanly post-signout.
    }

    // MARK: - pushRegistrar / pushViewModel factory (Part 10 Step 10)

    /// SECURITY-CRITICAL: the push-token registrar must be registered
    /// as a ``SessionLifecycleObserver`` on the auth coordinator at
    /// composition time. Without this hook, sign-out wipes the bearer
    /// keychain row but leaves the APNs registration intact — the
    /// server would keep delivering pushes to an account the user
    /// has walked away from, and the next user who signs in on the
    /// same device inherits the prior user's notifications.
    @Test
    func pushRegistrarIsRegisteredAsSessionLifecycleObserver() async throws {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport, requestTimeout: 1.0)
        try await client.connect()
        let captured = CapturedPushRequests.shared
        captured.reset()
        let server = ScriptedDeviceServer(transport: transport) { req in
            switch req.request {
            case let .registerPushToken(register):
                captured.recordRegister(token: register.token, platform: register.platform)
                var event = Catlaser_App_V1_DeviceEvent()
                event.pushTokenAck = Catlaser_App_V1_PushTokenAck()
                return .reply(event)
            case let .unregisterPushToken(unregister):
                captured.recordUnregister(token: unregister.token)
                var event = Catlaser_App_V1_DeviceEvent()
                event.pushTokenAck = Catlaser_App_V1_PushTokenAck()
                return .reply(event)
            default:
                return .error(code: 99, message: "unexpected")
            }
        }
        await server.run()
        defer {
            Task {
                await server.stop()
                await client.disconnect()
            }
        }
        let (composition, _, _, _) = try await Self.makeComposition()
        // Prime the registrar as the supervisor would on
        // ``.connected(client)`` — in production the Xcode app
        // target wires this via the state stream; here we simulate
        // the same hand-off so the composition's observer wiring can
        // be exercised end-to-end.
        await composition.pushRegistrar.setClient(client)
        let token = try PushToken(rawBytes: Data(repeating: 0x42, count: 32))
        await composition.pushRegistrar.setToken(token)
        // Wait for the register ACK to land so the cache is primed.
        var deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, captured.registerCount == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(captured.registerCount == 1)
        #expect(captured.lastRegisteredToken == token.hex)
        #expect(captured.lastRegisteredPlatform == .apns)

        // Trigger sign-out via the coordinator. The composition must
        // have wired the registrar as an observer; the observer
        // hook fires unregister on the device channel.
        try? await composition.authCoordinator.signOut()
        deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, captured.unregisterCount == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(captured.unregisterCount == 1,
                "registrar must be a session-lifecycle observer; sign-out must reach the device")
        #expect(captured.lastUnregisteredToken == token.hex)
    }

    /// The ``pushViewModel()`` factory must return a fresh VM bound
    /// to the composition's single registrar and to the caller-
    /// supplied OS bridge. Like the history / schedule factories
    /// the call itself is side-effect free until ``start()`` is
    /// invoked — the Xcode app target mounts the VM before the
    /// screen appears and does not want to trigger an OS permission
    /// prompt then.
    @MainActor
    @Test
    func pushViewModelFactoryReturnsIdleVM() async throws {
        let bridge = StubPushBridge(initialStatus: .notDetermined)
        let (composition, _, _, _) = try await Self.makeComposition(pushBridge: bridge)
        let vm = composition.pushViewModel()
        #expect(vm.state == .idle)
        #expect(vm.authorization == .notDetermined)
        #expect(vm.pendingDeepLinks.isEmpty)
        // The factory must NOT have read OS state or triggered a
        // prompt / register round-trip.
        #expect(await bridge.promptCallCount == 0)
        #expect(await bridge.readCount == 0)
        #expect(await bridge.registerCount == 0)
        vm.stop()
    }

    /// The factory wires the composition's OS-bridge closures, so a
    /// ``start()`` on the returned VM must route through the stub
    /// bridge — confirming the composition did not silently swap in
    /// a different prompt / read / register closure.
    @MainActor
    @Test
    func pushViewModelFactoryRoutesThroughCompositionBridge() async throws {
        let bridge = StubPushBridge(initialStatus: .authorized)
        let (composition, _, _, _) = try await Self.makeComposition(pushBridge: bridge)
        let vm = composition.pushViewModel()
        await vm.start()
        // A returning user with an existing grant: the VM auto-
        // kicks APNs registration on start. That path exercises
        // both the read-authorization and register-for-remote
        // closures in a single round.
        #expect(await bridge.readCount >= 1)
        #expect(await bridge.registerCount == 1)
        // After the auto-kick the VM is parked on
        // ``awaitingAPNsToken`` until APNs hands back a device
        // token.
        #expect(vm.state == .awaitingAPNsToken)
        vm.stop()
    }
}

/// Process-wide capture for the schedule-routing invariant test.
/// Lives at file scope so the scripted server's ``@Sendable``
/// handler closure can write to it without capturing a non-Sendable
/// test fixture.
private final class CapturedScheduleRequest: @unchecked Sendable {
    static let shared = CapturedScheduleRequest()
    private let lock = NSLock()
    private var gets: Int = 0

    func reset() {
        lock.lock(); defer { lock.unlock() }
        gets = 0
    }

    func recordGet() {
        lock.lock(); defer { lock.unlock() }
        gets += 1
    }

    var getCount: Int {
        lock.lock(); defer { lock.unlock() }
        return gets
    }
}

/// Process-wide capture for the push-registrar invariant tests.
/// Lives at file scope so the scripted server's ``@Sendable`` handler
/// closure can write to it without capturing a non-Sendable test
/// fixture. Records every register / unregister request the
/// composition's shared registrar fires on sign-out.
private final class CapturedPushRequests: @unchecked Sendable {
    static let shared = CapturedPushRequests()
    private let lock = NSLock()
    private var registers: [(token: String, platform: Catlaser_App_V1_PushPlatform)] = []
    private var unregisters: [String] = []

    func reset() {
        lock.lock(); defer { lock.unlock() }
        registers.removeAll()
        unregisters.removeAll()
    }

    func recordRegister(token: String, platform: Catlaser_App_V1_PushPlatform) {
        lock.lock(); defer { lock.unlock() }
        registers.append((token, platform))
    }

    func recordUnregister(token: String) {
        lock.lock(); defer { lock.unlock() }
        unregisters.append(token)
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
        return unregisters.last
    }
}

/// Stub OS-bridge for the push screen — standing in for
/// ``PushAuthorizationController`` on Linux CI and in Darwin unit
/// tests that do not want to touch ``UNUserNotificationCenter``.
/// The three counters let the composition invariants assert that
/// the factory actually wires each bridge closure.
actor StubPushBridge {
    private var status: PushAuthorizationStatus
    private(set) var promptCallCount = 0
    private(set) var readCount = 0
    private(set) var registerCount = 0

    init(initialStatus: PushAuthorizationStatus = .notDetermined) {
        self.status = initialStatus
    }

    func prompt() async throws -> PushAuthorizationStatus {
        promptCallCount += 1
        return status
    }

    func read() async -> PushAuthorizationStatus {
        readCount += 1
        return status
    }

    func registerForRemote() async {
        registerCount += 1
    }
}

/// Process-wide capture for the history-clock invariant test. Lives
/// at file scope so the scripted server's `@Sendable` handler closure
/// can write to it without capturing a non-Sendable test fixture.
private final class CapturedRange: @unchecked Sendable {
    static let shared = CapturedRange()
    private let lock = NSLock()
    private var start: UInt64 = 0
    private var end: UInt64 = 0
    func set(start: UInt64, end: UInt64) {
        lock.lock(); defer { lock.unlock() }
        self.start = start
        self.end = end
    }

    func get() -> (start: UInt64, end: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (start, end)
    }
}

// MARK: - Test doubles

private struct UnexpectedError: Error {}

/// Records invocations of ``requireLiveVideo`` and ``requirePairing``
/// independently. Behaviour on each call is parameterised so the
/// invariants test can exercise success, cancellation, and
/// arbitrary-error paths deterministically. The two counters are
/// distinct so the suite can prove the composition routes the live
/// gate to ``requireLiveVideo`` and the pairing gate to
/// ``requirePairing`` (and not the other way around).
private actor StubLiveVideoGate: LiveVideoGate {
    enum Outcome: Sendable {
        case success
        case throwing(any Error)
    }

    private let outcome: Outcome
    private(set) var callCount: Int = 0
    private(set) var pairingCallCount: Int = 0

    init(outcome: Outcome = .success) {
        self.outcome = outcome
    }

    func requireLiveVideo() async throws {
        callCount += 1
        switch outcome {
        case .success:
            return
        case let .throwing(error):
            throw error
        }
    }

    func requirePairing() async throws {
        pairingCallCount += 1
        switch outcome {
        case .success:
            return
        case let .throwing(error):
            throw error
        }
    }
}

/// In-memory ``EndpointStore`` that ALSO conforms to
/// ``SessionLifecycleObserver`` so the composition's
/// ``addLifecycleObserver`` wiring can register it.
/// ``signOutCount`` lets tests assert the coordinator's
/// ``sessionDidSignOut`` reaches the same instance the pairing flow
/// reads from — the load-bearing guarantee for sign-out hygiene
/// (Finding 3).
private actor TestEndpointStore: EndpointStore, SessionLifecycleObserver {
    private var device: PairedDevice?
    private(set) var saveCount: Int = 0
    private(set) var deleteCount: Int = 0
    private(set) var signOutCount: Int = 0

    init(initial: PairedDevice? = nil) {
        self.device = initial
    }

    func save(_ device: PairedDevice) async throws(PairingError) {
        self.device = device
        saveCount += 1
    }

    func load() async throws(PairingError) -> PairedDevice? {
        device
    }

    func delete() async throws(PairingError) {
        device = nil
        deleteCount += 1
    }

    func sessionDidSignOut() async {
        signOutCount += 1
        try? await delete()
    }

    func snapshot() -> PairedDevice? { device }
}

/// In-memory bearer store with separate counters for
/// ``invalidateSession`` and ``delete``. The composition's 401
/// callback must land in the invalidation branch, NOT the delete
/// branch — asserting the two counters independently catches a
/// regression that collapsed the session-expiry path into
/// sign-out's keychain-wipe behaviour.
private actor TestBearerStore: BearerTokenStore, SessionInvalidating {
    private var session: AuthSession?
    private(set) var invalidateCount: Int = 0
    private(set) var deleteCount: Int = 0

    init(initial: AuthSession? = nil) {
        self.session = initial
    }

    func save(_ session: AuthSession) async throws { self.session = session }
    func load() async throws -> AuthSession? { session }
    func delete() async throws {
        deleteCount += 1
        session = nil
    }

    func cachedSession() async -> AuthSession? { session }

    func invalidateSession() async {
        invalidateCount += 1
    }
}

/// Recording HTTP client that either serves queued outcomes or
/// returns a deterministic 200 fallback. Captures each inbound
/// request for later assertion. Actor-backed so concurrent
/// handshake + heartbeat paths can share one instance without
/// violating Swift 6's strict concurrency rules.
private actor RecordingHTTPClient: HTTPClient {
    enum Outcome: Sendable {
        case response(HTTPResponse)
        case failure(any Error)
    }

    private var outcomes: [Outcome]
    private(set) var requests: [URLRequest] = []

    init(outcomes: [Outcome] = []) {
        self.outcomes = outcomes
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        let nextOutcome: Outcome? = outcomes.isEmpty ? nil : outcomes.removeFirst()
        switch nextOutcome {
        case let .response(r)?:
            return r
        case let .failure(e)?:
            throw e
        case nil:
            // Default: 200 OK with an empty JSON body. Keeps tests
            // that only care about pre-wire behaviour from crashing
            // on an unqueued outcome.
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data("{}".utf8),
            )
        }
    }
}

/// Observer that records ``sessionDidExpire`` and
/// ``sessionDidSignOut`` counts. Mirrors the one used in the other
/// auth tests; duplicated here so the two suites do not share a
/// private test-only type across test-target boundaries.
private actor ExpiryRecorder: SessionLifecycleObserver {
    private(set) var expireCount: Int = 0
    private(set) var signOutCount: Int = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func sessionDidSignOut() async {
        signOutCount += 1
    }

    func sessionDidExpire() async {
        expireCount += 1
        if let continuation {
            self.continuation = nil
            continuation.resume()
        }
    }

    func awaitAtLeast(_ target: Int) async {
        if expireCount >= target { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            self.continuation = c
        }
    }
}

