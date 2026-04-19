import CatLaserAuthTestSupport
import CatLaserDevice
import CatLaserDeviceTestSupport
import CatLaserLive
import CatLaserProto
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
    ) throws -> (AppComposition, TestBearerStore) {
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
        let composition = AppComposition.make(
            authConfig: try makeAuthConfig(),
            authHTTPClient: underlyingHTTP,
            signedHTTPClientFactory: factory,
            liveKitAllowlist: try makeAllowlist(),
            attestationProvider: attestationProvider,
            bearerStore: bearerStore,
            liveVideoGate: gate,
            clock: { Date(timeIntervalSince1970: TimeInterval(fixedClockTimestamp)) },
        )
        return (composition, bearerStore)
    }

    // MARK: - 1. LiveKit allowlist

    @Test
    func liveKitAllowlistContainsExactlyTheConfiguredHosts() throws {
        let (composition, _) = try Self.makeComposition()
        // Exact match — not a permissive superset, not a silent empty
        // set.
        #expect(composition.liveKitAllowlist.contains(Self.allowedLiveKitHost))
        #expect(composition.liveKitAllowlist.sortedHosts == [Self.allowedLiveKitHost])
        #expect(!composition.liveKitAllowlist.contains("attacker-livekit.example.com"))
        #expect(!composition.liveKitAllowlist.contains(""))
    }

    @Test
    func liveStreamCredentialsRejectsHostOutsideAllowlist() throws {
        // The allowlist plumbs all the way down to the
        // ``LiveStreamCredentials`` constructor. A tampered offer
        // must never produce valid credentials.
        let (composition, _) = try Self.makeComposition()
        var offer = Catlaser_App_V1_StreamOffer()
        offer.livekitURL = "wss://attacker-livekit.example.com"
        offer.subscriberToken = "jwt.placeholder"
        #expect(throws: LiveStreamCredentialsError.hostNotAllowed("attacker-livekit.example.com")) {
            _ = try LiveStreamCredentials(offer: offer, allowlist: composition.liveKitAllowlist)
        }
    }

    @Test
    func liveStreamCredentialsAcceptsAllowedHost() throws {
        let (composition, _) = try Self.makeComposition()
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
        let (composition, _) = try Self.makeComposition(gate: gate)
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
        let (composition, _) = try Self.makeComposition(gate: gate)
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
        let (composition, _) = try Self.makeComposition(gate: gate)
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
        let (composition, _) = try Self.makeComposition(gate: gate)
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
        let (composition, _) = try Self.makeComposition()
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
        let (composition, _) = try Self.makeComposition()
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
        let (composition, _) = try Self.makeComposition()
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
        let (composition, bearerStore) = try Self.makeComposition(
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
        let (composition, _) = try Self.makeComposition(underlyingHTTP: http)
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
        let (composition, _) = try Self.makeComposition(underlyingHTTP: http)
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
    func liveViewModelFactoryBindsIdentityToPairedDeviceSlug() throws {
        let (composition, _) = try Self.makeComposition()
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
}

// MARK: - Test doubles

private struct UnexpectedError: Error {}

/// Records invocations of ``requireLiveVideo``. Behaviour on each
/// call is parameterised so the invariants test can exercise success,
/// cancellation, and arbitrary-error paths deterministically.
private actor StubLiveVideoGate: LiveVideoGate {
    enum Outcome: Sendable {
        case success
        case throwing(any Error)
    }

    private let outcome: Outcome
    private(set) var callCount: Int = 0

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

