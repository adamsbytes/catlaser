import CatLaserAuth
import CatLaserDevice
import CatLaserHistory
import CatLaserLive
import CatLaserPairing
import Foundation

/// Single production wiring for the app's object graph.
///
/// Every cross-module seam that is security-relevant at runtime — TLS
/// pinning, LiveKit host allowlisting, bearer-token biometric gating,
/// `dev:` handshake attestation, 401-triggered session invalidation —
/// is assembled here. The product target (the Xcode app bundle)
/// constructs an ``AppComposition`` once at launch via
/// ``AppComposition/production(config:)`` and then hands out the
/// prebuilt components to SwiftUI views.
///
/// ## Platform posture
///
/// The type itself builds on every platform so the
/// ``AppCompositionInvariantsTests`` suite runs on Linux CI (where
/// ``SecureEnclaveIdentityStore``, ``KeychainBearerTokenStore``,
/// ``GatedBearerTokenStore``, and ``PinnedHTTPClient`` are all
/// unavailable). Production construction lives in a Darwin-only
/// extension (``production(config:)``) so a shipping iOS / macOS
/// build always threads the pinned + SE-backed dependencies. The
/// cross-platform ``make`` factory is package-internal — the product
/// target reaches it only via ``production(config:)``.
///
/// ## What is asserted
///
/// The accompanying ``AppCompositionInvariantsTests`` suite locks in
/// four structural guarantees that the type system cannot express on
/// its own:
///
/// 1. The LiveKit allowlist exactly matches the operator-provisioned
///    host set — a silent over-permissive allowlist would defeat the
///    defence against a tampered ``StreamOffer``.
/// 2. The live-view ``AuthGate`` routes through a ``LiveVideoGate``
///    conformer that actually performs a user-presence check
///    (production binds ``GatedBearerTokenStore/requireLiveVideo``).
///    Skipping this would let a momentarily-unlocked phone reveal the
///    in-home feed.
/// 3. The ``ConnectionManager/HandshakeBuilder`` produces a header
///    whose ``bnd`` decodes to ``AttestationBinding/device(timestamp:)``
///    — any other binding tag would be rejected by the device daemon,
///    and using ``api:`` by mistake would still succeed against the
///    coordination server, inviting cross-context replay.
/// 4. The Darwin ``production`` factory constructs the
///    ``SignedHTTPClient`` from a ``PinnedHTTPClient``. The type
///    system already enforces this on the public initialiser; the
///    invariant test locks in the concrete construction path in
///    case a refactor reached for the package-internal
///    ``init(underlying:...)``.
public struct AppComposition: Sendable {
    // MARK: - Deployment input

    /// Inputs a release product target must supply. Construction
    /// fails closed: every field is validated before use.
    public struct DeploymentConfig: Sendable {
        /// Auth endpoint configuration — base URL, OAuth client IDs,
        /// Universal-Link host/path.
        public let authConfig: AuthConfig

        /// SPKI-SHA256 pin set for the coordination server. Must
        /// contain at least one pin; empty is rejected at
        /// ``TLSPinning/init``.
        public let tlsPinning: TLSPinning

        /// LiveKit hosts the app may dial. Must be non-empty; exactly
        /// the hosts the operator provisioned LiveKit on, with no
        /// wildcards. Mirrors the server's per-device-room isolation
        /// by constraining the subscriber-side dial target.
        public let liveKitAllowlist: LiveKitHostAllowlist

        /// Keychain access group shared with extensions, if any.
        /// ``nil`` keeps the store in the app-private access group
        /// (the release default).
        public let keychainAccessGroup: String?

        public init(
            authConfig: AuthConfig,
            tlsPinning: TLSPinning,
            liveKitAllowlist: LiveKitHostAllowlist,
            keychainAccessGroup: String? = nil,
        ) {
            self.authConfig = authConfig
            self.tlsPinning = tlsPinning
            self.liveKitAllowlist = liveKitAllowlist
            self.keychainAccessGroup = keychainAccessGroup
        }
    }

    // MARK: - Assembled graph

    /// Auth coordinator — sign-in flows, session management, 401
    /// handling via ``AuthCoordinator/handleSessionExpired()``.
    public let authCoordinator: AuthCoordinator

    /// Pairing-code exchange client. Always built on top of the
    /// pinned + signed transport in production; no code path in this
    /// module can construct one on an unpinned session.
    public let pairingClient: PairingClient

    /// Ownership re-verification client — ``/api/v1/devices/paired``.
    /// Same pinning + signing posture as ``pairingClient``.
    public let pairedDevicesClient: PairedDevicesClient

    /// LiveKit host allowlist. Re-exposed verbatim so
    /// ``LiveViewModel`` construction does not touch
    /// ``DeploymentConfig`` directly.
    public let liveKitAllowlist: LiveKitHostAllowlist

    /// Device-handshake builder. Emits a v4 attestation header with
    /// ``bnd = "dev:<unix_seconds>"``. The ``ConnectionManager``
    /// threads this into ``DeviceClient/connect(handshake:)`` on
    /// every reconnect.
    public let handshakeBuilder: ConnectionManager.HandshakeBuilder

    /// Live-view user-presence gate. Always prompts the user (Face
    /// ID / passcode) before any stream machinery touches the wire —
    /// even inside the bearer cache's idle window. Returns
    /// ``LiveAuthGateOutcome/allowed``, ``/cancelled``, or
    /// ``/denied(_:)`` for the ``LiveViewModel`` to route on.
    public let liveAuthGate: LiveViewModel.AuthGate

    /// Pairing-confirmation user-presence gate. Always prompts the
    /// user before the ``PairingClient/exchange`` HTTP call adds a
    /// device to the user's account, even if the bearer cache's idle
    /// window is still fresh. The exposure is the same shape as
    /// ``liveAuthGate``: the ``PairingViewModel`` invokes the closure
    /// at the start of ``confirmPairing`` and routes on the typed
    /// outcome. Without this gate a momentarily-unlocked phone could
    /// be coerced into silently pairing an attacker-controlled device
    /// — the bearer comes from the in-memory cache, the
    /// Secure-Enclave attestation signs, and the coordination server
    /// records the new pairing with no biometric prompt.
    public let pairingAuthGate: PairingAuthGate

    /// Single shared `EndpointStore` instance used by both the
    /// ``PairingViewModel`` and the auth coordinator's lifecycle
    /// observation. Wiring one instance through both paths is
    /// load-bearing for sign-out hygiene: the coordinator's
    /// ``sessionDidSignOut`` notification must reach the SAME store
    /// the pairing flow reads / writes, otherwise the keychain row
    /// survives sign-out and is inherited by the next user on the
    /// device. Documented as ``EndpointStore & SessionLifecycleObserver``
    /// so production conformers (``KeychainEndpointStore``) and test
    /// doubles both fit, and so the type system refuses a wiring
    /// that omits the lifecycle hook.
    public let endpointStore: any EndpointStore & SessionLifecycleObserver

    /// Construct a ``LiveViewModel`` wired to the paired device. The
    /// slug is read from the trusted ``PairedDevice`` (Keychain) and
    /// captured in the session factory closure — it is NEVER derived
    /// from a received ``StreamOffer`` or any other field an
    /// impostor server could influence.
    ///
    /// This is the single authorised construction site for a
    /// ``LiveViewModel`` on a paired connection. A hypothetical
    /// alternative path that derived the slug from the offer would
    /// collapse the publisher-identity check to self-trust: the
    /// attacker who sent the offer chooses the identity the app
    /// expects to see. Routing everything through this factory
    /// keeps the boundary narrow and testable.
    ///
    /// The factory is `@MainActor` because ``LiveViewModel`` itself
    /// is MainActor-isolated — constructing it off the main thread
    /// would require a hop anyway, so we surface that constraint at
    /// the factory boundary.
    @MainActor
    public func liveViewModel(
        pairedDevice: PairedDevice,
        deviceClient: DeviceClient,
    ) -> LiveViewModel {
        let expectedIdentity = LiveStreamIdentity.expectedPublisherIdentity(
            forDeviceSlug: pairedDevice.id,
        )
        // `expectedIdentity` is captured by value in the closure so
        // a later mutation of `pairedDevice` (by this or any other
        // reference) cannot retroactively change what the VM
        // trusts.
        let sessionFactory: @Sendable () -> any LiveStreamSession = {
            Self.makeLiveStreamSession(expectedPublisherIdentity: expectedIdentity)
        }
        return LiveViewModel(
            deviceClient: deviceClient,
            authGate: liveAuthGate,
            liveKitAllowlist: liveKitAllowlist,
            sessionFactory: sessionFactory,
        )
    }

    /// Construct a ``HistoryViewModel`` wired to the supplied
    /// ``DeviceClient``. The same client instance threaded through
    /// ``liveViewModel(pairedDevice:deviceClient:)`` MUST be passed
    /// here so both screens share the single-consumer event stream
    /// surface. A second client built behind the back of the
    /// composition would race the supervisor's reconnect logic and
    /// silently drop unsolicited ``NewCatDetected`` pushes against
    /// whichever VM lost the race.
    ///
    /// ``@MainActor`` because ``HistoryViewModel`` is MainActor-
    /// isolated: constructing it off the main thread would require a
    /// hop anyway, so we surface the constraint at the factory
    /// boundary.
    @MainActor
    public func historyViewModel(deviceClient: DeviceClient) -> HistoryViewModel {
        HistoryViewModel(deviceClient: deviceClient, clock: clock)
    }

    /// Concrete session factory used by ``liveViewModel``. Lives in
    /// its own helper so the `#if canImport(LiveKit)` branch stays
    /// tight: when LiveKit is linked (production + Xcode target),
    /// the real session is built; when it isn't (SPM Linux CI),
    /// the call fatal-errors because there is no on-device video
    /// to subscribe to anyway, and the composition invariants tests
    /// cover this path with mock sessions constructed by the test
    /// target, not by this factory.
    private static func makeLiveStreamSession(
        expectedPublisherIdentity: String,
    ) -> any LiveStreamSession {
        #if canImport(LiveKit)
        return LiveKitStreamSession(expectedPublisherIdentity: expectedPublisherIdentity)
        #else
        preconditionFailure(
            "AppComposition.liveViewModel requires LiveKit; target must link client-sdk-swift",
        )
        #endif
    }

    // MARK: - Cross-platform construction

    /// Closure that builds a ``SignedHTTPClient`` given the
    /// ``onSessionExpired`` callback the composition needs to thread
    /// in. Indirected as a factory so the composition can inject its
    /// own 401 callback (which closes over the ``AuthCoordinator`` it
    /// just built) without forcing the caller to construct the
    /// coordinator first.
    ///
    /// The production factory on Darwin passes the pinned transport
    /// to ``SignedHTTPClient``'s ``init(transport:...)`` public
    /// initializer, which enforces the ``PinnedHTTPClient`` type
    /// invariant at compile time. The invariants test suite passes a
    /// factory that uses ``@testable import CatLaserAuth`` to reach
    /// the package-internal ``init(underlying:...)`` with a mock HTTP
    /// client — that seam is invisible to the shipping product target
    /// (no ``@testable`` imports in release code), so a refactor
    /// cannot accidentally smuggle an unpinned transport into
    /// production.
    public typealias SignedHTTPClientFactory = @Sendable (
        @escaping SignedHTTPClient.SessionExpiryHandler,
    ) -> SignedHTTPClient

    /// Wire the production object graph from injectable dependencies.
    ///
    /// Called on Darwin by the thin ``production(config:)`` factory
    /// with real SE-backed / keychain-backed / pinned-URLSession
    /// dependencies; called on all platforms by the
    /// ``AppCompositionInvariantsTests`` suite with test doubles so
    /// the wiring invariants are asserted on a real composition, not
    /// a bespoke per-test rig.
    /// Builder for the per-attempt device transport.
    ///
    /// The composition owns ``DeviceClient`` construction directly so
    /// the ``HandshakeResponseVerifier`` cannot be omitted at the
    /// production callsite (Finding 2: DeviceClient's verifier slot
    /// is optional, and the composition is the place to make sure it
    /// always carries the right key). Callers supply the transport
    /// factory; the composition wires the verifier from the trusted
    /// ``PairedDevice/devicePublicKey`` and constructs the client
    /// itself.
    ///
    /// On Darwin production: returns a ``NetworkDeviceTransport``
    /// pinned to the Tailscale ``utunN`` interface. On Linux SPM
    /// tests: returns an ``InMemoryDeviceTransport`` so the
    /// composition-invariants suite can exercise the wiring without
    /// a live socket.
    public typealias DeviceTransportFactory = @Sendable (DeviceEndpoint) throws -> any DeviceTransport

    public static func make(
        authConfig: AuthConfig,
        authHTTPClient: any HTTPClient,
        signedHTTPClientFactory: SignedHTTPClientFactory,
        liveKitAllowlist: LiveKitHostAllowlist,
        attestationProvider: any DeviceAttestationProviding,
        bearerStore: any BearerTokenStore & SessionInvalidating,
        liveVideoGate: any LiveVideoGate,
        endpointStore: any EndpointStore & SessionLifecycleObserver,
        deviceTransportFactory: @escaping DeviceTransportFactory,
        pathMonitorFactory: @escaping @Sendable () -> any NetworkPathMonitor,
        connectionConfiguration: ConnectionManager.Configuration = .default,
        clock: @escaping @Sendable () -> Date = { Date() },
    ) async -> AppComposition {
        let authClient = AuthClient(
            config: authConfig,
            http: authHTTPClient,
        )

        // Build the coordinator first (no dependency on the signed
        // wrapper). The ``handleSessionExpired`` hook closes over it.
        let coordinator = AuthCoordinator(
            client: authClient,
            store: bearerStore,
            attestationProvider: attestationProvider,
        )

        // Wire the endpoint store as a sign-out observer at composition
        // time. Without this hook the store conforms to
        // ``SessionLifecycleObserver`` for nothing — sign-out wipes
        // the bearer keychain row but leaves the paired-device row
        // behind, so the next user signing in on the same device
        // inherits the prior user's pairing until the
        // ``PairingViewModel/start`` ownership re-check catches it
        // (and that path fails open on transient/offline launches,
        // making the inheritance window large enough to matter).
        // Registering here is the single composition-level guarantee
        // that the docstring claim on ``KeychainEndpointStore`` is
        // actually true at runtime.
        await coordinator.addLifecycleObserver(endpointStore)

        // Build the signed transport via the caller-supplied factory,
        // threading the composition's 401 callback. The factory is
        // the seam that controls pinning: Darwin production passes
        // the ``PinnedHTTPClient``-taking init; tests pass a
        // ``@testable``-accessible internal init.
        let signedTransport = signedHTTPClientFactory { [coordinator] in
            // Fire-and-forget on a 401. The coordinator drops the
            // in-memory bearer cache and notifies observers; any
            // subsequent protected call re-reads the keychain
            // (prompting for biometrics under the ``.userPresence``
            // ACL). The keychain row itself is NOT deleted.
            await coordinator.handleSessionExpired()
        }

        let pairingClient = PairingClient(
            baseURL: authConfig.baseURL,
            http: signedTransport,
        )
        let pairedDevicesClient = PairedDevicesClient(
            baseURL: authConfig.baseURL,
            http: signedTransport,
        )

        // The handshake builder captures the attestation provider so
        // every reconnect produces a fresh ``dev:<unix_seconds>``
        // signature under a fresh ECDSA ``k`` — the property the
        // server's replay cache relies on to distinguish legitimate
        // retries from captured-byte replays.
        let handshakeBuilder: ConnectionManager.HandshakeBuilder = { [attestationProvider, clock] in
            let timestamp = Int64(clock().timeIntervalSince1970)
            return try await attestationProvider.currentAttestationHeader(
                binding: .device(timestamp: timestamp),
            )
        }

        // The live auth gate calls the strict re-auth path on every
        // stream start. Cancellation maps to ``.cancelled``;
        // unavailability / biometric failure maps to ``.denied`` with
        // a diagnostic string. Every other error path also maps to
        // ``.denied`` — a failure to obtain user presence must NEVER
        // default-allow.
        let liveAuthGate: LiveViewModel.AuthGate = { [liveVideoGate] in
            do {
                try await liveVideoGate.requireLiveVideo()
                return .allowed
            } catch AuthError.cancelled {
                return .cancelled
            } catch {
                return .denied(String(describing: error))
            }
        }

        // The pairing auth gate uses the same conformer as
        // ``liveAuthGate`` but routes through the pairing-specific
        // method so the OS biometric sheet renders an action-specific
        // reason. Same default-deny posture: every non-success error
        // class maps to ``.denied`` so a failure to obtain user
        // presence cannot silently let the exchange proceed.
        let pairingAuthGate: PairingAuthGate = { [liveVideoGate] in
            do {
                try await liveVideoGate.requirePairing()
                return .allowed
            } catch AuthError.cancelled {
                return .cancelled
            } catch {
                return .denied(String(describing: error))
            }
        }

        return AppComposition(
            authCoordinator: coordinator,
            pairingClient: pairingClient,
            pairedDevicesClient: pairedDevicesClient,
            liveKitAllowlist: liveKitAllowlist,
            handshakeBuilder: handshakeBuilder,
            liveAuthGate: liveAuthGate,
            pairingAuthGate: pairingAuthGate,
            endpointStore: endpointStore,
            deviceTransportFactory: deviceTransportFactory,
            pathMonitorFactory: pathMonitorFactory,
            connectionConfiguration: connectionConfiguration,
            clock: clock,
        )
    }

    // MARK: - ConnectionManager factory

    /// Build a ``ConnectionManager`` for `device`.
    ///
    /// The factory is THE single authorised construction site for a
    /// supervisor on a paired connection. It threads three
    /// security-critical wirings into the manager:
    ///
    /// 1. The ``HandshakeResponseVerifier`` constructed from the
    ///    trusted ``PairedDevice/devicePublicKey`` (sourced from the
    ///    Keychain row written at pairing time and re-checked on
    ///    every ownership re-verification). The verifier rejects any
    ///    ``AuthResponse`` not signed by that key, closing the
    ///    impostor-at-the-Tailscale-endpoint gap.
    /// 2. The ``handshakeBuilder``, producing a freshly-signed `dev:`
    ///    attestation under a fresh ECDSA ``k`` per attempt.
    /// 3. A fresh ``NetworkPathMonitor`` per supervisor — each
    ///    instance owns its own monitor lifecycle so two supervisors
    ///    cannot share a monitor and silently disagree on the path
    ///    state.
    ///
    /// Without this factory the Xcode app target would have to wire
    /// the verifier itself; forgetting that one parameter would
    /// silently weaken the security posture to the level of the v1
    /// (one-way handshake) design. Routing every paired-connection
    /// supervisor through here makes the verifier wiring impossible
    /// to forget — the call site has no way to construct a
    /// ``DeviceClient`` that skips signature verification.
    public func connectionManager(for device: PairedDevice) -> ConnectionManager {
        let verifier = HandshakeResponseVerifier(devicePublicKey: device.devicePublicKey)
        let captured = handshakeBuilder
        let transports = deviceTransportFactory
        // Build the DeviceClient HERE, wiring the verifier from the
        // trusted Keychain-stored public key. The verifier is
        // captured by value in the closure so a later mutation of
        // `device` cannot retroactively change what the supervisor
        // trusts. The composition is the only place where a
        // production DeviceClient gets constructed against a paired
        // device; `DeviceClient.connect` itself enforces (with a
        // typed `handshakeVerifierMissing` error) that the verifier
        // is non-nil whenever a handshake is supplied, so a refactor
        // that bypasses this factory would crash loudly on the first
        // connect attempt instead of silently weakening the posture.
        let verifyingFactory: ConnectionManager.DeviceClientFactory = { endpoint in
            let transport = try transports(endpoint)
            return DeviceClient(
                transport: transport,
                responseVerifier: verifier,
            )
        }
        return ConnectionManager(
            endpoint: device.endpoint,
            clientFactory: verifyingFactory,
            pathMonitor: pathMonitorFactory(),
            handshakeBuilder: captured,
            configuration: connectionConfiguration,
        )
    }

    // MARK: - Private memberwise

    private let deviceTransportFactory: DeviceTransportFactory
    private let pathMonitorFactory: @Sendable () -> any NetworkPathMonitor
    private let connectionConfiguration: ConnectionManager.Configuration
    /// Shared clock source. Captured on the composition so the
    /// ``handshakeBuilder`` and ``historyViewModel(deviceClient:)``
    /// factory both observe the same wall-clock — a divergence
    /// between the two would manifest as nonsense session-history
    /// ranges or replay-cache misses on slow-clock builds.
    private let clock: @Sendable () -> Date

    private init(
        authCoordinator: AuthCoordinator,
        pairingClient: PairingClient,
        pairedDevicesClient: PairedDevicesClient,
        liveKitAllowlist: LiveKitHostAllowlist,
        handshakeBuilder: @escaping ConnectionManager.HandshakeBuilder,
        liveAuthGate: @escaping LiveViewModel.AuthGate,
        pairingAuthGate: @escaping PairingAuthGate,
        endpointStore: any EndpointStore & SessionLifecycleObserver,
        deviceTransportFactory: @escaping DeviceTransportFactory,
        pathMonitorFactory: @escaping @Sendable () -> any NetworkPathMonitor,
        connectionConfiguration: ConnectionManager.Configuration,
        clock: @escaping @Sendable () -> Date,
    ) {
        self.authCoordinator = authCoordinator
        self.pairingClient = pairingClient
        self.pairedDevicesClient = pairedDevicesClient
        self.liveKitAllowlist = liveKitAllowlist
        self.handshakeBuilder = handshakeBuilder
        self.liveAuthGate = liveAuthGate
        self.pairingAuthGate = pairingAuthGate
        self.endpointStore = endpointStore
        self.deviceTransportFactory = deviceTransportFactory
        self.pathMonitorFactory = pathMonitorFactory
        self.connectionConfiguration = connectionConfiguration
        self.clock = clock
    }
}

// MARK: - Production factory (Darwin-only)

#if canImport(Security) && canImport(Darwin) && canImport(LocalAuthentication)
public extension AppComposition {
    /// Build the production object graph. Darwin-only because it
    /// wires the Secure-Enclave-backed identity store, the
    /// ``LocalAuthentication``-gated bearer store, and the
    /// SPKI-pinned HTTP transport — none of which are available on
    /// Linux.
    ///
    /// Called once at app launch from the SwiftUI `App` entry point.
    /// Every component returned is already connected: invoking an
    /// authenticated HTTP call via ``pairingClient`` attaches the
    /// pinned transport, the signed bearer, the SE-backed attestation
    /// header, and the idempotency key; the ``onSessionExpired`` path
    /// routes into ``authCoordinator`` / ``bearerStore`` to drop the
    /// in-memory cache on a 401 without disturbing the keychain row.
    static func production(config: DeploymentConfig) async -> AppComposition {
        let identity = SecureEnclaveIdentityStore()
        let attestationProvider = SystemDeviceAttestationProvider(identity: identity)
        let bearerStore = GatedBearerTokenStore(
            underlying: KeychainBearerTokenStore(accessGroup: config.keychainAccessGroup),
            gate: SessionAccessGate(),
        )
        // Single shared endpoint store. Constructed here and passed
        // BOTH to ``make`` (which registers it as a sign-out
        // observer on the auth coordinator) AND held on the returned
        // composition so the Xcode app target threads the same
        // instance into ``PairingViewModel``. Any future code path
        // that builds a second ``KeychainEndpointStore`` instance
        // would race with this one — sign-out would wipe the row
        // owned by the registered observer while the pairing flow
        // would still observe a populated keychain via the other
        // instance until the next read coincided. Sharing one
        // instance closes that gap.
        let endpointStore = KeychainEndpointStore(
            accessGroup: config.keychainAccessGroup,
        )
        let pinnedTransport = PinnedHTTPClient(pinning: config.tlsPinning)
        // The signed-client factory uses the Darwin-only
        // ``SignedHTTPClient/init(transport:store:attestationProvider:
        // onSessionExpired:)`` initialiser, which enforces the
        // ``PinnedHTTPClient`` type invariant at compile time: the
        // product target has no way to reach the package-internal
        // init that accepts a raw ``HTTPClient``. A future refactor
        // that threaded an unpinned session into production would
        // have to either change this factory (visible diff) or reach
        // for ``@testable import``, which a release target cannot do.
        let pinnedFactory: SignedHTTPClientFactory = { [bearerStore, attestationProvider] onExpired in
            SignedHTTPClient(
                transport: pinnedTransport,
                store: bearerStore,
                attestationProvider: attestationProvider,
                onSessionExpired: onExpired,
            )
        }
        // Production transport factory: pin every TCP socket to the
        // Tailscale ``utunN`` interface via the production resolver.
        // ``NetworkDeviceTransport.init`` throws when no Tailscale
        // interface is available; the ``ConnectionManager`` catches
        // that and treats it as a transient connect failure (back off
        // and retry once Tailscale comes up).
        let transportFactory: DeviceTransportFactory = { endpoint in
            try NetworkDeviceTransport(endpoint: endpoint)
        }
        // Each ``ConnectionManager`` constructed via
        // ``connectionManager(for:)`` gets its own
        // ``SystemNetworkPathMonitor`` — the protocol forbids more
        // than one consumer of a monitor's stream, so two supervisors
        // sharing one would deadlock the second.
        let pathMonitorFactory: @Sendable () -> any NetworkPathMonitor = {
            SystemNetworkPathMonitor()
        }
        return await make(
            authConfig: config.authConfig,
            authHTTPClient: pinnedTransport,
            signedHTTPClientFactory: pinnedFactory,
            liveKitAllowlist: config.liveKitAllowlist,
            attestationProvider: attestationProvider,
            bearerStore: bearerStore,
            liveVideoGate: bearerStore,
            endpointStore: endpointStore,
            deviceTransportFactory: transportFactory,
            pathMonitorFactory: pathMonitorFactory,
        )
    }
}
#endif
