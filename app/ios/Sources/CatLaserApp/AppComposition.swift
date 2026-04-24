import CatLaserAuth
import CatLaserDevice
import CatLaserHistory
import CatLaserLive
import CatLaserObservability
import CatLaserPairing
import CatLaserPush
import CatLaserSchedule
import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

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

        /// Observability endpoints, storage paths, app version, and
        /// device-id hashing salt. Production callers derive this
        /// from the same coordination-server base URL ``authConfig``
        /// uses via ``ObservabilityConfig/derived(baseURL:...)`` so
        /// the three endpoints (auth, observability-events,
        /// observability-crashes) land on the same Cloudflare worker.
        public let observabilityConfig: ObservabilityConfig

        public init(
            authConfig: AuthConfig,
            tlsPinning: TLSPinning,
            liveKitAllowlist: LiveKitHostAllowlist,
            observabilityConfig: ObservabilityConfig,
            keychainAccessGroup: String? = nil,
        ) {
            self.authConfig = authConfig
            self.tlsPinning = tlsPinning
            self.liveKitAllowlist = liveKitAllowlist
            self.observabilityConfig = observabilityConfig
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

    /// Observability facade — breadcrumb ring, telemetry queue,
    /// crash uploader. Constructed once per launch in
    /// ``production(config:)``; the composition wires it as a
    /// ``SessionLifecycleObserver`` on the auth coordinator so
    /// sign-out purges local observability state (breadcrumbs,
    /// pending telemetry, tombstones). Every view that wants to
    /// record an event or a breadcrumb reaches for this instance
    /// via the composition it was constructed from.
    public let observability: Observability

    /// Consent store. Read at launch to decide whether to present
    /// ``PrivacyConsentView``. Shared with the consent VM, the
    /// future Settings screen, and the observability actor (which
    /// reads it on every upload).
    public let consentStore: any ConsentStore

    /// Face ID / passcode intro store. Read at launch (after the
    /// consent screen commits) to decide whether to present
    /// ``FaceIDIntroView``. One-shot: once the user dismisses the
    /// card (via Got it, or Continue anyway when biometrics are
    /// unavailable), the flag flips and the card is skipped on
    /// subsequent launches.
    public let faceIDIntroductionStore: any FaceIDIntroductionStore

    /// Onboarding tour store. Holds two one-shot flags: the tabs
    /// tour (shown on the first successful pair + connect) and the
    /// schedule hint (shown on the first Schedule tab visit). The
    /// ``PairedShell`` reads the first; ``ScheduleView`` reads the
    /// second. Both flip on first dismissal and stay.
    public let onboardingTourStore: any OnboardingTourStore

    /// Bearer-token store retained here so ``applicationDidEnterBackground``
    /// can drop the in-memory cache on scene backgrounding. The
    /// keychain row is deliberately untouched — the next protected
    /// call will re-read under the Secure-Enclave `.userPresence` ACL
    /// and prompt the user for biometrics, which is the posture the
    /// `GatedBearerTokenStore` docstring claims. Without this hook the
    /// in-memory bearer survives every app background, undercutting
    /// the 2-minute idle window the gate advertises.
    private let bearerStore: any BearerTokenStore & SessionInvalidating

    /// Single shared push-token registrar. Wired as a
    /// ``SessionLifecycleObserver`` on the auth coordinator at
    /// composition time so sign-out unregisters the APNs token from
    /// the paired device (and wipes the local cache) without the
    /// Xcode app target having to remember. The same registrar is
    /// threaded into every ``PushViewModel`` the composition mints —
    /// a second registrar instance would race with this one on
    /// token dedupe and silently re-register on every wake.
    ///
    /// The Xcode app target additionally feeds the supervisor's
    /// ``ConnectionState.connected(client)`` reference into
    /// ``PushTokenRegistrar/setClient(_:)`` so a fresh reconnect
    /// triggers a fresh register against the new `DeviceClient`
    /// identity.
    public let pushRegistrar: PushTokenRegistrar

    /// Construct a ``DeviceEventBroker`` attached to the supplied
    /// ``DeviceClient``. Intended to be constructed once per supervisor
    /// cycle (each reconnect produces a fresh client → fresh broker)
    /// and shared across every VM that observes the device's
    /// unsolicited event surface. The broker itself is the single
    /// consumer of ``DeviceClient/events``; view models subscribe via
    /// ``DeviceEventBroker/events()`` so multiple screens can observe
    /// concurrently without racing the single-consumer contract.
    ///
    /// The caller is responsible for lifecycle: ``start()`` after
    /// construction and ``stop()`` before tearing down the supervisor
    /// cycle. The ``PairedShell`` threads these calls through its
    /// connection-state reconcile loop.
    @MainActor
    public func deviceEventBroker(for deviceClient: DeviceClient) -> DeviceEventBroker {
        DeviceEventBroker(client: deviceClient, clock: clock)
    }

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
    /// The ``eventBroker`` parameter is threaded through so the VM
    /// can observe device heartbeats and render the live-view session
    /// overlay. The same broker instance MUST be passed to the
    /// sibling ``historyViewModel`` so both VMs observe the same
    /// device-pushed event stream through the one authorised consumer.
    ///
    /// The factory is `@MainActor` because ``LiveViewModel`` itself
    /// is MainActor-isolated — constructing it off the main thread
    /// would require a hop anyway, so we surface that constraint at
    /// the factory boundary.
    @MainActor
    public func liveViewModel(
        pairedDevice: PairedDevice,
        deviceClient: DeviceClient,
        eventBroker: DeviceEventBroker,
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
            eventBroker: eventBroker,
            clock: clock,
        )
    }

    /// Construct a ``HistoryViewModel`` wired to the supplied
    /// ``DeviceClient``. The same client instance threaded through
    /// ``liveViewModel(pairedDevice:deviceClient:eventBroker:)`` MUST
    /// be passed here — likewise the same ``DeviceEventBroker``
    /// instance — so both VMs observe the device through one broker
    /// and one client. A second broker built behind the back of the
    /// composition would race the single-consumer contract on
    /// ``DeviceClient/events`` and silently drop pushes against
    /// whichever broker lost the race.
    ///
    /// ``@MainActor`` because ``HistoryViewModel`` is MainActor-
    /// isolated: constructing it off the main thread would require a
    /// hop anyway, so we surface the constraint at the factory
    /// boundary.
    @MainActor
    public func historyViewModel(
        deviceClient: DeviceClient,
        eventBroker: DeviceEventBroker,
    ) -> HistoryViewModel {
        HistoryViewModel(
            deviceClient: deviceClient,
            eventBroker: eventBroker,
            clock: clock,
        )
    }

    /// Construct a ``ScheduleViewModel`` wired to the supplied
    /// ``DeviceClient``. Like ``historyViewModel``, the SAME
    /// supervisor-owned client instance MUST be threaded through so
    /// every screen shares the post-handshake connection (a
    /// background-built second client would miss the
    /// ``HandshakeResponseVerifier`` wiring and race the supervisor's
    /// reconnect logic).
    ///
    /// The schedule VM does not subscribe to the
    /// ``DeviceClient.events`` stream — see the module docstring
    /// on ``ScheduleViewModel`` for why — so it cannot contend with
    /// ``HistoryViewModel`` for the single-consumer surface.
    ///
    /// ``@MainActor`` because ``ScheduleViewModel`` is MainActor-
    /// isolated.
    @MainActor
    public func scheduleViewModel(deviceClient: DeviceClient) -> ScheduleViewModel {
        ScheduleViewModel(deviceClient: deviceClient)
    }

    /// Construct a ``PushViewModel`` wired to the composition's
    /// ``pushRegistrar`` and to the caller-supplied OS bridge
    /// closures. The closures are supplied per-composition (not per-
    /// call) because they are stateless and injected by the
    /// ``production(config:)`` factory on Darwin (backed by
    /// ``PushAuthorizationController``). The cross-platform
    /// ``make(...)`` variant accepts them directly so Linux-side
    /// tests can stub them.
    ///
    /// ``@MainActor`` because ``PushViewModel`` is MainActor-
    /// isolated; hoisting the constraint to the factory boundary
    /// surfaces it to the SwiftUI host rather than hiding it inside
    /// a VM initialiser call.
    @MainActor
    public func pushViewModel() -> PushViewModel {
        PushViewModel(
            registrar: pushRegistrar,
            prompt: pushPrompt,
            readAuthorization: pushReadAuthorization,
            registerForRemoteNotifications: pushRegisterForRemote,
        )
    }

    /// Build a ``PrivacyConsentViewModel`` wired to this
    /// composition's consent store and observability facade. The
    /// host view calls ``onCompletion`` when the user taps Continue
    /// so the SwiftUI root can transition from the consent screen
    /// to the sign-in flow.
    @MainActor
    public func privacyConsentViewModel(
        onCompletion: @escaping @MainActor () -> Void,
    ) -> PrivacyConsentViewModel {
        PrivacyConsentViewModel(
            consentStore: consentStore,
            observability: observability,
            onCompletion: onCompletion,
        )
    }

    /// Whether the consent screen must be presented before the
    /// main flow. Read once at launch; subsequent changes to consent
    /// state are committed via the VM and do not re-trigger the
    /// prompt.
    public func needsPrivacyConsent() async -> Bool {
        await consentStore.load().needsPrompt
    }

    /// Whether the Face ID / passcode onboarding card must be
    /// presented. One-shot: after the user commits once the flag
    /// flips and stays. Read after the consent gate clears so the
    /// two prompts don't stack.
    public func needsFaceIDIntroduction() async -> Bool {
        await faceIDIntroductionStore.load().needsPrompt
    }

    /// Build the Face ID intro VM. Called by the app shell when
    /// ``needsFaceIDIntroduction()`` is `true`; the shell passes a
    /// completion closure that drives the phase machine forward.
    @MainActor
    public func faceIDIntroViewModel(
        onCompletion: @escaping @MainActor () -> Void,
    ) -> FaceIDIntroViewModel {
        FaceIDIntroViewModel(
            store: faceIDIntroductionStore,
            onCompletion: onCompletion,
        )
    }

    // MARK: - Lifecycle hooks

    /// Called by the app's scene-phase observer on every transition
    /// into ``ScenePhase/background``.
    ///
    /// Two cooperating actions:
    ///
    /// 1. Drop the in-memory bearer cache via
    ///    ``SessionInvalidating/invalidateSession()``. The next
    ///    protected call will re-read the keychain, which triggers a
    ///    biometric prompt under the `.userPresence` ACL. This is the
    ///    property the `GatedBearerTokenStore` docstring claims —
    ///    without this hook the in-memory cache survives every
    ///    background, and a stolen-just-unlocked phone could swipe up
    ///    back into the app and reach protected calls without a fresh
    ///    prompt.
    /// 2. Best-effort drain of the observability queue so pending
    ///    telemetry or crash-payload tombstones ship before the OS
    ///    suspends the app. The drain is cooperative — a concurrent
    ///    drain no-ops — and the iOS runtime's graceful-suspension
    ///    window caps the work; we never block the scene transition.
    ///
    /// Idempotent: a double-call (rapid foreground / background hop)
    /// is safe. Both downstream actions already guard against
    /// concurrent invocation internally.
    public func applicationDidEnterBackground() async {
        await bearerStore.invalidateSession()
        await observability.drain()
    }

    /// Called by the app's scene-phase observer on every transition
    /// into ``ScenePhase/active``, including first-foreground on cold
    /// launch.
    ///
    /// Kicks an observability drain so any events queued while the
    /// network was unreachable ship now that it is presumably back.
    /// The ``ConnectionManager`` reacts to network-path changes on its
    /// own, so the supervisor does not need a manual foreground kick
    /// — its ``NetworkPathMonitor`` surfaces the `.satisfied` event
    /// that wakes the parked backoff immediately.
    ///
    /// Idempotent: a second call while a previous drain is in flight
    /// no-ops inside ``Observability/drain()``.
    public func applicationDidBecomeActive() async {
        await observability.drain()
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
        observability: Observability,
        consentStore: any ConsentStore,
        faceIDIntroductionStore: any FaceIDIntroductionStore,
        onboardingTourStore: any OnboardingTourStore,
        deviceTransportFactory: @escaping DeviceTransportFactory,
        pathMonitorFactory: @escaping @Sendable () -> any NetworkPathMonitor,
        pushPrompt: @escaping PushViewModel.AuthorizationPrompt,
        pushReadAuthorization: @escaping PushViewModel.AuthorizationStatusReader,
        pushRegisterForRemoteNotifications: @escaping PushViewModel.RegisterForRemoteNotifications,
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

        // The push-token registrar is the second composition-time
        // lifecycle observer. Sign-out unregisters the APNs token
        // with the paired device (and wipes the local cache) so the
        // server does not keep delivering pushes to an account the
        // user has abandoned. Sign-out hygiene here mirrors the
        // endpoint store's: a refactor that builds a second registrar
        // behind the back of the composition would have that second
        // instance miss the observer hook and the keychain-bound
        // paired device would keep receiving pushes.
        let pushRegistrar = PushTokenRegistrar()
        await coordinator.addLifecycleObserver(pushRegistrar)

        // The observability lifecycle observer fires on sign-out and
        // on 401. Sign-out purges every persisted observability
        // artefact (breadcrumbs, telemetry queue, tombstones) so the
        // next user on the same device cannot read the prior user's
        // audit trail. 401 records a breadcrumb but leaves state
        // intact because a 401 is a short-lived re-auth nudge, not a
        // permanent session end.
        let observabilityObserver = ObservabilityLifecycleObserver(
            observability: observability,
        )
        await coordinator.addLifecycleObserver(observabilityObserver)

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
            pushRegistrar: pushRegistrar,
            observability: observability,
            consentStore: consentStore,
            faceIDIntroductionStore: faceIDIntroductionStore,
            onboardingTourStore: onboardingTourStore,
            bearerStore: bearerStore,
            pushPrompt: pushPrompt,
            pushReadAuthorization: pushReadAuthorization,
            pushRegisterForRemote: pushRegisterForRemoteNotifications,
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
    /// Cross-platform OS bridge for the push screen. Stored here so
    /// ``pushViewModel()`` has a single source of truth (and a single
    /// test-injection surface) for the ``UserNotifications`` /
    /// ``UIApplication`` calls a Linux runner cannot issue.
    private let pushPrompt: PushViewModel.AuthorizationPrompt
    private let pushReadAuthorization: PushViewModel.AuthorizationStatusReader
    private let pushRegisterForRemote: PushViewModel.RegisterForRemoteNotifications

    private init(
        authCoordinator: AuthCoordinator,
        pairingClient: PairingClient,
        pairedDevicesClient: PairedDevicesClient,
        liveKitAllowlist: LiveKitHostAllowlist,
        handshakeBuilder: @escaping ConnectionManager.HandshakeBuilder,
        liveAuthGate: @escaping LiveViewModel.AuthGate,
        pairingAuthGate: @escaping PairingAuthGate,
        endpointStore: any EndpointStore & SessionLifecycleObserver,
        pushRegistrar: PushTokenRegistrar,
        observability: Observability,
        consentStore: any ConsentStore,
        faceIDIntroductionStore: any FaceIDIntroductionStore,
        onboardingTourStore: any OnboardingTourStore,
        bearerStore: any BearerTokenStore & SessionInvalidating,
        pushPrompt: @escaping PushViewModel.AuthorizationPrompt,
        pushReadAuthorization: @escaping PushViewModel.AuthorizationStatusReader,
        pushRegisterForRemote: @escaping PushViewModel.RegisterForRemoteNotifications,
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
        self.pushRegistrar = pushRegistrar
        self.observability = observability
        self.consentStore = consentStore
        self.faceIDIntroductionStore = faceIDIntroductionStore
        self.onboardingTourStore = onboardingTourStore
        self.bearerStore = bearerStore
        self.pushPrompt = pushPrompt
        self.pushReadAuthorization = pushReadAuthorization
        self.pushRegisterForRemote = pushRegisterForRemote
        self.deviceTransportFactory = deviceTransportFactory
        self.pathMonitorFactory = pathMonitorFactory
        self.connectionConfiguration = connectionConfiguration
        self.clock = clock
    }
}

// MARK: - Production factory (Darwin-only)

#if canImport(Security) && canImport(Darwin) && canImport(LocalAuthentication) && canImport(UserNotifications)
import UserNotifications

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
        // Push OS bridge: one shared ``PushAuthorizationController``
        // instance backs every closure. The controller is stateless
        // (the shared ``UNUserNotificationCenter`` is a process-wide
        // singleton anyway), so a single captured reference is
        // correct. The ``PushTokenRegistrar`` lives on the composition
        // itself — ``make`` registers it as a session-lifecycle
        // observer so sign-out unregisters the APNs token without
        // the Xcode app target having to remember. A product target
        // that bypassed this factory would have to build both the
        // controller AND the registrar themselves and could silently
        // forget one — the composition is the belt-and-braces
        // guarantee that both are wired.
        let authController = PushAuthorizationController()
        let pushPrompt: PushViewModel.AuthorizationPrompt = {
            try await authController.prompt()
        }
        let pushReadAuthorization: PushViewModel.AuthorizationStatusReader = {
            await authController.currentStatus()
        }
        let pushRegisterForRemote: PushViewModel.RegisterForRemoteNotifications = {
            await authController.registerForRemoteNotifications()
        }

        // Observability pipeline. Wires:
        //  * the persistent ``UserDefaultsConsentStore`` (UserDefaults
        //    value, versioned key) — checked on every upload.
        //  * the HTTPS transport hanging off the same pinned URL
        //    session the auth traffic uses, with a bearer-provider
        //    closure that attaches the current bearer when available
        //    (opportunistic: pre-login crash uploads still ship).
        //  * the ``Observability`` actor — breadcrumb ring,
        //    telemetry queue, tombstone pickup. Registered as a
        //    ``SessionLifecycleObserver`` inside ``make`` so sign-out
        //    purges every persisted artefact.
        //  * the POSIX signal + ``NSException`` handlers, which
        //    write tombstones the facade picks up on next launch.
        //  * the ``MXMetricManager`` subscriber that delivers
        //    Apple-signed crash / hang / cpu-exception diagnostics
        //    on the launch following a crash.
        //
        // The MetricKit bridge and the in-process handlers are
        // installed inside an unstructured Task so a failure to
        // register does not block the rest of the composition from
        // returning (and therefore the app from launching).
        let consentStore = UserDefaultsConsentStore()
        let faceIDIntroductionStore = UserDefaultsFaceIDIntroductionStore()
        let onboardingTourStore = UserDefaultsOnboardingTourStore()
        let observabilityTransportClient = ObservabilityPinnedHTTPClient(
            pinned: pinnedTransport,
        )
        let transport = HTTPObservabilityTransport(
            uploadURL: config.observabilityConfig.telemetryURL,
            httpClient: observabilityTransportClient,
            bearerProvider: { [bearerStore] in
                try? await bearerStore.load()?.bearerToken
            },
        )
        let observability = Observability(
            config: config.observabilityConfig,
            consent: consentStore,
            transport: transport,
        )

        // Install the in-process crash handler BEFORE doing any more
        // work so any crash between now and the end of composition is
        // captured for the next launch. The handler is idempotent —
        // a test that runs ``production`` twice (unusual) does not
        // double-install.
        try? config.observabilityConfig.tombstoneDirectory.checkResourceIsReachable()
        let tombstoneStore = TombstoneStore(
            directory: config.observabilityConfig.tombstoneDirectory,
        )
        try? tombstoneStore.prepare()
        InProcessCrashHandler.install(
            tombstoneDirectory: config.observabilityConfig.tombstoneDirectory,
            sessionID: observability.sessionID,
            appVersion: config.observabilityConfig.appVersion,
            buildNumber: config.observabilityConfig.buildNumber,
            osVersion: UIDevice.current.systemVersion,
        )

        // Register for MetricKit deliveries. The subscriber holds a
        // strong reference to the bridge (``MetricKitBridge``) via
        // a static so a future deployment does not have to remember
        // to hold onto the bridge themselves.
        let metricKitBridge = MetricKitBridge(handler: { [observability] payloads in
            Task { await observability.ingestCrashPayloads(payloads) }
        })
        metricKitBridge.register()
        _metricKitBridge = metricKitBridge

        let composition = await make(
            authConfig: config.authConfig,
            authHTTPClient: pinnedTransport,
            signedHTTPClientFactory: pinnedFactory,
            liveKitAllowlist: config.liveKitAllowlist,
            attestationProvider: attestationProvider,
            bearerStore: bearerStore,
            liveVideoGate: bearerStore,
            endpointStore: endpointStore,
            observability: observability,
            consentStore: consentStore,
            faceIDIntroductionStore: faceIDIntroductionStore,
            onboardingTourStore: onboardingTourStore,
            deviceTransportFactory: transportFactory,
            pathMonitorFactory: pathMonitorFactory,
            pushPrompt: pushPrompt,
            pushReadAuthorization: pushReadAuthorization,
            pushRegisterForRemoteNotifications: pushRegisterForRemote,
        )

        // Kick off the first drain. Any crash payload + any queued
        // events from previous sessions get uploaded as soon as the
        // network is up — the drain is cooperative and a second
        // concurrent call no-ops, so the Task here does not race
        // with a later on-foreground drain.
        Task { await observability.drain() }

        return composition
    }
}

/// Process-global strong reference to the ``MXMetricManager``
/// subscriber. MetricKit registers with a weak reference pattern
/// (subscribers stay alive by being retained elsewhere); we keep
/// them here so the registration survives the composition returning.
/// Shared via ``nonisolated(unsafe)`` because the value is mutated
/// only from the main-actor ``production`` factory during launch.
nonisolated(unsafe) private var _metricKitBridge: MetricKitBridge?

/// Bridge type that lets ``HTTPObservabilityTransport`` use the
/// same ``PinnedHTTPClient`` the rest of the app uses for auth
/// traffic, without requiring ``CatLaserObservability`` to import
/// ``CatLaserAuth``. The transport declares a minimal
/// ``HTTPClient`` protocol of its own; this adapter bridges the
/// two.
private struct ObservabilityPinnedHTTPClient: ObservabilityHTTPClient {
    let pinned: PinnedHTTPClient

    func send(_ request: URLRequest) async throws -> ObservabilityHTTPResponse {
        let response = try await pinned.send(request)
        return ObservabilityHTTPResponse(
            statusCode: response.statusCode,
            headers: response.headers,
            body: response.body,
        )
    }
}
#endif
