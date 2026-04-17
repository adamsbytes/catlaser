import Foundation
import Testing

@testable import CatLaserAuth

private func makeConfig(
    base: String = "https://auth.catlaser.example",
    universalLinkHost: String = "link.catlaser.example",
    universalLinkPath: String = "/app/magic-link",
) throws -> AuthConfig {
    try AuthConfig(
        baseURL: URL(string: base)!,
        appleServiceID: "svc",
        googleClientID: "cid",
        bundleID: "com.catlaser.app",
        universalLinkHost: universalLinkHost,
        universalLinkPath: universalLinkPath,
        oauthRedirectHosts: ["auth.catlaser.example"],
    )
}

@Suite("MagicLinkCallback")
struct MagicLinkCallbackTests {
    @Test
    func parsesValidCallback() throws {
        let config = try makeConfig()
        let url = URL(string: "https://link.catlaser.example/app/magic-link?token=abc123")!
        let callback = try MagicLinkCallback(url: url, config: config)
        #expect(callback.token == "abc123")
    }

    @Test
    func acceptsUppercaseHostIgnoringCase() throws {
        let config = try makeConfig()
        let url = URL(string: "https://LINK.CATLASER.EXAMPLE/app/magic-link?token=abc")!
        let callback = try MagicLinkCallback(url: url, config: config)
        #expect(callback.token == "abc")
    }

    @Test
    func tokenPreservesPercentDecodedValue() throws {
        let config = try makeConfig()
        let url = URL(string: "https://link.catlaser.example/app/magic-link?token=a%2Bb")!
        let callback = try MagicLinkCallback(url: url, config: config)
        #expect(callback.token == "a+b")
    }

    @Test
    func ignoresUnrelatedQueryParams() throws {
        let config = try makeConfig()
        let url = URL(string: "https://link.catlaser.example/app/magic-link?token=ok&callbackURL=whatever")!
        let callback = try MagicLinkCallback(url: url, config: config)
        #expect(callback.token == "ok")
    }

    @Test
    func rejectsHTTPScheme() throws {
        let config = try makeConfig()
        let url = URL(string: "http://link.catlaser.example/app/magic-link?token=abc")!
        expectInvalidMagicLink(url: url, config: config, matching: "https")
    }

    @Test
    func rejectsCustomScheme() throws {
        let config = try makeConfig()
        let url = URL(string: "catlaser://link.catlaser.example/app/magic-link?token=abc")!
        expectInvalidMagicLink(url: url, config: config, matching: "https")
    }

    @Test
    func rejectsSubdomainLookalikeHost() throws {
        let config = try makeConfig()
        let url = URL(string: "https://link.catlaser.example.evil.com/app/magic-link?token=abc")!
        expectInvalidMagicLink(url: url, config: config, matching: "host")
    }

    @Test
    func rejectsAPIVerifyHostEvenIfValid() throws {
        // Critical C2 property: a link at the API host path must NOT be
        // treated as a valid callback. Safari may reach the API directly
        // in bad-AASA cases and must never be able to complete sign-in
        // via that route.
        let config = try makeConfig()
        let url = URL(string: "https://auth.catlaser.example/api/auth/magic-link/verify?token=abc")!
        expectInvalidMagicLink(url: url, config: config, matching: "host")
    }

    @Test
    func rejectsDifferentHostEntirely() throws {
        let config = try makeConfig()
        let url = URL(string: "https://evil.example/app/magic-link?token=abc")!
        expectInvalidMagicLink(url: url, config: config, matching: "host")
    }

    @Test
    func rejectsUserInfoSmuggling() throws {
        let config = try makeConfig()
        let url = URL(string: "https://attacker@link.catlaser.example/app/magic-link?token=abc")!
        expectInvalidMagicLink(url: url, config: config, matching: "userinfo")
    }

    @Test
    func rejectsUnexpectedPort() throws {
        let config = try makeConfig()
        let url = URL(string: "https://link.catlaser.example:8443/app/magic-link?token=abc")!
        expectInvalidMagicLink(url: url, config: config, matching: "port")
    }

    @Test
    func rejectsPathMismatch() throws {
        let config = try makeConfig()
        let url = URL(string: "https://link.catlaser.example/app/other?token=abc")!
        expectInvalidMagicLink(url: url, config: config, matching: "path")
    }

    @Test
    func rejectsTrailingPathSegment() throws {
        let config = try makeConfig()
        let url = URL(string: "https://link.catlaser.example/app/magic-link/extra?token=abc")!
        expectInvalidMagicLink(url: url, config: config, matching: "path")
    }

    @Test
    func rejectsMissingToken() throws {
        let config = try makeConfig()
        let url = URL(string: "https://link.catlaser.example/app/magic-link")!
        expectInvalidMagicLink(url: url, config: config, matching: "missing token")
    }

    @Test
    func rejectsEmptyToken() throws {
        let config = try makeConfig()
        let url = URL(string: "https://link.catlaser.example/app/magic-link?token=")!
        expectInvalidMagicLink(url: url, config: config, matching: "empty")
    }

    @Test
    func rejectsDuplicateTokenParam() throws {
        let config = try makeConfig()
        let url = URL(string: "https://link.catlaser.example/app/magic-link?token=a&token=b")!
        expectInvalidMagicLink(url: url, config: config, matching: "duplicate")
    }

    @Test
    func rejectsWhitespaceInToken() throws {
        let config = try makeConfig()
        let url = URL(string: "https://link.catlaser.example/app/magic-link?token=a%20b")!
        expectInvalidMagicLink(url: url, config: config, matching: "control")
    }

    @Test
    func rejectsNewlineInToken() throws {
        let config = try makeConfig()
        let url = URL(string: "https://link.catlaser.example/app/magic-link?token=a%0Ab")!
        expectInvalidMagicLink(url: url, config: config, matching: "control")
    }

    @Test
    func acceptsVeryLongLegitimateToken() throws {
        let config = try makeConfig()
        let token = String(repeating: "A", count: 512)
        let url = URL(string: "https://link.catlaser.example/app/magic-link?token=\(token)")!
        let callback = try MagicLinkCallback(url: url, config: config)
        #expect(callback.token == token)
    }

    @Test
    func keepsInjectionPayloadOpaque() throws {
        let config = try makeConfig()
        let payload = "'%20OR%20'1'='1"
        let url = URL(string: "https://link.catlaser.example/app/magic-link?token=\(payload)")!
        expectInvalidMagicLink(url: url, config: config, matching: "control")

        let safePayload = "';DROP--TABLE--users"
        let urlSafe = URL(string: "https://link.catlaser.example/app/magic-link?token=\(safePayload.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)")!
        let callback = try MagicLinkCallback(url: urlSafe, config: config)
        #expect(callback.token == "';DROP--TABLE--users")
    }

    @Test
    func configWithDeeperPathResolvesCorrectly() throws {
        let config = try makeConfig(universalLinkPath: "/tenants/42/app/magic-link")
        #expect(config.universalLinkPath == "/tenants/42/app/magic-link")
        let url = URL(string: "https://link.catlaser.example/tenants/42/app/magic-link?token=ok")!
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
            #expect(
                text.lowercased().contains(contains.lowercased()),
                "message '\(text)' did not contain '\(contains)'",
                sourceLocation: sourceLocation,
            )
        } catch {
            Issue.record("unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }
}
