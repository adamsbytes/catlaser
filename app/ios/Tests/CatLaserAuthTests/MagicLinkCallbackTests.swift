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

@Suite("MagicLinkCallback")
struct MagicLinkCallbackTests {
    @Test
    func parsesValidCallback() throws {
        let config = try makeConfig()
        let url = URL(string: "https://auth.catlaser.example/api/auth/magic-link/verify?token=abc123")!
        let callback = try MagicLinkCallback(url: url, config: config)
        #expect(callback.token == "abc123")
    }

    @Test
    func acceptsUppercaseHostHeaderIgnoringCase() throws {
        let config = try makeConfig()
        let url = URL(string: "https://AUTH.CATLASER.EXAMPLE/api/auth/magic-link/verify?token=abc")!
        let callback = try MagicLinkCallback(url: url, config: config)
        #expect(callback.token == "abc")
    }

    @Test
    func tokenPreservesPercentDecodedValue() throws {
        // %2B = '+', which base64url tokens can contain after decoding.
        let config = try makeConfig()
        let url = URL(string: "https://auth.catlaser.example/api/auth/magic-link/verify?token=a%2Bb")!
        let callback = try MagicLinkCallback(url: url, config: config)
        #expect(callback.token == "a+b")
    }

    @Test
    func ignoresUnrelatedQueryParams() throws {
        let config = try makeConfig()
        let url = URL(string: "https://auth.catlaser.example/api/auth/magic-link/verify?token=ok&callbackURL=whatever")!
        let callback = try MagicLinkCallback(url: url, config: config)
        #expect(callback.token == "ok")
    }

    @Test
    func rejectsHTTPScheme() throws {
        let config = try makeConfig()
        let url = URL(string: "http://auth.catlaser.example/api/auth/magic-link/verify?token=abc")!
        expectInvalidMagicLink(url: url, config: config, matching: "https")
    }

    @Test
    func rejectsCustomScheme() throws {
        let config = try makeConfig()
        let url = URL(string: "catlaser://auth.catlaser.example/api/auth/magic-link/verify?token=abc")!
        expectInvalidMagicLink(url: url, config: config, matching: "https")
    }

    @Test
    func rejectsSubdomainLookalikeHost() throws {
        // Classic homograph / subdomain attack: host literally
        // "auth.catlaser.example.evil.com". Must never be accepted.
        let config = try makeConfig()
        let url = URL(string: "https://auth.catlaser.example.evil.com/api/auth/magic-link/verify?token=abc")!
        expectInvalidMagicLink(url: url, config: config, matching: "host")
    }

    @Test
    func rejectsDifferentHostEntirely() throws {
        let config = try makeConfig()
        let url = URL(string: "https://evil.example/api/auth/magic-link/verify?token=abc")!
        expectInvalidMagicLink(url: url, config: config, matching: "host")
    }

    @Test
    func rejectsUserInfoSmuggling() throws {
        // `https://auth.catlaser.example@evil.example/...` parses as host
        // `evil.example` with user `auth.catlaser.example`. The host check
        // catches it, but we also reject userinfo explicitly as a
        // defence-in-depth signal.
        let config = try makeConfig()
        let url = URL(string: "https://attacker@auth.catlaser.example/api/auth/magic-link/verify?token=abc")!
        expectInvalidMagicLink(url: url, config: config, matching: "userinfo")
    }

    @Test
    func rejectsUnexpectedPort() throws {
        let config = try makeConfig()
        let url = URL(string: "https://auth.catlaser.example:8443/api/auth/magic-link/verify?token=abc")!
        expectInvalidMagicLink(url: url, config: config, matching: "port")
    }

    @Test
    func rejectsPathMismatch() throws {
        let config = try makeConfig()
        let url = URL(string: "https://auth.catlaser.example/api/auth/sign-in/social?token=abc")!
        expectInvalidMagicLink(url: url, config: config, matching: "path")
    }

    @Test
    func rejectsTrailingPathSegment() throws {
        let config = try makeConfig()
        let url = URL(string: "https://auth.catlaser.example/api/auth/magic-link/verify/extra?token=abc")!
        expectInvalidMagicLink(url: url, config: config, matching: "path")
    }

    @Test
    func rejectsMissingToken() throws {
        let config = try makeConfig()
        let url = URL(string: "https://auth.catlaser.example/api/auth/magic-link/verify")!
        expectInvalidMagicLink(url: url, config: config, matching: "missing token")
    }

    @Test
    func rejectsEmptyToken() throws {
        let config = try makeConfig()
        let url = URL(string: "https://auth.catlaser.example/api/auth/magic-link/verify?token=")!
        expectInvalidMagicLink(url: url, config: config, matching: "empty")
    }

    @Test
    func rejectsDuplicateTokenParam() throws {
        let config = try makeConfig()
        let url = URL(string: "https://auth.catlaser.example/api/auth/magic-link/verify?token=a&token=b")!
        expectInvalidMagicLink(url: url, config: config, matching: "duplicate")
    }

    @Test
    func rejectsWhitespaceInToken() throws {
        let config = try makeConfig()
        let url = URL(string: "https://auth.catlaser.example/api/auth/magic-link/verify?token=a%20b")!
        expectInvalidMagicLink(url: url, config: config, matching: "control")
    }

    @Test
    func rejectsNewlineInToken() throws {
        let config = try makeConfig()
        let url = URL(string: "https://auth.catlaser.example/api/auth/magic-link/verify?token=a%0Ab")!
        expectInvalidMagicLink(url: url, config: config, matching: "control")
    }

    @Test
    func acceptsVeryLongLegitimateToken() throws {
        // Opaque tokens can realistically reach a few hundred bytes — make sure
        // we don't trip an arbitrary length limit.
        let config = try makeConfig()
        let token = String(repeating: "A", count: 512)
        let url = URL(string: "https://auth.catlaser.example/api/auth/magic-link/verify?token=\(token)")!
        let callback = try MagicLinkCallback(url: url, config: config)
        #expect(callback.token == token)
    }

    @Test
    func keepsInjectionPayloadOpaque() throws {
        // Parser must NOT evaluate, execute, or alter the token; it just
        // forwards the opaque value to the server. Classic injection
        // payloads should survive unchanged.
        let config = try makeConfig()
        let payload = "'%20OR%20'1'='1"
        let url = URL(string: "https://auth.catlaser.example/api/auth/magic-link/verify?token=\(payload)")!
        // Space via %20 is whitespace after decoding — rejected by our control-char policy.
        expectInvalidMagicLink(url: url, config: config, matching: "control")

        let safePayload = "';DROP--TABLE--users"
        let urlSafe = URL(string: "https://auth.catlaser.example/api/auth/magic-link/verify?token=\(safePayload.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)")!
        let callback = try MagicLinkCallback(url: urlSafe, config: config)
        #expect(callback.token == "';DROP--TABLE--users")
    }

    @Test
    func configWithBasePathResolvesCorrectPath() throws {
        let config = try makeConfig(base: "https://auth.catlaser.example/prefix")
        #expect(config.universalLinkPath == "/prefix/api/auth/magic-link/verify")
        let url = URL(string: "https://auth.catlaser.example/prefix/api/auth/magic-link/verify?token=ok")!
        let callback = try MagicLinkCallback(url: url, config: config)
        #expect(callback.token == "ok")
    }

    private func expectInvalidMagicLink(
        url: URL,
        config: AuthConfig,
        matching contains: String,
        sourceLocation: SourceLocation = #_sourceLocation,
    ) {
        do {
            _ = try MagicLinkCallback(url: url, config: config)
            Issue.record("expected invalidMagicLink", sourceLocation: sourceLocation)
        } catch let AuthError.invalidMagicLink(message) {
            let text = message ?? ""
            #expect(text.lowercased().contains(contains.lowercased()), "message '\(text)' did not contain '\(contains)'", sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }
}
