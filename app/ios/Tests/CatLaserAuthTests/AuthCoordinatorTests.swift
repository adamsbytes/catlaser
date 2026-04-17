import Foundation
import Testing

@testable import CatLaserAuth

// MARK: - Mock providers

actor MockAppleProvider: AppleIDTokenProviding {
    enum Outcome: Sendable {
        case token(ProviderIDToken)
        case failure(AuthError)
    }

    private var outcomes: [Outcome]
    private(set) var receivedHashes: [String] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    nonisolated func requestIDToken(
        nonceHash: String,
        context _: ProviderPresentationContext,
    ) async throws -> ProviderIDToken {
        try await consume(nonceHash: nonceHash)
    }

    private func consume(nonceHash: String) throws -> ProviderIDToken {
        receivedHashes.append(nonceHash)
        guard !outcomes.isEmpty else {
            throw AuthError.providerInternal("MockAppleProvider: no outcomes")
        }
        switch outcomes.removeFirst() {
        case let .token(t): return t
        case let .failure(e): throw e
        }
    }
}

actor MockGoogleProvider: GoogleIDTokenProviding {
    enum Outcome: Sendable {
        case token(ProviderIDToken)
        case failure(AuthError)
    }

    private var outcomes: [Outcome]
    private(set) var callCount = 0
    private(set) var receivedNonces: [String] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    nonisolated func requestIDToken(
        rawNonce: String,
        context _: ProviderPresentationContext,
    ) async throws -> ProviderIDToken {
        try await consume(rawNonce: rawNonce)
    }

    private func consume(rawNonce: String) throws -> ProviderIDToken {
        callCount += 1
        receivedNonces.append(rawNonce)
        guard !outcomes.isEmpty else {
            throw AuthError.providerInternal("MockGoogleProvider: no outcomes")
        }
        switch outcomes.removeFirst() {
        case let .token(t): return t
        case let .failure(e): throw e
        }
    }
}

private func makeContext() -> ProviderPresentationContext {
    #if canImport(UIKit) && !os(watchOS)
    return ProviderPresentationContext(viewController: nil)
    #elseif canImport(AppKit)
    return ProviderPresentationContext(window: nil)
    #else
    return ProviderPresentationContext()
    #endif
}

private func makeConfig() throws -> AuthConfig {
    try AuthConfig(
        baseURL: URL(string: "https://auth.example")!,
        appleServiceID: "svc",
        googleClientID: "cid",
        bundleID: "com.catlaser.app",
        universalLinkHost: "link.example",
        universalLinkPath: "/app/magic-link",
        oauthRedirectHosts: ["auth.example"],
    )
}

private func makeSocialFingerprint() -> DeviceFingerprint {
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
        installID: "social-install",
    )
}

private func makeAttestationProvider(
    identity: any DeviceIdentityStoring,
) async throws -> RecordingAttestationProvider {
    let installID = try await identity.installID()
    var fingerprint = makeSocialFingerprint()
    fingerprint = DeviceFingerprint(
        platform: fingerprint.platform,
        model: fingerprint.model,
        systemName: fingerprint.systemName,
        osVersion: fingerprint.osVersion,
        locale: fingerprint.locale,
        timezone: fingerprint.timezone,
        appVersion: fingerprint.appVersion,
        appBuild: fingerprint.appBuild,
        bundleID: fingerprint.bundleID,
        installID: installID,
    )
    return RecordingAttestationProvider(fingerprint: fingerprint, identity: identity)
}

@Suite("AuthCoordinator")
struct AuthCoordinatorTests {
    @Test
    func appleSignInSuccess() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(.json(["user": ["id": "apple-user", "email": "u@apple.example"]], token: "bearer-a")),
        ])
        let client = AuthClient(
            config: try makeConfig(),
            http: http,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        let applied = ProviderIDToken(token: "apple-idt", rawNonce: nil, accessToken: nil)
        let apple = MockAppleProvider(outcomes: [.token(applied)])
        let identity = SoftwareIdentityStore()
        let attestation = try await makeAttestationProvider(identity: identity)
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            nonceGenerator: NonceGenerator(),
            appleProvider: apple,
            googleProvider: nil,
            attestationProvider: attestation,
        )

        let session = try await coord.signInWithApple(context: makeContext())

        #expect(session.bearerToken == "bearer-a")
        #expect(session.user.id == "apple-user")
        #expect(session.provider == .apple)
        #expect(try await store.load() == session)

        // Verify apple received a 64-char hex hash, matching SHA-256 hex output length.
        let hashes = await apple.receivedHashes
        #expect(hashes.count == 1)
        #expect(hashes[0].count == 64)

        // Inspect the HTTP body to confirm rawNonce was forwarded to server (not the hash).
        let body = try #require(await http.lastRequest()?.body)
        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let idToken = parsed?["idToken"] as? [String: Any]
        let nonceSent = idToken?["nonce"] as? String
        #expect(nonceSent != nil)
        #expect(nonceSent != hashes[0], "server must receive rawNonce, NOT the hashed value")
        #expect(nonceSent?.isEmpty == false)
    }

    @Test
    func appleSignInSendsAttestationHeaderBoundToRawNonce() async throws {
        // Social sign-in carries a v3 device attestation whose `bnd`
        // encodes `"sis:<rawNonce>"`. Verify the header is on the wire,
        // its signed message ties to the same raw nonce we post in the
        // request body, and the cryptographic pieces (fph/pk) were
        // produced by the SE identity we handed the provider.
        let http = MockHTTPClient(outcomes: [
            .response(.json(["user": ["id": "u"]], token: "b")),
        ])
        let client = AuthClient(
            config: try makeConfig(),
            http: http,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        let apple = MockAppleProvider(outcomes: [.token(ProviderIDToken(token: "idt"))])
        let identity = SoftwareIdentityStore()
        let attestation = try await makeAttestationProvider(identity: identity)
        let coord = AuthCoordinator(
            client: client,
            store: InMemoryBearerTokenStore(),
            appleProvider: apple,
            googleProvider: nil,
            attestationProvider: attestation,
        )

        _ = try await coord.signInWithApple(context: makeContext())

        let req = try #require(await http.lastRequest())
        let header = try #require(req.header(DeviceAttestationEncoder.headerName))
        let decoded = try DeviceAttestationEncoder.decodeHeaderValue(header)
        let body = try #require(req.body)
        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let idToken = parsed?["idToken"] as? [String: Any]
        let rawNonceInBody = try #require(idToken?["nonce"] as? String)
        #expect(decoded.binding == .social(rawNonce: rawNonceInBody),
                "bnd must bind the attestation to the raw nonce echoed in the request body")
        #expect(decoded.publicKeySPKI == (try await identity.publicKeySPKI()))
        #expect(decoded.fingerprintHash.count == 32)
    }

    @Test
    func appleSignInRequiresAttestationProvider() async throws {
        // Without an attestation provider the coordinator refuses to
        // kick off social sign-in at all — no network call, no key
        // attempt, no state mutation. Mirrors the magic-link contract so
        // every authenticated path carries SE-bound device proof.
        let http = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let apple = MockAppleProvider(outcomes: [.token(ProviderIDToken(token: "idt"))])
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: apple,
            googleProvider: nil,
            attestationProvider: nil,
        )
        do {
            _ = try await coord.signInWithApple(context: makeContext())
            Issue.record("expected providerUnavailable")
        } catch let AuthError.providerUnavailable(msg) {
            #expect(msg.lowercased().contains("attestation"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await http.sendCount() == 0)
        #expect(try await store.load() == nil)
    }

    @Test
    func googleSignInSuccess() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(.json(["user": ["id": "g-user"]], token: "bearer-g")),
        ])
        let client = AuthClient(
            config: try makeConfig(),
            http: http,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        let token = ProviderIDToken(token: "google-idt", rawNonce: nil, accessToken: "atk")
        let google = MockGoogleProvider(outcomes: [.token(token)])
        let identity = SoftwareIdentityStore()
        let attestation = try await makeAttestationProvider(identity: identity)
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: nil,
            googleProvider: google,
            attestationProvider: attestation,
        )

        let session = try await coord.signInWithGoogle(context: makeContext())
        #expect(session.bearerToken == "bearer-g")
        #expect(session.provider == .google)
        #expect(try await store.load() == session)

        // Google OIDC echoes the raw nonce verbatim in the ID token, so the
        // coordinator forwards the same raw value to the server for comparison.
        let nonces = await google.receivedNonces
        #expect(nonces.count == 1)
        #expect(!nonces[0].isEmpty)

        let body = try #require(await http.lastRequest()?.body)
        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let idToken = parsed?["idToken"] as? [String: Any]
        #expect(idToken?["accessToken"] as? String == "atk")
        #expect(idToken?["nonce"] as? String == nonces[0])
    }

    @Test
    func googleSignInSendsAttestationHeaderBoundToRawNonce() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(.json(["user": ["id": "u"]], token: "b")),
        ])
        let client = AuthClient(
            config: try makeConfig(),
            http: http,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        let google = MockGoogleProvider(outcomes: [.token(ProviderIDToken(token: "idt"))])
        let identity = SoftwareIdentityStore()
        let attestation = try await makeAttestationProvider(identity: identity)
        let coord = AuthCoordinator(
            client: client,
            store: InMemoryBearerTokenStore(),
            appleProvider: nil,
            googleProvider: google,
            attestationProvider: attestation,
        )

        _ = try await coord.signInWithGoogle(context: makeContext())

        let req = try #require(await http.lastRequest())
        let header = try #require(req.header(DeviceAttestationEncoder.headerName))
        let decoded = try DeviceAttestationEncoder.decodeHeaderValue(header)
        let rawNonceSent = try #require((await google.receivedNonces).first)
        #expect(decoded.binding == .social(rawNonce: rawNonceSent),
                "bnd must bind the attestation to the raw nonce sent to Google")
        #expect(decoded.publicKeySPKI == (try await identity.publicKeySPKI()))
    }

    @Test
    func googleSignInRequiresAttestationProvider() async throws {
        let http = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let google = MockGoogleProvider(outcomes: [.token(ProviderIDToken(token: "idt"))])
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: nil,
            googleProvider: google,
            attestationProvider: nil,
        )
        do {
            _ = try await coord.signInWithGoogle(context: makeContext())
            Issue.record("expected providerUnavailable")
        } catch let AuthError.providerUnavailable(msg) {
            #expect(msg.lowercased().contains("attestation"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await http.sendCount() == 0)
        #expect(try await store.load() == nil)
    }

    @Test
    func appleMissingProviderThrows() async throws {
        let http = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let identity = SoftwareIdentityStore()
        let attestation = try await makeAttestationProvider(identity: identity)
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: nil,
            googleProvider: nil,
            attestationProvider: attestation,
        )
        do {
            _ = try await coord.signInWithApple(context: makeContext())
            Issue.record("expected error")
        } catch let AuthError.providerUnavailable(msg) {
            #expect(msg.contains("Apple"))
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test
    func googleMissingProviderThrows() async throws {
        let http = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let identity = SoftwareIdentityStore()
        let attestation = try await makeAttestationProvider(identity: identity)
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: nil,
            googleProvider: nil,
            attestationProvider: attestation,
        )
        do {
            _ = try await coord.signInWithGoogle(context: makeContext())
            Issue.record("expected error")
        } catch let AuthError.providerUnavailable(msg) {
            #expect(msg.contains("Google"))
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test
    func applyCancellationPropagatesAndDoesNotPersist() async throws {
        let http = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let apple = MockAppleProvider(outcomes: [.failure(.cancelled)])
        let identity = SoftwareIdentityStore()
        let attestation = try await makeAttestationProvider(identity: identity)
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: apple,
            googleProvider: nil,
            attestationProvider: attestation,
        )

        await #expect(throws: AuthError.cancelled) {
            _ = try await coord.signInWithApple(context: makeContext())
        }
        #expect(try await store.load() == nil)
        #expect(await http.sendCount() == 0)
    }

    @Test
    func googleProviderErrorDoesNotPersist() async throws {
        let http = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let google = MockGoogleProvider(outcomes: [.failure(.providerInternal("GID exploded"))])
        let identity = SoftwareIdentityStore()
        let attestation = try await makeAttestationProvider(identity: identity)
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: nil,
            googleProvider: google,
            attestationProvider: attestation,
        )
        do {
            _ = try await coord.signInWithGoogle(context: makeContext())
            Issue.record("expected error")
        } catch let AuthError.providerInternal(msg) {
            #expect(msg == "GID exploded")
        } catch {
            Issue.record("unexpected: \(error)")
        }
        #expect(try await store.load() == nil)
        #expect(await http.sendCount() == 0)
    }

    @Test
    func serverRejectsAppleCredential() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 401, headers: [:], body: Data("bad token".utf8))),
        ])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let apple = MockAppleProvider(outcomes: [.token(ProviderIDToken(token: "idt"))])
        let identity = SoftwareIdentityStore()
        let attestation = try await makeAttestationProvider(identity: identity)
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: apple,
            googleProvider: nil,
            attestationProvider: attestation,
        )
        do {
            _ = try await coord.signInWithApple(context: makeContext())
            Issue.record("expected failure")
        } catch let AuthError.credentialInvalid(msg) {
            #expect(msg == "bad token")
        } catch {
            Issue.record("unexpected: \(error)")
        }
        #expect(try await store.load() == nil)
    }

    @Test
    func currentSessionLoadsFromStore() async throws {
        let session = AuthSession(
            bearerToken: "persisted",
            user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
            provider: .apple,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let store = InMemoryBearerTokenStore(initial: session)
        let http = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: nil,
            googleProvider: nil,
        )
        #expect(try await coord.currentSession() == session)
    }

    @Test
    func signOutInvalidatesServerAndClearsStore() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 200, headers: [:], body: Data())),
        ])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let session = AuthSession(
            bearerToken: "to-kill",
            user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
            provider: .google,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let store = InMemoryBearerTokenStore(initial: session)
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: nil,
            googleProvider: nil,
        )
        try await coord.signOut()
        #expect(try await store.load() == nil)
        let req = try #require(await http.lastRequest())
        #expect(req.url?.absoluteString == "https://auth.example/api/auth/sign-out")
        #expect(req.headers["Authorization"] == "Bearer to-kill")
    }

    @Test
    func signOutStillClearsStoreOnServerError() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 500, headers: [:], body: Data())),
        ])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let session = AuthSession(
            bearerToken: "t",
            user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
            provider: .google,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let store = InMemoryBearerTokenStore(initial: session)
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: nil,
            googleProvider: nil,
        )
        await #expect(throws: AuthError.serverError(status: 500, message: nil)) {
            try await coord.signOut()
        }
        #expect(try await store.load() == nil)
    }

    @Test
    func signOutWithNoSessionIsNoOp() async throws {
        let http = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: nil,
            googleProvider: nil,
        )
        try await coord.signOut()
        #expect(await http.sendCount() == 0)
    }

    @Test
    func googleRawNonceDiffersAcrossCalls() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(.json(["user": ["id": "u"]], token: "b1")),
            .response(.json(["user": ["id": "u"]], token: "b2")),
        ])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let google = MockGoogleProvider(outcomes: [
            .token(ProviderIDToken(token: "idt1", rawNonce: nil, accessToken: nil)),
            .token(ProviderIDToken(token: "idt2", rawNonce: nil, accessToken: nil)),
        ])
        let identity = SoftwareIdentityStore()
        let attestation = try await makeAttestationProvider(identity: identity)
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: nil,
            googleProvider: google,
            attestationProvider: attestation,
        )
        _ = try await coord.signInWithGoogle(context: makeContext())
        _ = try await coord.signInWithGoogle(context: makeContext())

        let received = await google.receivedNonces
        #expect(received.count == 2)
        #expect(received[0] != received[1], "each sign-in must use a fresh nonce")

        let bodies = await http.requests().map(\.body)
        let nonces = bodies.compactMap { body -> String? in
            guard let body else { return nil }
            let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let idToken = obj?["idToken"] as? [String: Any]
            return idToken?["nonce"] as? String
        }
        #expect(nonces.count == 2)
        #expect(nonces[0] != nonces[1])
        // The nonce sent to the provider equals the nonce forwarded to the
        // server (Google echoes the raw value — no hashing on this path).
        #expect(nonces[0] == received[0])
        #expect(nonces[1] == received[1])

        // Each attestation must bind to its own raw nonce — swapping a
        // captured first-sign-in header into the second request would
        // fail server-side because the bnd would not match the nonce in
        // the body.
        let bindings = await attestation.bindingCalls
        #expect(bindings == [
            .social(rawNonce: received[0]),
            .social(rawNonce: received[1]),
        ])
    }

    @Test
    func appleRawNonceDiffersAcrossCalls() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(.json(["user": ["id": "u"]], token: "b1")),
            .response(.json(["user": ["id": "u"]], token: "b2")),
        ])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let apple = MockAppleProvider(outcomes: [
            .token(ProviderIDToken(token: "idt1")),
            .token(ProviderIDToken(token: "idt2")),
        ])
        let identity = SoftwareIdentityStore()
        let attestation = try await makeAttestationProvider(identity: identity)
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: apple,
            googleProvider: nil,
            attestationProvider: attestation,
        )
        _ = try await coord.signInWithApple(context: makeContext())
        _ = try await coord.signInWithApple(context: makeContext())

        let hashes = await apple.receivedHashes
        #expect(hashes.count == 2)
        #expect(hashes[0] != hashes[1], "each sign-in must use a fresh nonce")

        let bodies = await http.requests().map(\.body)
        let nonces = bodies.compactMap { body -> String? in
            guard let body else { return nil }
            let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let idToken = obj?["idToken"] as? [String: Any]
            return idToken?["nonce"] as? String
        }
        #expect(nonces.count == 2)
        #expect(nonces[0] != nonces[1])

        let bindings = await attestation.bindingCalls
        #expect(bindings == [
            .social(rawNonce: nonces[0]),
            .social(rawNonce: nonces[1]),
        ])
    }
}
