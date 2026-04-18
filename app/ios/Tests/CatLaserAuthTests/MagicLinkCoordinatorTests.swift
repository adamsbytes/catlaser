import Foundation
import Testing

@testable import CatLaserAuth

private func makeConfig() throws -> AuthConfig {
    try AuthConfig(
        baseURL: URL(string: "https://auth.catlaser.example")!,
        appleServiceID: "svc",
        googleClientID: "cid",
        bundleID: "com.catlaser.app",
        universalLinkHost: "link.catlaser.example",
        universalLinkPath: "/app/magic-link",
        oauthRedirectHosts: ["auth.catlaser.example"],
    )
}

/// Records every header request, the binding that produced it, and the
/// fingerprint behind it so tests can assert that (a) the request and
/// verify attestations share the same `fph` and `pk` but (b) their
/// bindings are tagged distinctly and the `sig` is fresh on each call.
actor RecordingAttestationProvider: DeviceAttestationProviding {
    let fingerprint: DeviceFingerprint
    let identity: any DeviceIdentityStoring

    private(set) var headerCalls: [String] = []
    private(set) var attestationCalls: [DeviceAttestation] = []
    private(set) var bindingCalls: [AttestationBinding] = []

    init(fingerprint: DeviceFingerprint, identity: any DeviceIdentityStoring) {
        self.fingerprint = fingerprint
        self.identity = identity
    }

    nonisolated func currentFingerprint() async throws -> DeviceFingerprint {
        fingerprint
    }

    nonisolated func currentAttestation(binding: AttestationBinding) async throws -> DeviceAttestation {
        let attestation = try await DeviceAttestationBuilder.build(
            fingerprint: fingerprint,
            identity: identity,
            binding: binding,
        )
        await record(attestation: attestation, binding: binding)
        return attestation
    }

    private func record(attestation: DeviceAttestation, binding: AttestationBinding) {
        attestationCalls.append(attestation)
        bindingCalls.append(binding)
    }

    nonisolated func currentAttestationHeader(binding: AttestationBinding) async throws -> String {
        let attestation = try await currentAttestation(binding: binding)
        let header = try DeviceAttestationEncoder.encodeHeaderValue(attestation)
        await recordHeader(header)
        return header
    }

    private func recordHeader(_ header: String) {
        headerCalls.append(header)
    }
}

private func makeFingerprint(installID: String = "test-install") -> DeviceFingerprint {
    DeviceFingerprint(
        platform: "ios",
        model: "iPhone15,4",
        systemName: "iOS",
        bundleID: "com.catlaser.app",
        installID: installID,
    )
}

@Suite("AuthCoordinator magic link")
struct MagicLinkCoordinatorTests {
    @Test
    func requestMagicLinkSendsAttestationHeader() async throws {
        let mock = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
        ])
        let client = AuthClient(
            config: try makeConfig(),
            http: mock,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        let identity = SoftwareIdentityStore()
        let installID = try await identity.installID()
        let fingerprint = makeFingerprint(installID: installID)
        let provider = RecordingAttestationProvider(fingerprint: fingerprint, identity: identity)
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            attestationProvider: provider,
            clock: { Date(timeIntervalSince1970: 1_700_000_042) },
        )

        try await coord.requestMagicLink(email: "cat@example.com")

        let req = try #require(await mock.lastRequest())
        let header = try #require(req.header(DeviceAttestationEncoder.headerName))
        #expect(await provider.headerCalls.count == 1)
        #expect(header == (await provider.headerCalls[0]))
        // No session persisted at request time (link hasn't been completed).
        #expect(try await store.load() == nil)

        // Decode and sanity-check the header contents.
        let attestation = try DeviceAttestationEncoder.decodeHeaderValue(header)
        #expect(attestation.version == DeviceAttestation.currentVersion)
        #expect(attestation.fingerprintHash.count == 32)
        #expect(attestation.publicKeySPKI == (try await identity.publicKeySPKI()))
        // Request flow must bind to the wall-clock second.
        #expect(attestation.binding == .request(timestamp: 1_700_000_042))
        let bindings = await provider.bindingCalls
        #expect(bindings == [.request(timestamp: 1_700_000_042)])
    }

    @Test
    func requestAndCompletePairSharesFphAndPkButDiffersOnBinding() async throws {
        // The crux of the phishing + replay defence: `fph` (hash of the
        // canonical fingerprint) and `pk` (public key) are byte-identical
        // on request and verify so the server can confirm same device;
        // the `bnd` differs (timestamp on request vs token on verify) so
        // a capture of one cannot be replayed as the other; `sig`
        // differs every call — ECDSA is non-deterministic and the signed
        // bytes include the distinct binding.
        let mock = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
            .response(.json(["user": ["id": "u", "emailVerified": true]], token: "tok")),
        ])
        let client = AuthClient(
            config: try makeConfig(),
            http: mock,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        let identity = SoftwareIdentityStore()
        let installID = try await identity.installID()
        let fingerprint = makeFingerprint(installID: installID)
        let provider = RecordingAttestationProvider(fingerprint: fingerprint, identity: identity)
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            attestationProvider: provider,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )

        try await coord.requestMagicLink(email: "cat@example.com")
        _ = try await coord.completeMagicLink(url: URL(string: "https://link.catlaser.example/app/magic-link?token=T")!)

        let requests = await mock.requests()
        #expect(requests.count == 2)

        let requestHeader = try #require(requests[0].header(DeviceAttestationEncoder.headerName))
        let completeHeader = try #require(requests[1].header(DeviceAttestationEncoder.headerName))

        let requestAttestation = try DeviceAttestationEncoder.decodeHeaderValue(requestHeader)
        let completeAttestation = try DeviceAttestationEncoder.decodeHeaderValue(completeHeader)

        #expect(requestAttestation.fingerprintHash == completeAttestation.fingerprintHash,
                "same device + same fingerprint ⇒ identical fph")
        #expect(requestAttestation.publicKeySPKI == completeAttestation.publicKeySPKI,
                "same SE key ⇒ identical pk")
        #expect(requestAttestation.binding != completeAttestation.binding,
                "request and verify must use distinctly-tagged bindings")
        #expect(requestAttestation.binding == .request(timestamp: 1_700_000_000))
        #expect(completeAttestation.binding == .verify(token: "T"))
        #expect(requestAttestation.signature != completeAttestation.signature,
                "ECDSA over distinct signed bytes ⇒ fresh sig per call")
    }

    @Test
    func completeMagicLinkBindsVerifyToTokenFromURL() async throws {
        // A capture of the request-time attestation cannot satisfy the
        // verify endpoint because the token encoded in the binding
        // changes per-link. Here we assert the verify-call binding
        // equals exactly the token parsed from the URL.
        let mock = MockHTTPClient(outcomes: [
            .response(.json(["user": ["id": "u", "emailVerified": true]], token: "bearer")),
        ])
        let client = AuthClient(
            config: try makeConfig(),
            http: mock,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        let identity = SoftwareIdentityStore()
        let installID = try await identity.installID()
        let fingerprint = makeFingerprint(installID: installID)
        let provider = RecordingAttestationProvider(fingerprint: fingerprint, identity: identity)
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            attestationProvider: provider,
        )
        let url = URL(string: "https://link.catlaser.example/app/magic-link?token=unique-per-link")!
        _ = try await coord.completeMagicLink(url: url)

        let bindings = await provider.bindingCalls
        #expect(bindings == [.verify(token: "unique-per-link")])
    }

    @Test
    func completeMagicLinkFromURLExchangesAndPersists() async throws {
        let mock = MockHTTPClient(outcomes: [
            .response(.json(
                ["user": ["id": "u-ml", "email": "cat@example.com", "emailVerified": true]],
                token: "bearer-ml",
            )),
        ])
        let client = AuthClient(
            config: try makeConfig(),
            http: mock,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        let identity = SoftwareIdentityStore()
        let installID = try await identity.installID()
        let fingerprint = makeFingerprint(installID: installID)
        let provider = StubDeviceAttestationProvider(fingerprint: fingerprint, identity: identity)
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            attestationProvider: provider,
        )
        let url = URL(string: "https://link.catlaser.example/app/magic-link?token=opaque123")!
        let session = try await coord.completeMagicLink(url: url)

        #expect(session.bearerToken == "bearer-ml")
        #expect(session.provider == .magicLink)
        #expect(session.user.id == "u-ml")
        #expect(try await store.load() == session)

        let req = try #require(await mock.lastRequest())
        #expect(req.url?.absoluteString == "https://auth.catlaser.example/api/v1/auth/magic-link/verify?token=opaque123")
    }

    @Test
    func missingAttestationProviderBlocksRequest() async throws {
        let mock = MockHTTPClient(outcomes: [])
        let client = AuthClient(
            config: try makeConfig(),
            http: mock,
            clock: { Date() },
        )
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(client: client, store: store)
        do {
            try await coord.requestMagicLink(email: "a@b.com")
            Issue.record("expected providerUnavailable")
        } catch let AuthError.providerUnavailable(msg) {
            #expect(msg.lowercased().contains("magic link"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await mock.sendCount() == 0)
    }

    @Test
    func missingAttestationProviderBlocksCompletion() async throws {
        let mock = MockHTTPClient(outcomes: [])
        let client = AuthClient(
            config: try makeConfig(),
            http: mock,
            clock: { Date() },
        )
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(client: client, store: store)
        let url = URL(string: "https://link.catlaser.example/app/magic-link?token=T")!
        await #expect(throws: (any Error).self) {
            _ = try await coord.completeMagicLink(url: url)
        }
        #expect(await mock.sendCount() == 0)
        #expect(try await store.load() == nil)
    }

    @Test
    func completeWithBadURLDoesNotHitNetworkOrStore() async throws {
        let mock = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: mock, clock: { Date() })
        let identity = SoftwareIdentityStore()
        let installID = try await identity.installID()
        let provider = StubDeviceAttestationProvider(
            fingerprint: makeFingerprint(installID: installID),
            identity: identity,
        )
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            attestationProvider: provider,
        )
        let url = URL(string: "https://evil.example/app/magic-link?token=T")!
        do {
            _ = try await coord.completeMagicLink(url: url)
            Issue.record("expected invalidMagicLink")
        } catch AuthError.invalidMagicLink {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await mock.sendCount() == 0)
        #expect(try await store.load() == nil)
    }

    @Test
    func serverMismatchRetainsPreviousSession() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["code": "DEVICE_MISMATCH"])
        let mock = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 403, headers: [:], body: body)),
        ])
        let client = AuthClient(config: try makeConfig(), http: mock, clock: { Date() })
        let existing = AuthSession(
            bearerToken: "still-valid",
            user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
            provider: .apple,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let store = InMemoryBearerTokenStore(initial: existing)
        let identity = SoftwareIdentityStore()
        let installID = try await identity.installID()
        let provider = StubDeviceAttestationProvider(
            fingerprint: makeFingerprint(installID: installID),
            identity: identity,
        )
        let coord = AuthCoordinator(
            client: client,
            store: store,
            attestationProvider: provider,
        )
        let url = URL(string: "https://link.catlaser.example/app/magic-link?token=T")!
        do {
            _ = try await coord.completeMagicLink(url: url)
            Issue.record("expected invalidMagicLink")
        } catch AuthError.invalidMagicLink {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(try await store.load() == existing, "failed completion must not drop existing session")
    }

    @Test
    func currentSessionLoadsExistingMagicLinkSession() async throws {
        let prev = AuthSession(
            bearerToken: "t",
            user: AuthUser(id: "u", email: "x@y.com", name: nil, image: nil, emailVerified: true),
            provider: .magicLink,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let store = InMemoryBearerTokenStore(initial: prev)
        let mock = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: mock, clock: { Date() })
        let coord = AuthCoordinator(client: client, store: store)
        let loaded = try await coord.currentSession()
        #expect(loaded == prev)
    }

    @Test
    func signOutOnMagicLinkSessionHitsServerAndClearsStore() async throws {
        let mock = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 200, headers: [:], body: Data())),
        ])
        let client = AuthClient(
            config: try makeConfig(),
            http: mock,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        let session = AuthSession(
            bearerToken: "bearer-ml",
            user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
            provider: .magicLink,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let store = InMemoryBearerTokenStore(initial: session)
        let identity = SoftwareIdentityStore()
        let installID = try await identity.installID()
        let provider = StubDeviceAttestationProvider(
            fingerprint: makeFingerprint(installID: installID),
            identity: identity,
        )
        let coord = AuthCoordinator(
            client: client,
            store: store,
            attestationProvider: provider,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        try await coord.signOut()
        let req = try #require(await mock.lastRequest())
        #expect(req.url?.absoluteString == "https://auth.catlaser.example/api/v1/auth/sign-out")
        #expect(req.headers["Authorization"] == "Bearer bearer-ml")
        let header = try #require(req.header(DeviceAttestationEncoder.headerName))
        let decoded = try DeviceAttestationEncoder.decodeHeaderValue(header)
        #expect(decoded.binding == .signOut(timestamp: 1_700_000_000))
        #expect(decoded.publicKeySPKI == (try await identity.publicKeySPKI()))
        #expect(try await store.load() == nil)
    }

    @Test
    func requestMagicLinkFailurePropagatesWithoutPersistence() async throws {
        let mock = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 503, headers: [:], body: Data("down".utf8))),
        ])
        let client = AuthClient(config: try makeConfig(), http: mock, clock: { Date() })
        let identity = SoftwareIdentityStore()
        let installID = try await identity.installID()
        let provider = StubDeviceAttestationProvider(
            fingerprint: makeFingerprint(installID: installID),
            identity: identity,
        )
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            attestationProvider: provider,
        )
        do {
            try await coord.requestMagicLink(email: "a@b.com")
            Issue.record("expected error")
        } catch AuthError.serverError {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(try await store.load() == nil)
    }

    @Test
    func providerAttestationFailurePropagates() async throws {
        struct Failing: DeviceAttestationProviding {
            func currentFingerprint() async throws -> DeviceFingerprint {
                throw AuthError.attestationFailed("fingerprint broken")
            }

            func currentAttestation(binding _: AttestationBinding) async throws -> DeviceAttestation {
                throw AuthError.attestationFailed("broken")
            }
        }
        let mock = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: mock, clock: { Date() })
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            attestationProvider: Failing(),
        )
        do {
            try await coord.requestMagicLink(email: "a@b.com")
            Issue.record("expected attestationFailed")
        } catch let AuthError.attestationFailed(msg) {
            #expect(msg == "broken")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await mock.sendCount() == 0)
    }

    @Test
    func requestRejectsEpochZeroClock() async throws {
        // A device that boots without time sync (rare, but possible on
        // locked-down or fresh hardware) will report epoch-0 or earlier.
        // Emitting `req:0` or `req:-42` poisons server-side skew checks,
        // so the coordinator refuses to build an attestation at all.
        try await expectImplausibleClockRejected(
            at: Date(timeIntervalSince1970: 0),
        )
    }

    @Test
    func requestRejectsNegativeClock() async throws {
        try await expectImplausibleClockRejected(
            at: Date(timeIntervalSince1970: -1_000_000),
        )
    }

    @Test
    func requestRejectsClockBeforePlausibleMinimum() async throws {
        // One second before the lower bound (2020-01-01 UTC). A device
        // reporting a timestamp this old has a broken RTC — signing
        // with it would only push the server's near-now skew check into
        // a reject, but we want a clean client-side failure, not a
        // wasted server round-trip.
        let justTooEarly = AuthCoordinator.minPlausibleRequestTimestamp - 1
        try await expectImplausibleClockRejected(
            at: Date(timeIntervalSince1970: TimeInterval(justTooEarly)),
        )
    }

    @Test
    func requestRejectsClockBeyondPlausibleMaximum() async throws {
        // One second past the upper bound (2100-01-01 UTC). Signing
        // attestations for the far future is the whole point of a
        // replay attempt against the skew window — if the attacker can
        // tamper with the clock and exfiltrate the header, they can
        // wait for real time to catch up. Refuse.
        let justTooLate = AuthCoordinator.maxPlausibleRequestTimestamp + 1
        try await expectImplausibleClockRejected(
            at: Date(timeIntervalSince1970: TimeInterval(justTooLate)),
        )
    }

    @Test
    func requestAcceptsClockAtPlausibleBounds() async throws {
        // Both bounds are inclusive — assert the happy path at each
        // edge so we don't regress into rejecting legitimate edge
        // timestamps.
        try await expectPlausibleClockAccepted(
            atUnixSeconds: AuthCoordinator.minPlausibleRequestTimestamp,
        )
        try await expectPlausibleClockAccepted(
            atUnixSeconds: AuthCoordinator.maxPlausibleRequestTimestamp,
        )
    }

    private func expectImplausibleClockRejected(
        at date: Date,
        sourceLocation: SourceLocation = #_sourceLocation,
    ) async throws {
        let mock = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: mock, clock: { Date() })
        let identity = SoftwareIdentityStore()
        let installID = try await identity.installID()
        let provider = StubDeviceAttestationProvider(
            fingerprint: makeFingerprint(installID: installID),
            identity: identity,
        )
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            attestationProvider: provider,
            clock: { date },
        )
        do {
            try await coord.requestMagicLink(email: "a@b.com")
            Issue.record("expected attestationFailed", sourceLocation: sourceLocation)
        } catch let AuthError.attestationFailed(msg) {
            #expect(
                msg.lowercased().contains("clock"),
                "message '\(msg)' did not mention the clock",
                sourceLocation: sourceLocation,
            )
        } catch {
            Issue.record("unexpected error: \(error)", sourceLocation: sourceLocation)
        }
        #expect(await mock.sendCount() == 0, sourceLocation: sourceLocation)
    }

    private func expectPlausibleClockAccepted(
        atUnixSeconds seconds: Int64,
        sourceLocation: SourceLocation = #_sourceLocation,
    ) async throws {
        let mock = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
        ])
        let client = AuthClient(config: try makeConfig(), http: mock, clock: { Date() })
        let identity = SoftwareIdentityStore()
        let installID = try await identity.installID()
        let provider = StubDeviceAttestationProvider(
            fingerprint: makeFingerprint(installID: installID),
            identity: identity,
        )
        let coord = AuthCoordinator(
            client: client,
            store: InMemoryBearerTokenStore(),
            attestationProvider: provider,
            clock: { Date(timeIntervalSince1970: TimeInterval(seconds)) },
        )
        try await coord.requestMagicLink(email: "a@b.com")
        let req = try #require(await mock.lastRequest(), sourceLocation: sourceLocation)
        let header = try #require(
            req.header(DeviceAttestationEncoder.headerName),
            sourceLocation: sourceLocation,
        )
        let decoded = try DeviceAttestationEncoder.decodeHeaderValue(header)
        #expect(
            decoded.binding == .request(timestamp: seconds),
            sourceLocation: sourceLocation,
        )
    }
}
