import Foundation
import Testing

@testable import CatLaserApp
@testable import CatLaserAuth

// MARK: - Helpers

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

private func makeContext() -> ProviderPresentationContext {
    #if canImport(UIKit) && !os(watchOS)
    return ProviderPresentationContext(viewController: nil)
    #elseif canImport(AppKit)
    return ProviderPresentationContext(window: nil)
    #else
    return ProviderPresentationContext()
    #endif
}

private func makeFingerprint(installID: String) -> DeviceFingerprint {
    DeviceFingerprint(
        platform: "ios",
        model: "iPhone15,4",
        systemName: "iOS",
        bundleID: "com.catlaser.app",
        installID: installID,
    )
}

private struct Harness {
    let viewModel: SignInViewModel
    let coordinator: AuthCoordinator
    let http: MockHTTPClient
    let store: InMemoryBearerTokenStore
    let apple: MockAppleProvider?
    let google: MockGoogleProvider?
}

private func makeHarness(
    http: MockHTTPClient,
    apple: MockAppleProvider? = nil,
    google: (any GoogleIDTokenProviding)? = nil,
    store: InMemoryBearerTokenStore = InMemoryBearerTokenStore(),
    clock: @escaping @Sendable () -> Date = {
        Date(timeIntervalSince1970: 1_700_000_000)
    },
    initialPhase: SignInPhase = .idle,
) async throws -> Harness {
    let config = try makeConfig()
    let client = AuthClient(config: config, http: http, clock: clock)
    let identity = SoftwareIdentityStore()
    let installID = try await identity.installID()
    let attestation = StubDeviceAttestationProvider(
        fingerprint: makeFingerprint(installID: installID),
        identity: identity,
    )
    let coordinator = AuthCoordinator(
        client: client,
        store: store,
        appleProvider: apple,
        googleProvider: google,
        attestationProvider: attestation,
        clock: clock,
    )
    let viewModel = await MainActor.run {
        SignInViewModel(coordinator: coordinator, initialPhase: initialPhase)
    }
    return Harness(
        viewModel: viewModel,
        coordinator: coordinator,
        http: http,
        store: store,
        apple: apple,
        google: google as? MockGoogleProvider,
    )
}

// MARK: - Suite

@MainActor
@Suite("SignInViewModel")
struct SignInViewModelTests {
    // MARK: Initial state

    @Test
    func initialStateIsIdleWithEmptyEmail() async throws {
        let harness = try await makeHarness(http: MockHTTPClient())
        #expect(harness.viewModel.phase == .idle)
        #expect(harness.viewModel.emailInput == "")
        #expect(!harness.viewModel.emailSheetPresented)
        #expect(!harness.viewModel.isEmailInputValid)
        #expect(!harness.viewModel.canRequestMagicLink)
        #expect(harness.viewModel.currentErrorMessage == nil)
    }

    // MARK: Apple sign-in

    @Test
    func appleSignInSucceedsAndPersistsSession() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(.json(["user": ["id": "u-apple"]], token: "bearer-a")),
        ])
        let apple = MockAppleProvider(outcomes: [
            .token(ProviderIDToken(token: "idt")),
        ])
        let harness = try await makeHarness(http: http, apple: apple)

        await harness.viewModel.signInWithApple(context: makeContext())

        guard case let .succeeded(session) = harness.viewModel.phase else {
            Issue.record("expected .succeeded, got \(harness.viewModel.phase)")
            return
        }
        #expect(session.bearerToken == "bearer-a")
        #expect(session.provider == .apple)
        #expect(try await harness.store.load() == session)
    }

    @Test
    func appleCancellationReturnsToIdleWithoutError() async throws {
        let apple = MockAppleProvider(outcomes: [.failure(.cancelled)])
        let harness = try await makeHarness(http: MockHTTPClient(), apple: apple)

        await harness.viewModel.signInWithApple(context: makeContext())

        #expect(harness.viewModel.phase == .idle)
        #expect(harness.viewModel.currentErrorMessage == nil)
        #expect(try await harness.store.load() == nil)
    }

    @Test
    func appleServerErrorLandsOnFailedPhase() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 500, headers: [:], body: Data())),
        ])
        let apple = MockAppleProvider(outcomes: [
            .token(ProviderIDToken(token: "idt")),
        ])
        let harness = try await makeHarness(http: http, apple: apple)

        await harness.viewModel.signInWithApple(context: makeContext())

        guard case let .failed(error) = harness.viewModel.phase else {
            Issue.record("expected .failed, got \(harness.viewModel.phase)")
            return
        }
        #expect(error == AuthError.serverError(status: 500, message: nil))
        #expect(try await harness.store.load() == nil)
    }

    @Test
    func appleMissingProviderLandsOnFailedPhase() async throws {
        // No apple provider wired. VM surfaces .providerUnavailable
        // from the coordinator as .failed and leaves the store empty.
        let harness = try await makeHarness(http: MockHTTPClient(), apple: nil)

        await harness.viewModel.signInWithApple(context: makeContext())

        guard case let .failed(error) = harness.viewModel.phase else {
            Issue.record("expected .failed, got \(harness.viewModel.phase)")
            return
        }
        if case .providerUnavailable = error {
            // expected
        } else {
            Issue.record("expected .providerUnavailable, got \(error)")
        }
    }

    // MARK: Google sign-in

    @Test
    func googleSignInSucceedsAndPersistsSession() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(.json(["user": ["id": "u-g"]], token: "bearer-g")),
        ])
        let google = MockGoogleProvider(outcomes: [
            .token(ProviderIDToken(token: "idt-g", accessToken: "atk")),
        ])
        let harness = try await makeHarness(http: http, google: google)

        await harness.viewModel.signInWithGoogle(context: makeContext())

        guard case let .succeeded(session) = harness.viewModel.phase else {
            Issue.record("expected .succeeded, got \(harness.viewModel.phase)")
            return
        }
        #expect(session.bearerToken == "bearer-g")
        #expect(session.provider == .google)
        #expect(try await harness.store.load() == session)
    }

    @Test
    func googleCancellationReturnsToIdleWithoutError() async throws {
        let google = MockGoogleProvider(outcomes: [.failure(.cancelled)])
        let harness = try await makeHarness(http: MockHTTPClient(), google: google)

        await harness.viewModel.signInWithGoogle(context: makeContext())

        #expect(harness.viewModel.phase == .idle)
        #expect(harness.viewModel.currentErrorMessage == nil)
    }

    @Test
    func googleProviderInternalErrorLandsOnFailedPhase() async throws {
        let google = MockGoogleProvider(outcomes: [
            .failure(.providerInternal("exploded")),
        ])
        let harness = try await makeHarness(http: MockHTTPClient(), google: google)

        await harness.viewModel.signInWithGoogle(context: makeContext())

        guard case let .failed(error) = harness.viewModel.phase else {
            Issue.record("expected .failed, got \(harness.viewModel.phase)")
            return
        }
        #expect(error == AuthError.providerInternal("exploded"))
        #expect(harness.viewModel.currentErrorMessage != nil)
    }

    // MARK: Magic link — request

    @Test
    func magicLinkRequestSucceedsAndLandsOnEmailSent() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
        ])
        let harness = try await makeHarness(http: http)
        harness.viewModel.emailInput = "cat@example.com"
        harness.viewModel.emailSheetPresented = true

        await harness.viewModel.requestMagicLink()

        #expect(harness.viewModel.phase == .emailSent("cat@example.com"))
        #expect(!harness.viewModel.emailSheetPresented, "sheet must close after a successful send")
        #expect(await harness.http.sendCount() == 1)
    }

    @Test
    func magicLinkRequestNormalizesSurroundingWhitespace() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
        ])
        let harness = try await makeHarness(http: http)
        harness.viewModel.emailInput = "  cat@example.com  \n"

        await harness.viewModel.requestMagicLink()

        // Normalized (trimmed) form is what the phase and the HTTP
        // body carry.
        #expect(harness.viewModel.phase == .emailSent("cat@example.com"))
        let req = try #require(await harness.http.lastRequest())
        let body = try #require(req.body)
        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(parsed?["email"] as? String == "cat@example.com")
    }

    @Test
    func magicLinkRequestRejectsInvalidEmailWithoutNetwork() async throws {
        let http = MockHTTPClient()
        let harness = try await makeHarness(http: http)
        harness.viewModel.emailInput = "not-an-email"

        await harness.viewModel.requestMagicLink()

        #expect(harness.viewModel.phase == .failed(.invalidEmail))
        #expect(await http.sendCount() == 0)
    }

    @Test
    func magicLinkRequestRejectsEmptyEmailWithoutNetwork() async throws {
        let http = MockHTTPClient()
        let harness = try await makeHarness(http: http)
        harness.viewModel.emailInput = "   "

        await harness.viewModel.requestMagicLink()

        #expect(harness.viewModel.phase == .failed(.invalidEmail))
        #expect(await http.sendCount() == 0)
    }

    @Test
    func magicLinkRequestServerErrorShowsFailedAndKeepsSheetOpen() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 503, headers: [:], body: Data("down".utf8))),
        ])
        let harness = try await makeHarness(http: http)
        harness.viewModel.emailInput = "cat@example.com"
        harness.viewModel.emailSheetPresented = true

        await harness.viewModel.requestMagicLink()

        guard case let .failed(error) = harness.viewModel.phase else {
            Issue.record("expected .failed, got \(harness.viewModel.phase)")
            return
        }
        #expect(error == AuthError.serverError(status: 503, message: "down"))
        #expect(harness.viewModel.emailSheetPresented, "sheet stays open on failure so user can correct and retry")
    }

    // MARK: Magic link — completion (Universal Link)

    @Test
    func completeMagicLinkFromIdleSucceedsAndPersists() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(.json(
                ["user": ["id": "u-ml", "email": "cat@example.com", "emailVerified": true]],
                token: "bearer-ml",
            )),
        ])
        let harness = try await makeHarness(http: http)
        let url = URL(string: "https://link.example/app/magic-link?token=opaque")!

        await harness.viewModel.completeMagicLink(url: url)

        guard case let .succeeded(session) = harness.viewModel.phase else {
            Issue.record("expected .succeeded, got \(harness.viewModel.phase)")
            return
        }
        #expect(session.provider == .magicLink)
        #expect(session.bearerToken == "bearer-ml")
        #expect(try await harness.store.load() == session)
    }

    @Test
    func completeMagicLinkFromEmailSentProceeds() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(.json(["user": ["id": "u-ml"]], token: "bearer-ml")),
        ])
        let harness = try await makeHarness(
            http: http,
            initialPhase: .emailSent("cat@example.com"),
        )
        let url = URL(string: "https://link.example/app/magic-link?token=t123")!

        await harness.viewModel.completeMagicLink(url: url)

        if case .succeeded = harness.viewModel.phase {
            // expected
        } else {
            Issue.record("expected .succeeded, got \(harness.viewModel.phase)")
        }
    }

    @Test
    func completeMagicLinkFromFailedPhaseAllowsRecovery() async throws {
        // A prior failure shouldn't block a valid link-completion. The
        // VM treats `.failed` as recoverable (the user might have tapped
        // the link *after* closing the error banner).
        let http = MockHTTPClient(outcomes: [
            .response(.json(["user": ["id": "u"]], token: "b")),
        ])
        let harness = try await makeHarness(
            http: http,
            initialPhase: .failed(.network(NetworkFailure("prior"))),
        )
        let url = URL(string: "https://link.example/app/magic-link?token=t")!

        await harness.viewModel.completeMagicLink(url: url)

        if case .succeeded = harness.viewModel.phase {
            // expected
        } else {
            Issue.record("expected .succeeded, got \(harness.viewModel.phase)")
        }
    }

    @Test
    func completeMagicLinkWithWrongHostFails() async throws {
        let http = MockHTTPClient()
        let harness = try await makeHarness(http: http)
        let url = URL(string: "https://evil.example/app/magic-link?token=t")!

        await harness.viewModel.completeMagicLink(url: url)

        guard case let .failed(error) = harness.viewModel.phase else {
            Issue.record("expected .failed, got \(harness.viewModel.phase)")
            return
        }
        if case .invalidMagicLink = error {
            // expected
        } else {
            Issue.record("expected .invalidMagicLink, got \(error)")
        }
        #expect(await http.sendCount() == 0, "bad URL must not hit the network")
    }

    @Test
    func completeMagicLinkWithNonHttpsSchemeFails() async throws {
        // MagicLinkCallback rejects http:// — but the URL still must
        // construct, so we use a URL with a recognised scheme other
        // than https. Verifies an attacker-controlled scheme (even
        // with the right host) is rejected at the callback boundary.
        let http = MockHTTPClient()
        let harness = try await makeHarness(http: http)
        let url = URL(string: "http://link.example/app/magic-link?token=t")!

        await harness.viewModel.completeMagicLink(url: url)

        if case .failed(.invalidMagicLink) = harness.viewModel.phase {
            // expected
        } else {
            Issue.record("expected .failed(.invalidMagicLink), got \(harness.viewModel.phase)")
        }
        #expect(await http.sendCount() == 0)
    }

    @Test
    func completeMagicLinkWithMissingTokenFails() async throws {
        let harness = try await makeHarness(http: MockHTTPClient())
        let url = URL(string: "https://link.example/app/magic-link")!

        await harness.viewModel.completeMagicLink(url: url)

        if case .failed(.invalidMagicLink) = harness.viewModel.phase {
            // expected
        } else {
            Issue.record("expected .failed(.invalidMagicLink), got \(harness.viewModel.phase)")
        }
    }

    @Test
    func completeMagicLinkWithDuplicateTokenParamFails() async throws {
        // An attacker crafting a link with two `token=` values is one of
        // the classic parameter-pollution tricks. MagicLinkCallback
        // rejects it outright; verify the VM surfaces that rejection.
        let harness = try await makeHarness(http: MockHTTPClient())
        let url = URL(string: "https://link.example/app/magic-link?token=good&token=evil")!

        await harness.viewModel.completeMagicLink(url: url)

        if case .failed(.invalidMagicLink) = harness.viewModel.phase {
            // expected
        } else {
            Issue.record("expected .failed(.invalidMagicLink), got \(harness.viewModel.phase)")
        }
    }

    @Test
    func completeMagicLinkFromSucceededIsNoOp() async throws {
        let http = MockHTTPClient()
        let existingSession = AuthSession(
            bearerToken: "kept",
            user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
            provider: .apple,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let harness = try await makeHarness(
            http: http,
            initialPhase: .succeeded(existingSession),
        )
        let url = URL(string: "https://link.example/app/magic-link?token=t")!

        await harness.viewModel.completeMagicLink(url: url)

        #expect(harness.viewModel.phase == .succeeded(existingSession))
        #expect(await http.sendCount() == 0, "already-signed-in VM must ignore stray link callbacks")
    }

    @Test
    func completeMagicLinkFromVerifyingPhaseIsNoOp() async throws {
        // Two Universal Link callbacks arriving in close succession
        // (e.g. scene restoration firing twice) must not overlap. The
        // second one is dropped.
        let http = MockHTTPClient()
        let harness = try await makeHarness(
            http: http,
            initialPhase: .verifyingMagicLink,
        )
        let url = URL(string: "https://link.example/app/magic-link?token=t")!

        await harness.viewModel.completeMagicLink(url: url)

        #expect(harness.viewModel.phase == .verifyingMagicLink)
        #expect(await http.sendCount() == 0)
    }

    // MARK: Reentrancy lock

    @Test
    func appleInFlightRejectsConcurrentGoogleTap() async throws {
        // A long-running Apple sign-in must block a simultaneous
        // Google tap. We use a PausingGoogleProvider to force Apple
        // into a busy state first — but simpler: simulate the busy
        // phase directly via the internal initializer and verify the
        // guard rejects the second call without touching the provider.
        let google = MockGoogleProvider(outcomes: [
            .token(ProviderIDToken(token: "idt", accessToken: nil)),
        ])
        let harness = try await makeHarness(
            http: MockHTTPClient(),
            google: google,
            initialPhase: .authenticating(.apple),
        )

        await harness.viewModel.signInWithGoogle(context: makeContext())

        #expect(harness.viewModel.phase == .authenticating(.apple))
        // Provider never called, no network traffic.
        let nonces = await google.receivedNonces
        #expect(nonces.isEmpty)
    }

    @Test
    func googleInFlightRejectsConcurrentMagicLinkRequest() async throws {
        // Mid-Google sign-in, the user shouldn't be able to kick off a
        // magic-link request. The guard drops the call on the floor.
        let http = MockHTTPClient()
        let harness = try await makeHarness(
            http: http,
            initialPhase: .authenticating(.google),
        )
        harness.viewModel.emailInput = "cat@example.com"

        await harness.viewModel.requestMagicLink()

        #expect(harness.viewModel.phase == .authenticating(.google))
        #expect(await http.sendCount() == 0)
    }

    @Test
    func liveReentrancyLockHoldsUnderActualInFlightCall() async throws {
        // End-to-end exercise of the lock: start a genuine Google
        // sign-in that blocks on its provider, observe the VM enter
        // `.authenticating(.google)`, attempt an Apple sign-in, and
        // verify the Apple provider is never called. Then release the
        // Google provider and confirm the VM lands cleanly on
        // `.succeeded`.
        let http = MockHTTPClient(outcomes: [
            .response(.json(["user": ["id": "u"]], token: "bearer")),
        ])
        let pausing = PausingGoogleProvider()
        let apple = MockAppleProvider(outcomes: [
            .token(ProviderIDToken(token: "idt-a")),
        ])
        let harness = try await makeHarness(
            http: http,
            apple: apple,
            google: pausing,
        )

        let googleTask = Task { @MainActor in
            await harness.viewModel.signInWithGoogle(context: makeContext())
        }

        // Wait until the pausing provider is actually in its blocking
        // await. A deterministic poll beats a fixed sleep: we yield
        // until the provider reports it started.
        while !(await pausing.hasStarted()) {
            await Task.yield()
        }
        #expect(harness.viewModel.phase == .authenticating(.google))

        await harness.viewModel.signInWithApple(context: makeContext())

        #expect(
            harness.viewModel.phase == .authenticating(.google),
            "Apple tap must not override the in-flight Google sign-in",
        )
        #expect(await apple.receivedHashes.isEmpty,
                "Apple provider must never have been called")

        await pausing.resume(with: ProviderIDToken(token: "idt-g", accessToken: nil))
        await googleTask.value

        if case .succeeded = harness.viewModel.phase {
            // expected
        } else {
            Issue.record("expected .succeeded, got \(harness.viewModel.phase)")
        }
    }

    // MARK: Dismiss & reset

    @Test
    func dismissErrorFromFailedReturnsToIdle() async throws {
        let harness = try await makeHarness(
            http: MockHTTPClient(),
            initialPhase: .failed(.invalidEmail),
        )

        harness.viewModel.dismissError()

        #expect(harness.viewModel.phase == .idle)
        #expect(harness.viewModel.currentErrorMessage == nil)
    }

    @Test
    func dismissErrorFromIdleIsNoOp() async throws {
        let harness = try await makeHarness(http: MockHTTPClient())
        harness.viewModel.dismissError()
        #expect(harness.viewModel.phase == .idle)
    }

    @Test
    func useDifferentEmailClearsInputAndReturnsToIdle() async throws {
        let harness = try await makeHarness(
            http: MockHTTPClient(),
            initialPhase: .emailSent("cat@example.com"),
        )
        harness.viewModel.emailInput = "cat@example.com"

        harness.viewModel.useDifferentEmail()

        #expect(harness.viewModel.phase == .idle)
        #expect(harness.viewModel.emailInput == "")
    }

    @Test
    func useDifferentEmailOnlyActsFromEmailSent() async throws {
        let harness = try await makeHarness(
            http: MockHTTPClient(),
            initialPhase: .idle,
        )
        harness.viewModel.emailInput = "do-not-wipe@example.com"

        harness.viewModel.useDifferentEmail()

        #expect(harness.viewModel.phase == .idle)
        #expect(harness.viewModel.emailInput == "do-not-wipe@example.com",
                "invocation from non-emailSent phase must not wipe the input")
    }

    // MARK: Resend

    @Test
    func resendMagicLinkFromEmailSentSucceedsAndStaysThere() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
        ])
        let harness = try await makeHarness(
            http: http,
            initialPhase: .emailSent("cat@example.com"),
        )

        await harness.viewModel.resendMagicLink()

        #expect(harness.viewModel.phase == .emailSent("cat@example.com"))
        #expect(await http.sendCount() == 1)
        let req = try #require(await http.lastRequest())
        let body = try #require(req.body)
        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(parsed?["email"] as? String == "cat@example.com",
                "resend must use the phase-captured address, not emailInput")
    }

    @Test
    func resendMagicLinkIgnoresEmailInputEdits() async throws {
        // User edits `emailInput` behind the "check your email" screen
        // (a text field could be left focused). Resend must still
        // target the original address, not the edited one.
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
        ])
        let harness = try await makeHarness(
            http: http,
            initialPhase: .emailSent("first@example.com"),
        )
        harness.viewModel.emailInput = "attacker@example.com"

        await harness.viewModel.resendMagicLink()

        let req = try #require(await http.lastRequest())
        let body = try #require(req.body)
        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(parsed?["email"] as? String == "first@example.com")
        #expect(harness.viewModel.phase == .emailSent("first@example.com"))
    }

    @Test
    func resendMagicLinkServerErrorPromotesToFailed() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse(statusCode: 500, headers: [:], body: Data())),
        ])
        let harness = try await makeHarness(
            http: http,
            initialPhase: .emailSent("cat@example.com"),
        )

        await harness.viewModel.resendMagicLink()

        guard case let .failed(error) = harness.viewModel.phase else {
            Issue.record("expected .failed, got \(harness.viewModel.phase)")
            return
        }
        #expect(error == AuthError.serverError(status: 500, message: nil))
    }

    @Test
    func resendMagicLinkFromNonEmailSentIsNoOp() async throws {
        let http = MockHTTPClient()
        let harness = try await makeHarness(http: http)

        await harness.viewModel.resendMagicLink()

        #expect(harness.viewModel.phase == .idle)
        #expect(await http.sendCount() == 0)
    }

    // MARK: Email sheet presentation

    @Test
    func presentEmailSheetFromIdleOpensIt() async throws {
        let harness = try await makeHarness(http: MockHTTPClient())
        harness.viewModel.presentEmailSheet()
        #expect(harness.viewModel.emailSheetPresented)
    }

    @Test
    func presentEmailSheetWhileBusyIsRejected() async throws {
        let harness = try await makeHarness(
            http: MockHTTPClient(),
            initialPhase: .authenticating(.apple),
        )
        harness.viewModel.presentEmailSheet()
        #expect(!harness.viewModel.emailSheetPresented)
    }

    @Test
    func presentEmailSheetFromSucceededIsRejected() async throws {
        let session = AuthSession(
            bearerToken: "t",
            user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
            provider: .apple,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let harness = try await makeHarness(
            http: MockHTTPClient(),
            initialPhase: .succeeded(session),
        )
        harness.viewModel.presentEmailSheet()
        #expect(!harness.viewModel.emailSheetPresented)
    }

    @Test
    func presentEmailSheetFromEmailSentIsRejected() async throws {
        let harness = try await makeHarness(
            http: MockHTTPClient(),
            initialPhase: .emailSent("cat@example.com"),
        )
        harness.viewModel.presentEmailSheet()
        #expect(!harness.viewModel.emailSheetPresented,
                "email entry sheet is a pre-request affordance; re-opening it from emailSent would be confusing")
    }

    @Test
    func dismissEmailSheetClearsFlag() async throws {
        let harness = try await makeHarness(http: MockHTTPClient())
        harness.viewModel.emailSheetPresented = true
        harness.viewModel.dismissEmailSheet()
        #expect(!harness.viewModel.emailSheetPresented)
    }

    // MARK: Derived properties

    @Test
    func isEmailInputValidReflectsTextContent() async throws {
        let harness = try await makeHarness(http: MockHTTPClient())
        harness.viewModel.emailInput = ""
        #expect(!harness.viewModel.isEmailInputValid)
        harness.viewModel.emailInput = "cat@example.com"
        #expect(harness.viewModel.isEmailInputValid)
        harness.viewModel.emailInput = "no-at-sign"
        #expect(!harness.viewModel.isEmailInputValid)
    }

    @Test
    func canRequestMagicLinkRequiresNotBusyAndValidEmail() async throws {
        let harness = try await makeHarness(http: MockHTTPClient())
        // idle + invalid email
        #expect(!harness.viewModel.canRequestMagicLink)
        harness.viewModel.emailInput = "cat@example.com"
        // idle + valid
        #expect(harness.viewModel.canRequestMagicLink)

        // Same email, but a busy phase — still rejected.
        let busy = try await makeHarness(
            http: MockHTTPClient(),
            initialPhase: .requestingMagicLink,
        )
        busy.viewModel.emailInput = "cat@example.com"
        #expect(!busy.viewModel.canRequestMagicLink)
    }

    @Test
    func currentErrorMessageIsNilUnlessFailed() async throws {
        let harness = try await makeHarness(http: MockHTTPClient())
        #expect(harness.viewModel.currentErrorMessage == nil)

        let failed = try await makeHarness(
            http: MockHTTPClient(),
            initialPhase: .failed(.invalidEmail),
        )
        let message = try #require(failed.viewModel.currentErrorMessage)
        #expect(message == SignInStrings.message(for: .invalidEmail))
    }

    // MARK: Resume

    @Test
    func resumeWithExistingSessionGoesStraightToSucceeded() async throws {
        let existing = AuthSession(
            bearerToken: "persisted",
            user: AuthUser(id: "u", email: "a@b.com", name: nil, image: nil, emailVerified: true),
            provider: .magicLink,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let store = InMemoryBearerTokenStore(initial: existing)
        let harness = try await makeHarness(http: MockHTTPClient(), store: store)

        await harness.viewModel.resume()

        #expect(harness.viewModel.phase == .succeeded(existing))
    }

    @Test
    func resumeWithNoSessionStaysIdle() async throws {
        let harness = try await makeHarness(http: MockHTTPClient())
        await harness.viewModel.resume()
        #expect(harness.viewModel.phase == .idle)
    }

    @Test
    func resumeDoesNotOverrideExistingSucceededPhase() async throws {
        // If the VM already holds a succeeded phase — perhaps because
        // a Universal Link completed during first-launch — a second
        // `resume()` call must leave it alone and not trigger a
        // keychain read.
        let first = AuthSession(
            bearerToken: "first",
            user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
            provider: .apple,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let second = AuthSession(
            bearerToken: "second",
            user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
            provider: .google,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_042),
        )
        let store = InMemoryBearerTokenStore(initial: second)
        let harness = try await makeHarness(
            http: MockHTTPClient(),
            store: store,
            initialPhase: .succeeded(first),
        )

        await harness.viewModel.resume()

        #expect(harness.viewModel.phase == .succeeded(first),
                "resume must not replace an already-succeeded phase")
    }
}
