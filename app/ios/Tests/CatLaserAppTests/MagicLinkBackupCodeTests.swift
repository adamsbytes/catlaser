import CatLaserAuthTestSupport
import Foundation
import Testing

@testable import CatLaserApp
@testable import CatLaserAuth

// MARK: - BackupCode structural tests

@Suite("BackupCode value type")
struct BackupCodeTests {
    @Test
    func rejectsTooShort() {
        #expect(throws: AuthError.self) {
            _ = try BackupCode("12345")
        }
    }

    @Test
    func rejectsTooLong() {
        #expect(throws: AuthError.self) {
            _ = try BackupCode("1234567")
        }
    }

    @Test
    func rejectsNonDigits() {
        #expect(throws: AuthError.self) {
            _ = try BackupCode("12a456")
        }
        #expect(throws: AuthError.self) {
            _ = try BackupCode("abcdef")
        }
    }

    @Test
    func stripsWhitespaceAndHyphens() throws {
        let variants = ["123456", "123 456", "123-456", " 123456 ", "1 2 3 4 5 6"]
        for raw in variants {
            let code = try BackupCode(raw)
            #expect(code.canonical == "123456", "input: \(raw)")
        }
    }

    @Test
    func rejectsFullwidthDigits() {
        // U+FF10..U+FF19 are visually-identical Unicode fullwidth digits.
        // The server HMAC is byte-wise over the UTF-8 encoding, so the
        // client MUST refuse these at the value-type layer to prevent a
        // canonicalisation mismatch that would always fail the server
        // lookup without a useful error.
        #expect(throws: AuthError.self) {
            _ = try BackupCode("\u{FF11}\u{FF12}\u{FF13}\u{FF14}\u{FF15}\u{FF16}")
        }
    }

    @Test
    func allZerosIsValid() throws {
        let code = try BackupCode("000000")
        #expect(code.canonical == "000000")
    }
}

// MARK: - SignInViewModel backup-code flow

private func makeBackupConfig() throws -> AuthConfig {
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

private func makeBackupFingerprint() -> DeviceFingerprint {
    DeviceFingerprint(
        platform: "ios",
        model: "iPhone15,4",
        systemName: "iOS",
        bundleID: "com.catlaser.app",
        installID: "install-1",
    )
}

@MainActor
private func makeBackupHarness(
    http: MockHTTPClient,
    store: InMemoryBearerTokenStore = InMemoryBearerTokenStore(),
) async throws -> (viewModel: SignInViewModel, http: MockHTTPClient, store: InMemoryBearerTokenStore) {
    let config = try makeBackupConfig()
    let clock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }
    let client = AuthClient(config: config, http: http, clock: clock)
    let identity = SoftwareIdentityStore()
    let attestation = StubDeviceAttestationProvider(
        fingerprint: makeBackupFingerprint(),
        identity: identity,
    )
    let coordinator = AuthCoordinator(
        client: client,
        store: store,
        attestationProvider: attestation,
        clock: clock,
    )
    let vm = SignInViewModel(
        coordinator: coordinator,
        initialPhase: .emailSent("you@example.com"),
    )
    return (vm, http, store)
}

@MainActor
@Suite("SignInViewModel backup-code path")
struct SignInViewModelBackupCodeTests {
    @Test
    func canSubmitRequiresEmailSentPhaseAndValidCode() async throws {
        let (vm, _, _) = try await makeBackupHarness(http: MockHTTPClient())

        // Empty buffer → cannot submit.
        #expect(!vm.canSubmitBackupCode)

        // Partial buffer → still cannot submit.
        vm.backupCodeInput = "123"
        #expect(!vm.canSubmitBackupCode)

        // Structurally valid → can submit.
        vm.backupCodeInput = "123456"
        #expect(vm.canSubmitBackupCode)

        // Whitespace allowed — the value type normalises.
        vm.backupCodeInput = "123 456"
        #expect(vm.canSubmitBackupCode)
    }

    @Test
    func canSubmitReturnsFalseOutsideEmailSentPhase() async throws {
        // Build a VM parked on `.idle` instead of `.emailSent` so the
        // phase gate refuses the submit even with a structurally-
        // valid code in the buffer.
        let clock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }
        let config = try makeBackupConfig()
        let identity = SoftwareIdentityStore()
        let coordinator = AuthCoordinator(
            client: AuthClient(config: config, http: MockHTTPClient(), clock: clock),
            store: InMemoryBearerTokenStore(),
            attestationProvider: StubDeviceAttestationProvider(
                fingerprint: makeBackupFingerprint(),
                identity: identity,
            ),
            clock: clock,
        )
        let idle = SignInViewModel(coordinator: coordinator, initialPhase: .idle)
        idle.backupCodeInput = "123456"
        #expect(!idle.canSubmitBackupCode)
    }

    @Test
    func malformedCodeLandsOnFailedWithoutNetworkCall() async throws {
        let http = MockHTTPClient()
        let (vm, mockHTTP, store) = try await makeBackupHarness(http: http)

        vm.backupCodeInput = "12345"
        await vm.submitBackupCode()

        guard case let .failed(error) = vm.phase else {
            Issue.record("expected .failed, got \(vm.phase)")
            return
        }
        if case .invalidMagicLink = error {
            // expected
        } else {
            Issue.record("expected .invalidMagicLink, got \(error)")
        }
        #expect(await mockHTTP.sendCount() == 0)
        #expect(try await store.load() == nil)
    }

    @Test
    func successfulBackupCodeMintsSession() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(.json(["user": ["id": "u-code"]], token: "bearer-code")),
        ])
        let (vm, mockHTTP, store) = try await makeBackupHarness(http: http)

        vm.backupCodeInput = "123456"
        await vm.submitBackupCode()

        guard case let .succeeded(session) = vm.phase else {
            Issue.record("expected .succeeded, got \(vm.phase)")
            return
        }
        #expect(session.bearerToken == "bearer-code")
        #expect(session.provider == .magicLink)
        #expect(try await store.load() == session)

        // Request shape: POST /api/v1/auth/magic-link/verify-by-code
        // with `{code: "123456"}` body and an attestation header.
        #expect(await mockHTTP.sendCount() == 1)
        let request = try #require(await mockHTTP.lastRequest())
        #expect(request.method == "POST")
        #expect(request.url?.path == "/api/v1/auth/magic-link/verify-by-code")
        #expect(request.header(DeviceAttestationEncoder.headerName)?.isEmpty == false)
        // Buffer cleared on success so a later re-mount of the
        // "check your email" screen starts fresh.
        #expect(vm.backupCodeInput == "")
    }

    @Test
    func serverRejectionLandsOnFailedButPreservesBuffer() async throws {
        // Server returns 401 with `INVALID_CODE` (simulating a wrong
        // code after the user mistyped). The VM must land on
        // `.failed` WITHOUT clearing the buffer so the user can
        // correct and retry on the same screen.
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse(
                statusCode: 401,
                headers: [:],
                body: Data(#"{"code":"INVALID_CODE"}"#.utf8),
            )),
        ])
        let (vm, _, store) = try await makeBackupHarness(http: http)

        vm.backupCodeInput = "123456"
        await vm.submitBackupCode()

        guard case let .failed(error) = vm.phase else {
            Issue.record("expected .failed, got \(vm.phase)")
            return
        }
        if case .invalidMagicLink = error {
            // expected
        } else {
            Issue.record("expected .invalidMagicLink, got \(error)")
        }
        #expect(try await store.load() == nil)
        #expect(vm.backupCodeInput == "123456")
    }
}
