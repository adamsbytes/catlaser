import Foundation
import Testing

@testable import CatLaserAuth

private func makeConfig() throws -> AuthConfig {
    try AuthConfig(
        baseURL: URL(string: "https://auth.catlaser.example")!,
        appleServiceID: "svc",
        googleClientID: "cid",
    )
}

/// Records every fingerprint-header request, and asserts that all headers
/// match — the crux of the phishing defence is that request-time and
/// completion-time headers are byte-identical.
actor RecordingFingerprintProvider: DeviceFingerprintProviding {
    let fingerprint: DeviceFingerprint
    private(set) var headerCalls: [String] = []
    private(set) var fingerprintCalls = 0

    init(fingerprint: DeviceFingerprint) {
        self.fingerprint = fingerprint
    }

    nonisolated func currentFingerprint() async throws -> DeviceFingerprint {
        await recordFingerprintCall()
        return fingerprint
    }

    private func recordFingerprintCall() {
        fingerprintCalls += 1
    }

    nonisolated func currentFingerprintHeader() async throws -> String {
        let header = try DeviceFingerprintEncoder.encodeHeaderValue(fingerprint)
        await recordHeaderCall(header)
        return header
    }

    private func recordHeaderCall(_ header: String) {
        headerCalls.append(header)
    }
}

private func makeFingerprint(installID: String = "test-install") -> DeviceFingerprint {
    DeviceFingerprint(
        platform: "ios",
        model: "iPhone15,4",
        systemName: "iOS",
        osVersion: "17.4",
        locale: "en_US",
        timezone: "UTC",
        appVersion: "1.0.0",
        appBuild: "1",
        bundleID: "com.catlaser.app",
        installID: installID,
    )
}

@Suite("AuthCoordinator magic link")
struct MagicLinkCoordinatorTests {
    @Test
    func requestMagicLinkSendsFingerprintHeader() async throws {
        let mock = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
        ])
        let client = AuthClient(
            config: try makeConfig(),
            http: mock,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        let fingerprint = makeFingerprint()
        let provider = RecordingFingerprintProvider(fingerprint: fingerprint)
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            fingerprintProvider: provider,
            magicLinkCallbackURL: "https://auth.catlaser.example/api/auth/magic-link/verify",
        )

        try await coord.requestMagicLink(email: "cat@example.com")

        let req = try #require(await mock.lastRequest())
        let header = req.header(DeviceFingerprintEncoder.headerName)
        let expected = try DeviceFingerprintEncoder.encodeHeaderValue(fingerprint)
        #expect(header == expected)
        #expect(await provider.headerCalls.count == 1)
        // No session persisted at request time (link hasn't been completed).
        #expect(try await store.load() == nil)
    }

    @Test
    func completeMagicLinkFromURLExchangesAndPersists() async throws {
        let mock = MockHTTPClient(outcomes: [
            .response(.json(["user": ["id": "u-ml", "email": "cat@example.com", "emailVerified": true]], token: "bearer-ml")),
        ])
        let client = AuthClient(
            config: try makeConfig(),
            http: mock,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        let fingerprint = makeFingerprint()
        let provider = RecordingFingerprintProvider(fingerprint: fingerprint)
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            fingerprintProvider: provider,
        )
        let url = URL(string: "https://auth.catlaser.example/api/auth/magic-link/verify?token=opaque123")!
        let session = try await coord.completeMagicLink(url: url)

        #expect(session.bearerToken == "bearer-ml")
        #expect(session.provider == .magicLink)
        #expect(session.user.id == "u-ml")
        #expect(try await store.load() == session)

        let req = try #require(await mock.lastRequest())
        #expect(req.url?.absoluteString == "https://auth.catlaser.example/api/auth/magic-link/verify?token=opaque123")
        #expect(req.header(DeviceFingerprintEncoder.headerName)
            == (try DeviceFingerprintEncoder.encodeHeaderValue(fingerprint)))
    }

    @Test
    func requestAndCompleteUseIdenticalFingerprintHeader() async throws {
        let mock = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
            .response(.json(["user": ["id": "u", "emailVerified": true]], token: "tok")),
        ])
        let client = AuthClient(
            config: try makeConfig(),
            http: mock,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        let fingerprint = makeFingerprint()
        let provider = RecordingFingerprintProvider(fingerprint: fingerprint)
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            fingerprintProvider: provider,
        )

        try await coord.requestMagicLink(email: "cat@example.com")
        _ = try await coord.completeMagicLink(url: URL(string: "https://auth.catlaser.example/api/auth/magic-link/verify?token=T")!)

        let requests = await mock.requests()
        #expect(requests.count == 2)
        let requestHeader = requests[0].header(DeviceFingerprintEncoder.headerName)
        let completeHeader = requests[1].header(DeviceFingerprintEncoder.headerName)
        #expect(requestHeader != nil)
        #expect(requestHeader == completeHeader, "same device ⇒ identical fingerprint header")
    }

    @Test
    func missingFingerprintProviderBlocksRequest() async throws {
        let mock = MockHTTPClient(outcomes: [])
        let client = AuthClient(
            config: try makeConfig(),
            http: mock,
            clock: { Date() },
        )
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
        )
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
    func missingFingerprintProviderBlocksCompletion() async throws {
        let mock = MockHTTPClient(outcomes: [])
        let client = AuthClient(
            config: try makeConfig(),
            http: mock,
            clock: { Date() },
        )
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
        )
        let url = URL(string: "https://auth.catlaser.example/api/auth/magic-link/verify?token=T")!
        await #expect(throws: (any Error).self) {
            _ = try await coord.completeMagicLink(url: url)
        }
        #expect(await mock.sendCount() == 0)
        #expect(try await store.load() == nil)
    }

    @Test
    func completeWithBadURLDoesNotHitNetworkOrStore() async throws {
        let mock = MockHTTPClient(outcomes: [])
        let client = AuthClient(
            config: try makeConfig(),
            http: mock,
            clock: { Date() },
        )
        let provider = RecordingFingerprintProvider(fingerprint: makeFingerprint())
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            fingerprintProvider: provider,
        )
        let url = URL(string: "https://evil.example/api/auth/magic-link/verify?token=T")!
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
        // If the user had an existing session and the magic-link completion
        // fails (device mismatch etc.), we must NOT clobber the stored
        // session. Coordinator only persists on success.
        let body = try JSONSerialization.data(withJSONObject: ["code": "DEVICE_MISMATCH"])
        let mock = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 403, headers: [:], body: body)),
        ])
        let client = AuthClient(
            config: try makeConfig(),
            http: mock,
            clock: { Date() },
        )
        let existing = AuthSession(
            bearerToken: "still-valid",
            user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
            provider: .apple,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let store = InMemoryBearerTokenStore(initial: existing)
        let provider = RecordingFingerprintProvider(fingerprint: makeFingerprint())
        let coord = AuthCoordinator(
            client: client,
            store: store,
            fingerprintProvider: provider,
        )
        let url = URL(string: "https://auth.catlaser.example/api/auth/magic-link/verify?token=T")!
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
        let client = AuthClient(config: try makeConfig(), http: mock, clock: { Date() })
        let session = AuthSession(
            bearerToken: "bearer-ml",
            user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
            provider: .magicLink,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let store = InMemoryBearerTokenStore(initial: session)
        let coord = AuthCoordinator(client: client, store: store)
        try await coord.signOut()
        let req = try #require(await mock.lastRequest())
        #expect(req.url?.absoluteString == "https://auth.catlaser.example/api/auth/sign-out")
        #expect(req.headers["Authorization"] == "Bearer bearer-ml")
        #expect(try await store.load() == nil)
    }

    @Test
    func requestMagicLinkFailurePropagatesWithoutPersistence() async throws {
        let mock = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 503, headers: [:], body: Data("down".utf8))),
        ])
        let client = AuthClient(config: try makeConfig(), http: mock, clock: { Date() })
        let provider = RecordingFingerprintProvider(fingerprint: makeFingerprint())
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            fingerprintProvider: provider,
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
    func providerFingerprintFailurePropagates() async throws {
        struct Failing: DeviceFingerprintProviding {
            func currentFingerprint() async throws -> DeviceFingerprint {
                throw AuthError.fingerprintCaptureFailed("broken")
            }
        }
        let mock = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: mock, clock: { Date() })
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            fingerprintProvider: Failing(),
        )
        do {
            try await coord.requestMagicLink(email: "a@b.com")
            Issue.record("expected fingerprintCaptureFailed")
        } catch let AuthError.fingerprintCaptureFailed(msg) {
            #expect(msg == "broken")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await mock.sendCount() == 0)
    }
}
