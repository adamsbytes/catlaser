import Foundation
import Testing

@testable import CatLaserAuth

private func makeConfig(base: String = "https://auth.catlaser.example") throws -> AuthConfig {
    try AuthConfig(
        baseURL: URL(string: base)!,
        appleServiceID: "svc",
        googleClientID: "cid",
    )
}

@Suite("AuthClient.requestMagicLink")
struct AuthClientRequestMagicLinkTests {
    private func makeClient(outcomes: [MockHTTPClient.Outcome]) throws -> (AuthClient, MockHTTPClient) {
        let mock = MockHTTPClient(outcomes: outcomes)
        let client = AuthClient(
            config: try makeConfig(),
            http: mock,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        return (client, mock)
    }

    @Test
    func sendsCorrectRequest() async throws {
        let (client, mock) = try makeClient(outcomes: [
            .response(HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
        ])
        try await client.requestMagicLink(
            email: "cat@example.com",
            callbackURL: "https://auth.catlaser.example/api/auth/magic-link/verify",
            fingerprintHeader: "ZmluZ2VycHJpbnQ=",
        )
        let req = try #require(await mock.lastRequest())
        #expect(req.url?.absoluteString == "https://auth.catlaser.example/api/auth/sign-in/magic-link")
        #expect(req.method == "POST")
        #expect(req.header("Content-Type") == "application/json")
        #expect(req.header("Accept") == "application/json")
        #expect(req.header(DeviceFingerprintEncoder.headerName) == "ZmluZ2VycHJpbnQ=")
        let body = try #require(req.body)
        let parsed = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(parsed["email"] as? String == "cat@example.com")
        #expect(parsed["callbackURL"] as? String == "https://auth.catlaser.example/api/auth/magic-link/verify")
    }

    @Test
    func trimsEmailWhitespace() async throws {
        let (client, mock) = try makeClient(outcomes: [
            .response(HTTPResponse(statusCode: 200, headers: [:], body: Data())),
        ])
        try await client.requestMagicLink(
            email: "  cat@example.com\n",
            callbackURL: nil,
            fingerprintHeader: "fp",
        )
        let body = try #require(await mock.lastRequest()?.body)
        let parsed = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(parsed["email"] as? String == "cat@example.com")
        // callbackURL omitted when nil
        #expect(parsed["callbackURL"] == nil)
    }

    @Test
    func rejectsEmptyEmailWithoutHittingNetwork() async throws {
        let (client, mock) = try makeClient(outcomes: [])
        await #expect(throws: AuthError.invalidEmail) {
            try await client.requestMagicLink(
                email: "   ",
                callbackURL: nil,
                fingerprintHeader: "fp",
            )
        }
        #expect(await mock.sendCount() == 0)
    }

    @Test
    func rejectsMalformedEmail() async throws {
        let (client, mock) = try makeClient(outcomes: [])
        await #expect(throws: AuthError.invalidEmail) {
            try await client.requestMagicLink(
                email: "not-an-email",
                callbackURL: nil,
                fingerprintHeader: "fp",
            )
        }
        #expect(await mock.sendCount() == 0)
    }

    @Test
    func rejectsEmailWithEmbeddedWhitespace() async throws {
        let (client, mock) = try makeClient(outcomes: [])
        await #expect(throws: AuthError.invalidEmail) {
            try await client.requestMagicLink(
                email: "a b@example.com",
                callbackURL: nil,
                fingerprintHeader: "fp",
            )
        }
        #expect(await mock.sendCount() == 0)
    }

    @Test
    func rejectsOverlongEmail() async throws {
        let local = String(repeating: "a", count: 330)
        let email = "\(local)@example.com"
        let (client, mock) = try makeClient(outcomes: [])
        await #expect(throws: AuthError.invalidEmail) {
            try await client.requestMagicLink(
                email: email,
                callbackURL: nil,
                fingerprintHeader: "fp",
            )
        }
        #expect(await mock.sendCount() == 0)
    }

    @Test
    func rejectsEmptyFingerprintHeader() async throws {
        let (client, mock) = try makeClient(outcomes: [])
        do {
            try await client.requestMagicLink(
                email: "a@b.com",
                callbackURL: nil,
                fingerprintHeader: "",
            )
            Issue.record("expected fingerprintCaptureFailed")
        } catch let AuthError.fingerprintCaptureFailed(msg) {
            #expect(msg.contains("empty"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await mock.sendCount() == 0)
    }

    @Test
    func serverRejects400AsInvalidEmail() async throws {
        let (client, _) = try makeClient(outcomes: [
            .response(HTTPResponse(statusCode: 400, headers: [:], body: Data("{}".utf8))),
        ])
        await #expect(throws: AuthError.invalidEmail) {
            try await client.requestMagicLink(
                email: "a@b.com",
                callbackURL: nil,
                fingerprintHeader: "fp",
            )
        }
    }

    @Test
    func serverRejects401AsCredentialInvalid() async throws {
        let (client, _) = try makeClient(outcomes: [
            .response(HTTPResponse(statusCode: 401, headers: [:], body: Data("denied".utf8))),
        ])
        do {
            try await client.requestMagicLink(
                email: "a@b.com",
                callbackURL: nil,
                fingerprintHeader: "fp",
            )
            Issue.record("expected credentialInvalid")
        } catch let AuthError.credentialInvalid(msg) {
            #expect(msg == "denied")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func serverError500IsPropagated() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["message": "email send failure"])
        let (client, _) = try makeClient(outcomes: [
            .response(HTTPResponse(statusCode: 503, headers: [:], body: body)),
        ])
        do {
            try await client.requestMagicLink(
                email: "a@b.com",
                callbackURL: nil,
                fingerprintHeader: "fp",
            )
            Issue.record("expected serverError")
        } catch let AuthError.serverError(status, message) {
            #expect(status == 503)
            #expect(message == "email send failure")
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test
    func transportErrorBubbles() async throws {
        struct Boom: Error {}
        let (client, _) = try makeClient(outcomes: [.failure(Boom())])
        await #expect(throws: (any Error).self) {
            try await client.requestMagicLink(
                email: "a@b.com",
                callbackURL: nil,
                fingerprintHeader: "fp",
            )
        }
    }
}

@Suite("AuthClient.completeMagicLink")
struct AuthClientCompleteMagicLinkTests {
    private func makeClient(outcomes: [MockHTTPClient.Outcome]) throws -> (AuthClient, MockHTTPClient) {
        let mock = MockHTTPClient(outcomes: outcomes)
        let client = AuthClient(
            config: try makeConfig(),
            http: mock,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        return (client, mock)
    }

    @Test
    func successExchangesForBearerSession() async throws {
        let (client, mock) = try makeClient(outcomes: [
            .response(.json(["user": ["id": "u1", "email": "c@e.com", "emailVerified": true]], token: "bearer-ml")),
        ])
        let session = try await client.completeMagicLink(
            token: "valid-token",
            fingerprintHeader: "fp-abc",
        )
        #expect(session.bearerToken == "bearer-ml")
        #expect(session.user.id == "u1")
        #expect(session.provider == .magicLink)
        #expect(session.establishedAt == Date(timeIntervalSince1970: 1_700_000_000))

        let req = try #require(await mock.lastRequest())
        #expect(req.url?.absoluteString == "https://auth.catlaser.example/api/auth/magic-link/verify?token=valid-token")
        #expect(req.method == "GET")
        #expect(req.header("Accept") == "application/json")
        #expect(req.header(DeviceFingerprintEncoder.headerName) == "fp-abc")
    }

    @Test
    func tokenIsPercentEncodedOnURL() async throws {
        let (client, mock) = try makeClient(outcomes: [
            .response(.json(["user": ["id": "u1", "emailVerified": false]], token: "bearer-ml")),
        ])
        _ = try await client.completeMagicLink(
            token: "a+b=c/d",
            fingerprintHeader: "fp",
        )
        let req = try #require(await mock.lastRequest())
        // `URLComponents` percent-encodes reserved chars in query values.
        #expect(req.url?.absoluteString == "https://auth.catlaser.example/api/auth/magic-link/verify?token=a+b%3Dc/d")
        let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
        let value = components?.queryItems?.first(where: { $0.name == "token" })?.value
        #expect(value == "a+b=c/d", "server must receive the original token after decode")
    }

    @Test
    func rejectsEmptyToken() async throws {
        let (client, mock) = try makeClient(outcomes: [])
        do {
            _ = try await client.completeMagicLink(
                token: "   ",
                fingerprintHeader: "fp",
            )
            Issue.record("expected invalidMagicLink")
        } catch let AuthError.invalidMagicLink(msg) {
            #expect(msg?.contains("empty") == true)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await mock.sendCount() == 0)
    }

    @Test
    func rejectsEmptyFingerprintHeader() async throws {
        let (client, mock) = try makeClient(outcomes: [])
        do {
            _ = try await client.completeMagicLink(
                token: "abc",
                fingerprintHeader: "",
            )
            Issue.record("expected fingerprintCaptureFailed")
        } catch AuthError.fingerprintCaptureFailed {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await mock.sendCount() == 0)
    }

    @Test
    func missingBearerHeaderMapsToMissingBearerToken() async throws {
        let (client, _) = try makeClient(outcomes: [
            .response(.json(["user": ["id": "u"]], token: nil)),
        ])
        await #expect(throws: AuthError.missingBearerToken) {
            _ = try await client.completeMagicLink(token: "t", fingerprintHeader: "fp")
        }
    }

    @Test
    func deviceMismatch403IsInvalidMagicLink() async throws {
        let body = try JSONSerialization.data(
            withJSONObject: ["code": "DEVICE_MISMATCH", "message": "device mismatch"],
        )
        let (client, _) = try makeClient(outcomes: [
            .response(HTTPResponse(statusCode: 403, headers: [:], body: body)),
        ])
        do {
            _ = try await client.completeMagicLink(token: "t", fingerprintHeader: "fp")
            Issue.record("expected invalidMagicLink")
        } catch let AuthError.invalidMagicLink(msg) {
            #expect(msg == "device mismatch")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func expired410IsInvalidMagicLink() async throws {
        let (client, _) = try makeClient(outcomes: [
            .response(HTTPResponse(statusCode: 410, headers: [:], body: Data("expired".utf8))),
        ])
        do {
            _ = try await client.completeMagicLink(token: "t", fingerprintHeader: "fp")
            Issue.record("expected invalidMagicLink")
        } catch let AuthError.invalidMagicLink(msg) {
            #expect(msg == "expired")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func bad400MapsToInvalidMagicLink() async throws {
        let (client, _) = try makeClient(outcomes: [
            .response(HTTPResponse(statusCode: 400, headers: [:], body: Data("bad request".utf8))),
        ])
        do {
            _ = try await client.completeMagicLink(token: "t", fingerprintHeader: "fp")
            Issue.record("expected invalidMagicLink")
        } catch AuthError.invalidMagicLink {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func unauth401MapsToCredentialInvalid() async throws {
        let (client, _) = try makeClient(outcomes: [
            .response(HTTPResponse(statusCode: 401, headers: [:], body: Data("no".utf8))),
        ])
        do {
            _ = try await client.completeMagicLink(token: "t", fingerprintHeader: "fp")
            Issue.record("expected credentialInvalid")
        } catch AuthError.credentialInvalid {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func server500IsServerError() async throws {
        let (client, _) = try makeClient(outcomes: [
            .response(HTTPResponse(statusCode: 500, headers: [:], body: Data())),
        ])
        await #expect(throws: AuthError.serverError(status: 500, message: nil)) {
            _ = try await client.completeMagicLink(token: "t", fingerprintHeader: "fp")
        }
    }

    @Test
    func malformedUserJSONIsMalformedResponse() async throws {
        let (client, _) = try makeClient(outcomes: [
            .response(HTTPResponse(
                statusCode: 200,
                headers: [AuthClient.bearerHeader: "tok", "Content-Type": "application/json"],
                body: Data("garbage".utf8),
            )),
        ])
        do {
            _ = try await client.completeMagicLink(token: "t", fingerprintHeader: "fp")
            Issue.record("expected malformedResponse")
        } catch AuthError.malformedResponse {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
