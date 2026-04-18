import CatLaserAuthTestSupport
import Foundation

@testable import CatLaserAuth

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP fake for `PairingClientTests`. Mirrors the pattern in
/// `CatLaserAuthTests/MockHTTPClient.swift` — queue response outcomes
/// up front, drive the `PairingClient`, then assert on the recorded
/// requests.
actor MockHTTPClient: HTTPClient {
    struct RecordedRequest: Sendable {
        let url: URL?
        let method: String?
        let headers: [String: String]
        let body: Data?

        func header(_ name: String) -> String? {
            let lower = name.lowercased()
            for (k, v) in headers where k.lowercased() == lower {
                return v
            }
            return nil
        }
    }

    enum Outcome: Sendable {
        case response(HTTPResponse)
        case failure(any Error)
    }

    private var outcomes: [Outcome]
    private var recorded: [RecordedRequest] = []

    init(outcomes: [Outcome] = []) {
        self.outcomes = outcomes
    }

    func enqueue(_ outcome: Outcome) {
        outcomes.append(outcome)
    }

    func requests() -> [RecordedRequest] { recorded }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        var headers: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] {
            headers[k] = v
        }
        recorded.append(
            RecordedRequest(
                url: request.url,
                method: request.httpMethod,
                headers: headers,
                body: request.httpBody,
            ),
        )
        guard !outcomes.isEmpty else {
            struct NoOutcome: Error {}
            throw NoOutcome()
        }
        let outcome = outcomes.removeFirst()
        switch outcome {
        case let .response(r): return r
        case let .failure(e): throw e
        }
    }
}

extension HTTPResponse {
    static func json(_ dict: [String: Any], status: Int = 200) -> HTTPResponse {
        let body = try! JSONSerialization.data(withJSONObject: dict)
        return HTTPResponse(
            statusCode: status,
            headers: ["Content-Type": "application/json"],
            body: body,
        )
    }

    static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data(text.utf8))
    }

    static func empty(status: Int) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data())
    }
}

// MARK: - SignedHTTPClient test harness

/// Build a `SignedHTTPClient` wrapping the given mock. Pairing tests
/// deliberately exercise the full signed pipeline — the same wrapper
/// production uses — rather than construct a `PairingClient` against
/// a raw mock. The package-private `SignedHTTPClient(underlying:...)`
/// initializer is reached via `@testable import CatLaserAuth`; that
/// seam is invisible to release builds of `CatLaserApp` / `CatLaserPairing`.
///
/// The stubbed bearer store and attestation provider intentionally
/// hold deterministic values: pairing-client tests care about status
/// mapping and wire format, not signing correctness
/// (`CatLaserAuthTests/SignedHTTPClientTests` owns that coverage).
func signedTestClient(wrapping mock: MockHTTPClient) -> SignedHTTPClient {
    let session = AuthSession(
        bearerToken: "pairing-test-bearer",
        user: AuthUser(
            id: "user-test",
            email: "test@example.com",
            name: "Test",
            image: nil,
            emailVerified: true,
        ),
        provider: .magicLink,
        establishedAt: Date(timeIntervalSince1970: 1_712_000_000),
    )
    let store = InMemoryBearerTokenStore(initial: session)
    let identity = SoftwareIdentityStore()
    let fingerprint = DeviceFingerprint(
        platform: "ios",
        model: "iPhone15,4",
        systemName: "iOS",
        bundleID: "com.catlaser.app.tests",
        installID: "pairing-test-install",
    )
    let provider = StubDeviceAttestationProvider(fingerprint: fingerprint, identity: identity)
    return SignedHTTPClient(
        underlying: mock,
        store: store,
        attestationProvider: provider,
        clock: { Date(timeIntervalSince1970: 1_712_345_678) },
        uuidFactory: { UUID(uuidString: "00000000-0000-4000-8000-000000000000")! },
    )
}

/// Variant of ``signedTestClient(wrapping:)`` whose bearer store is
/// empty. The wrapper short-circuits with
/// ``AuthError.missingBearerToken`` BEFORE issuing any HTTP call, so
/// downstream callers never see a response — they see the typed
/// error, which maps to ``PairingError.missingSession``. Used by the
/// pairing-view-model tests that exercise the "local bearer is
/// missing" branch of reverify (distinct from server-side 401).
///
/// No underlying ``MockHTTPClient`` is required because the wrapper
/// never reaches the transport; a sentinel mock is wired to make
/// that expectation assertable (it refuses to serve any request).
func signedTestClientWithoutBearer() -> SignedHTTPClient {
    let store = InMemoryBearerTokenStore()
    let identity = SoftwareIdentityStore()
    let fingerprint = DeviceFingerprint(
        platform: "ios",
        model: "iPhone15,4",
        systemName: "iOS",
        bundleID: "com.catlaser.app.tests",
        installID: "pairing-test-install",
    )
    let provider = StubDeviceAttestationProvider(fingerprint: fingerprint, identity: identity)
    return SignedHTTPClient(
        underlying: MockHTTPClient(),
        store: store,
        attestationProvider: provider,
        clock: { Date(timeIntervalSince1970: 1_712_345_678) },
        uuidFactory: { UUID(uuidString: "00000000-0000-4000-8000-000000000000")! },
    )
}
