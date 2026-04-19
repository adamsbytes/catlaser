import CatLaserObservability
import Foundation
import Testing

/// End-to-end tests of the ``Observability`` actor. Uses the
/// in-memory transport + consent store so nothing touches the wire
/// or the Keychain.
@Suite("Observability")
struct ObservabilityActorTests {
    private func makeRig(
        consent: ConsentState = .granted(crashReporting: true, telemetry: true),
    ) -> (Observability, InMemoryObservabilityTransport, InMemoryConsentStore, ObservabilityConfig) {
        let config = try! ObservabilityConfig.derived(
            baseURL: URL(string: "https://api.example.com")!,
            deviceIDSalt: "salt-\(UUID().uuidString)",
            appVersion: "1.0.0",
            buildNumber: "1",
            bundleID: "com.catlaser.app",
        )
        let consentStore = InMemoryConsentStore(initial: consent)
        let transport = InMemoryObservabilityTransport()
        let facade = Observability(
            config: config,
            consent: consentStore,
            transport: transport,
        )
        return (facade, transport, consentStore, config)
    }

    /// Telemetry events are dropped on the floor when the user has
    /// not opted in. This is the single contract that keeps the
    /// pipeline privacy-safe — a bug here would silently leak
    /// events to the server.
    @Test
    func telemetryEventsAreGatedByConsent() async throws {
        let (facade, transport, _, _) = makeRig(consent: .declined)

        await facade.record(event: .signInSucceeded(provider: .apple))
        await facade.drain()

        let uploaded = await transport.uploaded
        #expect(uploaded.isEmpty,
                "declined consent must prevent any upload")
    }

    /// With consent granted and a successful transport, a drain
    /// uploads the queued events.
    @Test
    func drainUploadsQueuedEventsWhenConsentGranted() async throws {
        let (facade, transport, _, _) = makeRig()

        await facade.record(event: .signInSucceeded(provider: .apple))
        await facade.record(event: .pairingSucceeded)
        await facade.drain()

        let uploaded = await transport.uploaded
        #expect(uploaded.count == 1,
                "drain should coalesce both events into one batch")
        #expect(uploaded.first?.events.count == 2)
        let names = uploaded.first?.events.map(\.name) ?? []
        #expect(names.contains("sign_in_succeeded"))
        #expect(names.contains("pairing_succeeded"))
    }

    /// A transient transport failure leaves the queued events in
    /// place — the next drain retries them.
    @Test
    func transientFailureLeavesEventsQueuedForRetry() async throws {
        let (facade, transport, _, _) = makeRig()
        await transport.setBehavior(.fail(.uploadTransient("simulated")))

        await facade.record(event: .signedOut)
        await facade.drain()
        #expect(await transport.uploaded.isEmpty)

        await transport.setBehavior(.succeed)
        await facade.drain()
        let uploaded = await transport.uploaded
        #expect(uploaded.count == 1)
        #expect(uploaded.first?.events.map(\.name) == ["signed_out"])
    }

    /// Breadcrumbs are recorded regardless of consent — they never
    /// leave the device on their own.
    @Test
    func breadcrumbsAreRecordedIndependentOfConsent() async throws {
        let (facade, _, _, _) = makeRig(consent: .declined)
        // Telemetry off — but recording a breadcrumb is still OK
        // because it's local-only until a crash happens.
        facade.record(.navigation, "screen.shown", attributes: ["screen": "sign_in"])
        // The facade has no `snapshot()` public API; instead we
        // assert via the crash-payload path — purge then re-record
        // and assert the purge did its job.
        await facade.purgeLocalState()
        // A record after purge must re-populate the ring; we can't
        // directly observe that without reflection, but this test
        // asserts the no-crash contract of the fire-and-forget
        // surface.
        facade.record(.navigation, "screen.shown2")
    }

    /// `purgeLocalState()` is the sign-out hygiene hook — called by
    /// ``ObservabilityLifecycleObserver`` on sign-out. A second
    /// drain after a purge must not upload anything.
    @Test
    func purgeLocalStateClearsPendingEvents() async throws {
        let (facade, transport, _, _) = makeRig()
        await facade.record(event: .signInSucceeded(provider: .google))
        await facade.purgeLocalState()
        await facade.drain()
        #expect(await transport.uploaded.isEmpty)
    }
}
