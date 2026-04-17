import Foundation
import Testing

@testable import CatLaserAuth

@Suite("AuthClient")
struct AuthClientTests {
    private func makeClient(
        outcomes: [MockHTTPClient.Outcome],
        clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) },
    ) throws -> (AuthClient, MockHTTPClient) {
        let mock = MockHTTPClient(outcomes: outcomes)
        let config = try AuthConfig(
            baseURL: URL(string: "https://auth.example")!,
            appleServiceID: "svc",
            googleClientID: "cid",
            bundleID: "com.catlaser.app",
            universalLinkHost: "link.example",
            universalLinkPath: "/app/magic-link",
            oauthRedirectHosts: ["auth.example"],
        )
        let client = AuthClient(config: config, http: mock, clock: clock)
        return (client, mock)
    }

    @Test
    func successfulAppleExchange() async throws {
        let responseJSON: [String: Any] = [
            "user": ["id": "user-1", "email": "a@b.com", "emailVerified": true],
        ]
        let outcome: MockHTTPClient.Outcome = .response(.json(responseJSON, token: "bearer-xyz"))
        let (client, mock) = try makeClient(outcomes: [outcome])

        let session = try await client.exchangeSocial(
            provider: .apple,
            idToken: SocialIDToken(token: "id.token", rawNonce: "raw", accessToken: nil),
            attestationHeader: "ATTEST",
        )

        #expect(session.bearerToken == "bearer-xyz")
        #expect(session.user.id == "user-1")
        #expect(session.user.email == "a@b.com")
        #expect(session.provider == .apple)
        #expect(session.establishedAt == Date(timeIntervalSince1970: 1_700_000_000))

        let request = await mock.lastRequest()
        #expect(request?.url?.absoluteString == "https://auth.example/api/auth/sign-in/social")
        #expect(request?.method == "POST")
        #expect(request?.headers["Content-Type"] == "application/json")
        #expect(request?.headers["Accept"] == "application/json")
        #expect(request?.header(DeviceAttestationEncoder.headerName) == "ATTEST")
        let body = try #require(request?.body)
        let bodyString = String(data: body, encoding: .utf8)
        #expect(bodyString == "{\"idToken\":{\"nonce\":\"raw\",\"token\":\"id.token\"},\"provider\":\"apple\"}")
    }

    @Test
    func successfulGoogleExchange() async throws {
        let responseJSON: [String: Any] = [
            "user": ["id": "u2", "name": "Bob", "emailVerified": false],
        ]
        let (client, mock) = try makeClient(
            outcomes: [.response(.json(responseJSON, token: "gbearer"))],
        )

        let session = try await client.exchangeSocial(
            provider: .google,
            idToken: SocialIDToken(token: "g.id.token", rawNonce: nil, accessToken: "g.access"),
            attestationHeader: "GHDR",
        )

        #expect(session.bearerToken == "gbearer")
        #expect(session.user.id == "u2")
        #expect(session.user.name == "Bob")
        #expect(session.provider == .google)

        let req = try #require(await mock.lastRequest())
        #expect(req.header(DeviceAttestationEncoder.headerName) == "GHDR")
        let body = try #require(req.body)
        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let idToken = parsed?["idToken"] as? [String: Any]
        #expect(parsed?["provider"] as? String == "google")
        #expect(idToken?["token"] as? String == "g.id.token")
        #expect(idToken?["accessToken"] as? String == "g.access")
        #expect(idToken?["nonce"] == nil)
    }

    @Test
    func exchangeSocialSendsAttestationHeader() async throws {
        // Social sign-in carries the same v3 device attestation header as
        // magic-link does. Without it, a stolen provider ID token could be
        // exchanged from a different device. Assert the exact header name
        // matches the encoder's configured header key (no duplication, no
        // rename drift) and the value is preserved byte-for-byte.
        let (client, mock) = try makeClient(
            outcomes: [.response(.json(["user": ["id": "u"]], token: "b"))],
        )
        _ = try await client.exchangeSocial(
            provider: .apple,
            idToken: SocialIDToken(token: "t", rawNonce: "n"),
            attestationHeader: "the-exact-header-value",
        )
        let req = try #require(await mock.lastRequest())
        #expect(DeviceAttestationEncoder.headerName == "x-device-attestation")
        #expect(req.header(DeviceAttestationEncoder.headerName) == "the-exact-header-value")
    }

    @Test
    func exchangeSocialRejectsEmptyAttestationHeader() async throws {
        let (client, mock) = try makeClient(outcomes: [])
        do {
            _ = try await client.exchangeSocial(
                provider: .apple,
                idToken: SocialIDToken(token: "t", rawNonce: "n"),
                attestationHeader: "",
            )
            Issue.record("expected attestationFailed")
        } catch let AuthError.attestationFailed(msg) {
            #expect(msg.contains("empty"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await mock.sendCount() == 0)
    }

    @Test
    func missingBearerHeaderIsError() async throws {
        let (client, _) = try makeClient(outcomes: [
            .response(.json(["user": ["id": "u"]], token: nil)),
        ])

        await #expect(throws: AuthError.missingBearerToken) {
            _ = try await client.exchangeSocial(
                provider: .apple,
                idToken: SocialIDToken(token: "t", rawNonce: "n", accessToken: nil),
                attestationHeader: "h",
            )
        }
    }

    @Test
    func emptyBearerHeaderIsError() async throws {
        let (client, _) = try makeClient(outcomes: [
            .response(.json(["user": ["id": "u"]], token: "   ")),
        ])
        await #expect(throws: AuthError.missingBearerToken) {
            _ = try await client.exchangeSocial(
                provider: .apple,
                idToken: SocialIDToken(token: "t", rawNonce: "n"),
                attestationHeader: "h",
            )
        }
    }

    @Test
    func bearerHeaderLookupIsCaseInsensitive() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["user": ["id": "u"]])
        let response = HTTPResponse(
            statusCode: 200,
            headers: ["SET-AUTH-TOKEN": "hdr-token", "Content-Type": "application/json"],
            body: body,
        )
        let (client, _) = try makeClient(outcomes: [.response(response)])
        let session = try await client.exchangeSocial(
            provider: .apple,
            idToken: SocialIDToken(token: "t", rawNonce: "n"),
            attestationHeader: "h",
        )
        #expect(session.bearerToken == "hdr-token")
    }

    @Test
    func malformedResponseJSON() async throws {
        let response = HTTPResponse(
            statusCode: 200,
            headers: [AuthClient.bearerHeader: "bearer"],
            body: Data("not json".utf8),
        )
        let (client, _) = try makeClient(outcomes: [.response(response)])
        do {
            _ = try await client.exchangeSocial(
                provider: .apple,
                idToken: SocialIDToken(token: "t", rawNonce: "n"),
                attestationHeader: "h",
            )
            Issue.record("expected malformedResponse")
        } catch let error as AuthError {
            switch error {
            case .malformedResponse: break
            default: Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test
    func emptyIDTokenRejectedLocally() async throws {
        let (client, mock) = try makeClient(outcomes: [])
        await #expect(throws: AuthError.missingIDToken) {
            _ = try await client.exchangeSocial(
                provider: .apple,
                idToken: SocialIDToken(token: "   ", rawNonce: "n"),
                attestationHeader: "h",
            )
        }
        #expect(await mock.sendCount() == 0)
    }

    @Test
    func serverError400MapsToCredentialInvalid() async throws {
        let body: [String: Any] = ["error": "invalid_id_token"]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response = HTTPResponse(statusCode: 400, headers: [:], body: bodyData)
        let (client, _) = try makeClient(outcomes: [.response(response)])
        do {
            _ = try await client.exchangeSocial(
                provider: .apple,
                idToken: SocialIDToken(token: "t", rawNonce: "n"),
                attestationHeader: "h",
            )
            Issue.record("expected error")
        } catch let AuthError.credentialInvalid(message) {
            #expect(message == "invalid_id_token")
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test
    func serverError401MapsToCredentialInvalid() async throws {
        let response = HTTPResponse(statusCode: 401, headers: [:], body: Data("Unauthorized".utf8))
        let (client, _) = try makeClient(outcomes: [.response(response)])
        do {
            _ = try await client.exchangeSocial(
                provider: .google,
                idToken: SocialIDToken(token: "t"),
                attestationHeader: "h",
            )
            Issue.record("expected error")
        } catch let AuthError.credentialInvalid(message) {
            #expect(message == "Unauthorized")
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test
    func serverError500MapsToServerError() async throws {
        let body: [String: Any] = ["message": "database down"]
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = HTTPResponse(statusCode: 503, headers: [:], body: data)
        let (client, _) = try makeClient(outcomes: [.response(response)])
        do {
            _ = try await client.exchangeSocial(
                provider: .apple,
                idToken: SocialIDToken(token: "t", rawNonce: "n"),
                attestationHeader: "h",
            )
            Issue.record("expected error")
        } catch let AuthError.serverError(status, message) {
            #expect(status == 503)
            #expect(message == "database down")
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test
    func transportErrorBubblesAsAuthError() async throws {
        struct Fake: Error {}
        let (client, _) = try makeClient(outcomes: [.failure(Fake())])
        await #expect(throws: (any Error).self) {
            _ = try await client.exchangeSocial(
                provider: .apple,
                idToken: SocialIDToken(token: "t", rawNonce: "n"),
                attestationHeader: "h",
            )
        }
    }

    @Test
    func signOutSendsBearer() async throws {
        let (client, mock) = try makeClient(outcomes: [.response(.json([:], status: 200, token: nil))])
        let user = AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true)
        let session = AuthSession(
            bearerToken: "my-token",
            user: user,
            provider: .apple,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        try await client.signOut(session: session)
        let request = try #require(await mock.lastRequest())
        #expect(request.url?.absoluteString == "https://auth.example/api/auth/sign-out")
        #expect(request.method == "POST")
        #expect(request.headers["Authorization"] == "Bearer my-token")
    }

    @Test
    func signOutServerErrorPropagates() async throws {
        let (client, _) = try makeClient(outcomes: [.response(HTTPResponse(statusCode: 500, headers: [:], body: Data()))])
        let session = AuthSession(
            bearerToken: "t",
            user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
            provider: .google,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        await #expect(throws: AuthError.serverError(status: 500, message: nil)) {
            try await client.signOut(session: session)
        }
    }

    @Test
    func decodesRealBetterAuthResponseShape() async throws {
        // Matches the actual /sign-in/social JSON emitted by better-auth when
        // ID-token flow succeeds: flat object with redirect/token/url/user keys.
        let responseJSON: [String: Any] = [
            "redirect": false,
            "token": "body-session-token",
            "user": [
                "id": "u-real",
                "email": "real@example.com",
                "emailVerified": true,
                "name": "Real User",
                "image": NSNull(),
            ],
        ]
        let (client, _) = try makeClient(
            outcomes: [.response(.json(responseJSON, token: "header-bearer"))],
        )
        let session = try await client.exchangeSocial(
            provider: .apple,
            idToken: SocialIDToken(token: "id", rawNonce: "n"),
            attestationHeader: "h",
        )
        #expect(session.bearerToken == "header-bearer", "header value takes precedence per bearer plugin contract")
        #expect(session.user.id == "u-real")
        #expect(session.user.email == "real@example.com")
        #expect(session.user.name == "Real User")
        #expect(session.user.image == nil)
        #expect(session.user.emailVerified == true)
    }

    @Test
    func requestBodyUsesSortedKeys() async throws {
        // sortedKeys output is deterministic; assert byte-for-byte.
        let (client, mock) = try makeClient(
            outcomes: [.response(.json(["user": ["id": "u"]], token: "b"))],
        )
        _ = try await client.exchangeSocial(
            provider: .apple,
            idToken: SocialIDToken(token: "A", rawNonce: "B", accessToken: "C"),
            attestationHeader: "h",
        )
        let body = try #require(await mock.lastRequest()?.body)
        let bodyString = String(data: body, encoding: .utf8)
        #expect(bodyString == "{\"idToken\":{\"accessToken\":\"C\",\"nonce\":\"B\",\"token\":\"A\"},\"provider\":\"apple\"}")
    }
}
