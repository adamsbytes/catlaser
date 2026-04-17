import Foundation
import Testing

@testable import CatLaserAuth

@Suite("OAuthRedirectPolicy")
struct OAuthRedirectPolicyTests {
    private let allowed: Set<String> = ["auth.catlaser.example", "auth.backup.example"]

    @Test
    func acceptsHTTPSOnAllowedHost() throws {
        let url = URL(string: "https://auth.catlaser.example/oauth/google")!
        try OAuthRedirectPolicy.validate(url, allowedHosts: allowed)
    }

    @Test
    func acceptsAnyOfMultipleAllowedHosts() throws {
        let url = URL(string: "https://auth.backup.example/oauth/google")!
        try OAuthRedirectPolicy.validate(url, allowedHosts: allowed)
    }

    @Test
    func acceptsUppercaseHostIgnoringCase() throws {
        let url = URL(string: "https://AUTH.CATLASER.EXAMPLE/oauth/google")!
        try OAuthRedirectPolicy.validate(url, allowedHosts: allowed)
    }

    @Test
    func rejectsCustomScheme() throws {
        // This is the headline property: custom schemes (including
        // Google's `com.googleusercontent.apps.*`) are rejected outright
        // because iOS offers no ownership verification.
        let url = URL(string: "com.googleusercontent.apps.12345:/oauth/google")!
        expectInvalidRedirect(url, allowed: allowed, matching: "https")
    }

    @Test
    func rejectsReverseDNSCustomScheme() {
        let url = URL(string: "com.catlaser.app:/oauth/google")!
        expectInvalidRedirect(url, allowed: allowed, matching: "https")
    }

    @Test
    func rejectsHTTPScheme() {
        let url = URL(string: "http://auth.catlaser.example/oauth/google")!
        expectInvalidRedirect(url, allowed: allowed, matching: "https")
    }

    @Test
    func rejectsHostNotInAllowlist() {
        let url = URL(string: "https://evil.example/oauth/google")!
        expectInvalidRedirect(url, allowed: allowed, matching: "allowed")
    }

    @Test
    func rejectsHostLookalikeSubdomain() {
        let url = URL(string: "https://auth.catlaser.example.evil.com/oauth/google")!
        expectInvalidRedirect(url, allowed: allowed, matching: "allowed")
    }

    @Test
    func rejectsUserInfoSmuggling() {
        let url = URL(string: "https://attacker@auth.catlaser.example/oauth/google")!
        expectInvalidRedirect(url, allowed: allowed, matching: "userinfo")
    }

    @Test
    func rejectsPasswordUserInfo() {
        let url = URL(string: "https://user:pass@auth.catlaser.example/oauth/google")!
        expectInvalidRedirect(url, allowed: allowed, matching: "userinfo")
    }

    @Test
    func rejectsExplicitPort() {
        let url = URL(string: "https://auth.catlaser.example:8443/oauth/google")!
        expectInvalidRedirect(url, allowed: allowed, matching: "port")
    }

    @Test
    func rejectsMissingHost() {
        let url = URL(string: "https:///oauth/google")!
        expectInvalidRedirect(url, allowed: allowed, matching: "host")
    }

    @Test
    func rejectsEmptyAllowlist() {
        let url = URL(string: "https://auth.catlaser.example/oauth/google")!
        expectInvalidRedirect(url, allowed: [], matching: "empty")
    }

    @Test
    func rejectsPathWithControlCharacters() {
        // URL() would not normally accept this, but hand-craft the URL.
        var components = URLComponents()
        components.scheme = "https"
        components.host = "auth.catlaser.example"
        components.path = "/oauth/\u{0A}google"
        let url = components.url!
        expectInvalidRedirect(url, allowed: allowed, matching: "control")
    }

    private func expectInvalidRedirect(
        _ url: URL,
        allowed: Set<String>,
        matching contains: String,
        sourceLocation: SourceLocation = #_sourceLocation,
    ) {
        do {
            try OAuthRedirectPolicy.validate(url, allowedHosts: allowed)
            Issue.record("expected invalidRedirectURL", sourceLocation: sourceLocation)
        } catch let AuthError.invalidRedirectURL(message) {
            #expect(
                message.lowercased().contains(contains.lowercased()),
                "message '\(message)' did not contain '\(contains)'",
                sourceLocation: sourceLocation,
            )
        } catch {
            Issue.record("unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }
}
