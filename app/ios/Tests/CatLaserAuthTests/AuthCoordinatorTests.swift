import CatLaserAuthTestSupport
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

private func makeSocialFingerprint(installID: String) -> DeviceFingerprint {
    DeviceFingerprint(
        platform: "ios",
        model: "iPhone15,4",
        systemName: "iOS",
        bundleID: "com.catlaser.app",
        installID: installID,
    )
}

private func makeAttestationProvider(
    identity: any DeviceIdentityStoring,
) async throws -> RecordingAttestationProvider {
    let installID = try await identity.installID()
    let fingerprint = makeSocialFingerprint(installID: installID)
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
        // Social sign-in carries a v4 device attestation whose `bnd`
        // encodes `"sis:<unix_seconds>:<rawNonce>"`. Verify the header
        // is on the wire, its signed message ties to both the clock
        // second (matching the coordinator's clock injection) and the
        // raw nonce we post in the request body, and the cryptographic
        // pieces (fph/pk) were produced by the SE identity we handed
        // the provider.
        let fixedSeconds: Int64 = 1_700_000_000
        let http = MockHTTPClient(outcomes: [
            .response(.json(["user": ["id": "u"]], token: "b")),
        ])
        let client = AuthClient(
            config: try makeConfig(),
            http: http,
            clock: { Date(timeIntervalSince1970: TimeInterval(fixedSeconds)) },
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
            clock: { Date(timeIntervalSince1970: TimeInterval(fixedSeconds)) },
        )

        _ = try await coord.signInWithApple(context: makeContext())

        let req = try #require(await http.lastRequest())
        let header = try #require(req.header(DeviceAttestationEncoder.headerName))
        let decoded = try DeviceAttestationEncoder.decodeHeaderValue(header)
        let body = try #require(req.body)
        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let idToken = parsed?["idToken"] as? [String: Any]
        let rawNonceInBody = try #require(idToken?["nonce"] as? String)
        #expect(
            decoded.binding == .social(timestamp: fixedSeconds, rawNonce: rawNonceInBody),
            "bnd must bind the attestation to the current wall-clock second AND to the raw nonce echoed in the request body",
        )
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
        let fixedSeconds: Int64 = 1_700_000_000
        let http = MockHTTPClient(outcomes: [
            .response(.json(["user": ["id": "u"]], token: "b")),
        ])
        let client = AuthClient(
            config: try makeConfig(),
            http: http,
            clock: { Date(timeIntervalSince1970: TimeInterval(fixedSeconds)) },
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
            clock: { Date(timeIntervalSince1970: TimeInterval(fixedSeconds)) },
        )

        _ = try await coord.signInWithGoogle(context: makeContext())

        let req = try #require(await http.lastRequest())
        let header = try #require(req.header(DeviceAttestationEncoder.headerName))
        let decoded = try DeviceAttestationEncoder.decodeHeaderValue(header)
        let rawNonceSent = try #require((await google.receivedNonces).first)
        #expect(
            decoded.binding == .social(timestamp: fixedSeconds, rawNonce: rawNonceSent),
            "bnd must bind the attestation to the current wall-clock second AND to the raw nonce sent to Google",
        )
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
        let client = AuthClient(
            config: try makeConfig(),
            http: http,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        let session = AuthSession(
            bearerToken: "to-kill",
            user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
            provider: .google,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let store = InMemoryBearerTokenStore(initial: session)
        let identity = SoftwareIdentityStore()
        let attestation = try await makeAttestationProvider(identity: identity)
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: nil,
            googleProvider: nil,
            attestationProvider: attestation,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        try await coord.signOut()
        #expect(try await store.load() == nil)
        let req = try #require(await http.lastRequest())
        #expect(req.url?.absoluteString == "https://auth.example/api/v1/auth/sign-out")
        #expect(req.headers["Authorization"] == "Bearer to-kill")
        let header = try #require(req.header(DeviceAttestationEncoder.headerName))
        let decoded = try DeviceAttestationEncoder.decodeHeaderValue(header)
        #expect(decoded.binding == .signOut(timestamp: 1_700_000_000),
                "sign-out must carry a freshness-bound attestation under the out: tag")
        #expect(decoded.publicKeySPKI == (try await identity.publicKeySPKI()))
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
        let identity = SoftwareIdentityStore()
        let attestation = try await makeAttestationProvider(identity: identity)
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: nil,
            googleProvider: nil,
            attestationProvider: attestation,
        )
        await #expect(throws: AuthError.serverError(status: 500, message: nil)) {
            try await coord.signOut()
        }
        #expect(try await store.load() == nil)
    }

    @Test
    func signOutWithNoSessionIsNoOp() async throws {
        // Cold cache, no attestation provider needed — sign-out must
        // still succeed without prompting or throwing, and must not hit
        // the network.
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
        #expect(try await store.load() == nil)
    }

    @Test
    func signOutWithCachedSessionButNoAttestationProviderThrowsAndWipes() async throws {
        // If the cache has a session — meaning we *would* notify the
        // server — but there's no attestation provider configured, the
        // coordinator must refuse to emit an unsigned sign-out call.
        // Production invariant: every authenticated endpoint carries a
        // device attestation. The local session is still wiped so the
        // user is not left in a stuck "cannot sign out" state.
        let http = MockHTTPClient(outcomes: [])
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
            attestationProvider: nil,
        )
        do {
            try await coord.signOut()
            Issue.record("expected providerUnavailable")
        } catch let AuthError.providerUnavailable(msg) {
            #expect(msg.lowercased().contains("sign-out"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await http.sendCount() == 0)
        #expect(try await store.load() == nil, "local session must be wiped even when the server call is refused")
    }

    @Test
    func signOutAttestationRebuildFailureStillWipesStore() async throws {
        // An attestation-side failure (e.g. an implausible clock or a
        // broken identity store) must not leave the user signed in
        // locally. Sign-out's contract is "after this returns the
        // device is logged out," even on the error path.
        struct Failing: DeviceAttestationProviding {
            func currentFingerprint() async throws -> DeviceFingerprint {
                throw AuthError.attestationFailed("fingerprint broken")
            }

            func currentAttestation(binding _: AttestationBinding) async throws -> DeviceAttestation {
                throw AuthError.attestationFailed("cannot build")
            }
        }
        let http = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let session = AuthSession(
            bearerToken: "t",
            user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
            provider: .apple,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let store = InMemoryBearerTokenStore(initial: session)
        let coord = AuthCoordinator(
            client: client,
            store: store,
            attestationProvider: Failing(),
        )
        do {
            try await coord.signOut()
            Issue.record("expected attestationFailed")
        } catch AuthError.attestationFailed {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await http.sendCount() == 0)
        #expect(try await store.load() == nil)
    }

    // MARK: - deleteAccount

    @Test
    func deleteAccountSendsSignedRequestAndWipesStore() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 200, headers: [:], body: Data())),
        ])
        let client = AuthClient(
            config: try makeConfig(),
            http: http,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        let session = AuthSession(
            bearerToken: "bearer-to-delete",
            user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
            provider: .apple,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let store = InMemoryBearerTokenStore(initial: session)
        let identity = SoftwareIdentityStore()
        let attestation = try await makeAttestationProvider(identity: identity)
        let recorder = RecordingLifecycleObserver()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: nil,
            googleProvider: nil,
            attestationProvider: attestation,
            lifecycleObservers: [recorder],
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        try await coord.deleteAccount()
        #expect(try await store.load() == nil)
        let req = try #require(await http.lastRequest())
        #expect(req.url?.absoluteString == "https://auth.example/api/v1/me/delete")
        #expect(req.headers["Authorization"] == "Bearer bearer-to-delete")
        let header = try #require(req.header(DeviceAttestationEncoder.headerName))
        let decoded = try DeviceAttestationEncoder.decodeHeaderValue(header)
        #expect(
            decoded.binding == .deleteAccount(timestamp: 1_700_000_000),
            "delete-account must carry a freshness-bound attestation under the del: tag",
        )
        #expect(decoded.publicKeySPKI == (try await identity.publicKeySPKI()))
        #expect(
            await recorder.callCount == 1,
            "successful delete-account must notify sign-out observers",
        )
    }

    @Test
    func deleteAccountWithNoSessionThrowsMissingBearer() async throws {
        // Cold cache is the one case where the app must refuse to
        // proceed rather than prompt via the userPresence ACL — the
        // user is mid-destructive-confirmation and an OS-level
        // biometric prompt on top would collide with "are you sure."
        let http = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let store = InMemoryBearerTokenStore()
        let identity = SoftwareIdentityStore()
        let attestation = try await makeAttestationProvider(identity: identity)
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: nil,
            googleProvider: nil,
            attestationProvider: attestation,
        )
        await #expect(throws: AuthError.missingBearerToken) {
            try await coord.deleteAccount()
        }
        #expect(await http.sendCount() == 0, "a cold-cache delete-account must not hit the wire")
    }

    @Test
    func deleteAccountWithNoAttestationProviderThrows() async throws {
        let http = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let session = AuthSession(
            bearerToken: "t",
            user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
            provider: .apple,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let store = InMemoryBearerTokenStore(initial: session)
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: nil,
            googleProvider: nil,
            attestationProvider: nil,
        )
        do {
            try await coord.deleteAccount()
            Issue.record("expected providerUnavailable")
        } catch let AuthError.providerUnavailable(msg) {
            #expect(msg.lowercased().contains("delete"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await http.sendCount() == 0)
        #expect(
            try await store.load() != nil,
            "a failed delete-account must NOT wipe local state — the account still exists server-side",
        )
    }

    @Test
    func deleteAccountServerErrorDoesNotWipeStore() async throws {
        // Unlike sign-out, delete-account is the one destructive call
        // where local state MUST survive a server failure: if the
        // server didn't actually delete the account, wiping local
        // credentials would leave the user unable to retry without
        // re-signing-in from scratch (and without a way to finish
        // the deletion).
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 500, headers: [:], body: Data())),
        ])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let session = AuthSession(
            bearerToken: "t",
            user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
            provider: .apple,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let store = InMemoryBearerTokenStore(initial: session)
        let identity = SoftwareIdentityStore()
        let attestation = try await makeAttestationProvider(identity: identity)
        let recorder = RecordingLifecycleObserver()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: nil,
            googleProvider: nil,
            attestationProvider: attestation,
            lifecycleObservers: [recorder],
        )
        await #expect(throws: AuthError.serverError(status: 500, message: nil)) {
            try await coord.deleteAccount()
        }
        #expect(
            try await store.load() != nil,
            "local credentials must survive a server-side delete failure so the user can retry",
        )
        #expect(
            await recorder.callCount == 0,
            "lifecycle observers must not fire when the deletion didn't actually land",
        )
    }

    @Test
    func googleRawNonceDiffersAcrossCalls() async throws {
        let fixedSeconds: Int64 = 1_700_000_000
        let http = MockHTTPClient(outcomes: [
            .response(.json(["user": ["id": "u"]], token: "b1")),
            .response(.json(["user": ["id": "u"]], token: "b2")),
        ])
        let client = AuthClient(
            config: try makeConfig(),
            http: http,
            clock: { Date(timeIntervalSince1970: TimeInterval(fixedSeconds)) },
        )
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
            clock: { Date(timeIntervalSince1970: TimeInterval(fixedSeconds)) },
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

        // Each attestation must bind to its own (timestamp, rawNonce)
        // pair — swapping a captured first-sign-in header into the
        // second request would fail server-side because the nonce would
        // not match the body (even though the timestamp would).
        let bindings = await attestation.bindingCalls
        #expect(bindings == [
            .social(timestamp: fixedSeconds, rawNonce: received[0]),
            .social(timestamp: fixedSeconds, rawNonce: received[1]),
        ])
    }

    @Test
    func appleRawNonceDiffersAcrossCalls() async throws {
        let fixedSeconds: Int64 = 1_700_000_000
        let http = MockHTTPClient(outcomes: [
            .response(.json(["user": ["id": "u"]], token: "b1")),
            .response(.json(["user": ["id": "u"]], token: "b2")),
        ])
        let client = AuthClient(
            config: try makeConfig(),
            http: http,
            clock: { Date(timeIntervalSince1970: TimeInterval(fixedSeconds)) },
        )
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
            clock: { Date(timeIntervalSince1970: TimeInterval(fixedSeconds)) },
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
            .social(timestamp: fixedSeconds, rawNonce: nonces[0]),
            .social(timestamp: fixedSeconds, rawNonce: nonces[1]),
        ])
    }

    @Test
    func appleSignInRejectsImplausibleClockBeforeBuildingAttestation() async throws {
        // A device with a broken clock (boots before first NTP sync, RTC
        // failure, deliberate tamper) must not silently sign a `sis:`
        // header against a bogus wall-clock second — the server would
        // either reject for skew (best case) or, if the attacker drove
        // the clock into the skew window artificially, accept a
        // replay-friendly timestamp (worst case). The coordinator's
        // clock-plausibility gate refuses to build the attestation at
        // all. Mirrors the magic-link path's clock validation.
        let http = MockHTTPClient(outcomes: [])
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
            clock: { Date(timeIntervalSince1970: 0) },
        )
        do {
            _ = try await coord.signInWithApple(context: makeContext())
            Issue.record("expected attestationFailed for implausible clock")
        } catch let AuthError.attestationFailed(msg) {
            #expect(msg.lowercased().contains("clock"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await http.sendCount() == 0)
        #expect(try await store.load() == nil)
    }

    @Test
    func googleSignInRejectsImplausibleClockBeforeBuildingAttestation() async throws {
        let http = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let google = MockGoogleProvider(outcomes: [.token(ProviderIDToken(token: "idt"))])
        let identity = SoftwareIdentityStore()
        let attestation = try await makeAttestationProvider(identity: identity)
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: nil,
            googleProvider: google,
            attestationProvider: attestation,
            clock: { Date(timeIntervalSince1970: 0) },
        )
        do {
            _ = try await coord.signInWithGoogle(context: makeContext())
            Issue.record("expected attestationFailed for implausible clock")
        } catch let AuthError.attestationFailed(msg) {
            #expect(msg.lowercased().contains("clock"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await http.sendCount() == 0)
        #expect(try await store.load() == nil)
    }

    // MARK: - SessionLifecycleObserver

    @Test
    func signOutNotifiesLifecycleObservers() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 200, headers: [:], body: Data())),
        ])
        let client = AuthClient(
            config: try makeConfig(),
            http: http,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        let session = AuthSession(
            bearerToken: "to-kill",
            user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
            provider: .google,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let store = InMemoryBearerTokenStore(initial: session)
        let identity = SoftwareIdentityStore()
        let attestation = try await makeAttestationProvider(identity: identity)
        let recorder1 = RecordingLifecycleObserver()
        let recorder2 = RecordingLifecycleObserver()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: nil,
            googleProvider: nil,
            attestationProvider: attestation,
            lifecycleObservers: [recorder1, recorder2],
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        try await coord.signOut()
        #expect(await recorder1.callCount == 1)
        #expect(await recorder2.callCount == 1)
    }

    @Test
    func signOutNotifiesLifecycleObserversEvenWhenServerCallFails() async throws {
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
        let identity = SoftwareIdentityStore()
        let attestation = try await makeAttestationProvider(identity: identity)
        let recorder = RecordingLifecycleObserver()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: nil,
            googleProvider: nil,
            attestationProvider: attestation,
            lifecycleObservers: [recorder],
        )
        await #expect(throws: AuthError.serverError(status: 500, message: nil)) {
            try await coord.signOut()
        }
        #expect(await recorder.callCount == 1,
                "observers must fire even when the server revocation fails")
    }

    @Test
    func signOutNotifiesObserversWhenNoSessionCached() async throws {
        let http = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let store = InMemoryBearerTokenStore()
        let recorder = RecordingLifecycleObserver()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: nil,
            googleProvider: nil,
            lifecycleObservers: [recorder],
        )
        try await coord.signOut()
        #expect(await recorder.callCount == 1)
    }

    @Test
    func runtimeRegisteredObserverIsAlsoNotified() async throws {
        let http = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let store = InMemoryBearerTokenStore()
        let coord = AuthCoordinator(
            client: client,
            store: store,
            appleProvider: nil,
            googleProvider: nil,
        )
        let recorder = RecordingLifecycleObserver()
        await coord.addLifecycleObserver(recorder)
        try await coord.signOut()
        #expect(await recorder.callCount == 1)
    }

    // MARK: - handleSessionExpired

    @Test
    func handleSessionExpiredInvalidatesInMemoryCacheViaSessionInvalidating() async throws {
        // `handleSessionExpired()` must drop any in-memory bearer
        // cache so the next authenticated call is forced to re-read
        // the keychain (which, under the production access-control,
        // prompts for re-auth). The persistent keychain row must NOT
        // be deleted — the token is still valid at rest and the user's
        // pairing, push tokens, and other session-scoped state are
        // orthogonal to momentary server-side rejection.
        let http = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let invalidator = TestSessionInvalidatingStore(
            initial: AuthSession(
                bearerToken: "still-on-disk",
                user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
                provider: .magicLink,
                establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            ),
        )
        let coord = AuthCoordinator(
            client: client,
            store: invalidator,
            appleProvider: nil,
            googleProvider: nil,
        )
        await coord.handleSessionExpired()
        #expect(await invalidator.invalidateCount == 1)
        #expect(await invalidator.deleteCount == 0)
        // The underlying stored session is still there — only the
        // in-memory cache was dropped.
        #expect(try await invalidator.load() != nil)
    }

    @Test
    func handleSessionExpiredNotifiesLifecycleObservers() async throws {
        // Observers learn about the expiry so the app can route the
        // user to re-sign-in. The endpoint-store-style observer uses
        // the protocol default (no-op) — but a coordinator observer
        // that overrides `sessionDidExpire` sees exactly one call.
        let http = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let recorder1 = RecordingLifecycleObserver()
        let recorder2 = RecordingLifecycleObserver()
        let defaultObserver = DefaultOnlyLifecycleObserver()
        let coord = AuthCoordinator(
            client: client,
            store: InMemoryBearerTokenStore(),
            appleProvider: nil,
            googleProvider: nil,
            lifecycleObservers: [recorder1, defaultObserver, recorder2],
        )
        await coord.handleSessionExpired()
        #expect(await recorder1.expireCount == 1)
        #expect(await recorder2.expireCount == 1)
        // The observer with only the default `sessionDidExpire`
        // behaves as a no-op — the call is issued but nothing happens.
        // This is exactly the pairing module's posture: a session
        // expiry must not wipe the endpoint keychain row.
        #expect(await defaultObserver.signOutCount == 0)
    }

    @Test
    func handleSessionExpiredDoesNotFireSignOutObservers() async throws {
        // Regression guard: `handleSessionExpired` and `signOut` are
        // distinct flows. Expiring must not collaterally notify
        // sign-out observers, because their contract (wipe the
        // endpoint row, etc.) is wrong for a transient bearer
        // rejection.
        let http = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let recorder = RecordingLifecycleObserver()
        let coord = AuthCoordinator(
            client: client,
            store: InMemoryBearerTokenStore(),
            appleProvider: nil,
            googleProvider: nil,
            lifecycleObservers: [recorder],
        )
        await coord.handleSessionExpired()
        #expect(await recorder.expireCount == 1)
        #expect(await recorder.callCount == 0,
                "sessionDidSignOut must NOT fire for a session expiry")
    }

    @Test
    func handleSessionExpiredOnStoreWithoutSessionInvalidatingIsNoOpOnStore() async throws {
        // A keychain-only bearer store (no in-memory cache) does not
        // conform to `SessionInvalidating`. The coordinator must still
        // complete cleanly — observers still fire — but the
        // invalidate path is skipped because there is nothing to
        // invalidate. This exercises the feature-detection branch.
        let http = MockHTTPClient(outcomes: [])
        let client = AuthClient(config: try makeConfig(), http: http, clock: { Date() })
        let plainStore = InMemoryBearerTokenStore() // Does not conform to SessionInvalidating
        let recorder = RecordingLifecycleObserver()
        let coord = AuthCoordinator(
            client: client,
            store: plainStore,
            appleProvider: nil,
            googleProvider: nil,
            lifecycleObservers: [recorder],
        )
        await coord.handleSessionExpired()
        #expect(await recorder.expireCount == 1)
    }
}

// MARK: - Recording observer

private actor RecordingLifecycleObserver: SessionLifecycleObserver {
    private(set) var callCount: Int = 0
    private(set) var expireCount: Int = 0

    func sessionDidSignOut() async {
        callCount += 1
    }

    func sessionDidExpire() async {
        expireCount += 1
    }
}

/// Observer that does NOT override `sessionDidExpire` — relies on the
/// protocol's default no-op. Exercises the pairing-module-posture
/// branch where a session expiry must not touch orthogonal state.
private actor DefaultOnlyLifecycleObserver: SessionLifecycleObserver {
    private(set) var signOutCount: Int = 0

    func sessionDidSignOut() async {
        signOutCount += 1
    }
}

/// Bearer-token store that also conforms to `SessionInvalidating`
/// so the coordinator's feature-detection branch can be exercised.
/// Records both invalidate and delete call counts separately so tests
/// can assert the coordinator's expiry path invalidates WITHOUT
/// deleting the persisted row.
private actor TestSessionInvalidatingStore: BearerTokenStore, SessionInvalidating {
    private var session: AuthSession?
    private(set) var invalidateCount: Int = 0
    private(set) var deleteCount: Int = 0

    init(initial: AuthSession? = nil) {
        self.session = initial
    }

    func save(_ session: AuthSession) async throws {
        self.session = session
    }

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
