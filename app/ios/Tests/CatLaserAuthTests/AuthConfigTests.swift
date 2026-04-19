import Foundation
import Testing

@testable import CatLaserAuth

@Suite("AuthConfig")
struct AuthConfigTests {
    private let validBaseURL = URL(string: "https://auth.catlaser.example")!

    private func config(
        baseURL: URL? = nil,
        appleServiceID: String = "com.catlaser.auth",
        googleClientID: String = "12345.apps.googleusercontent.com",
        bundleID: String = "com.catlaser.app",
        universalLinkHost: String = "link.catlaser.example",
        universalLinkPath: String = "/app/magic-link",
        oauthRedirectHosts: Set<String> = ["auth.catlaser.example"],
    ) throws -> AuthConfig {
        try AuthConfig(
            baseURL: baseURL ?? validBaseURL,
            appleServiceID: appleServiceID,
            googleClientID: googleClientID,
            bundleID: bundleID,
            universalLinkHost: universalLinkHost,
            universalLinkPath: universalLinkPath,
            oauthRedirectHosts: oauthRedirectHosts,
        )
    }

    @Test
    func acceptsHTTPSURL() throws {
        let config = try config()
        #expect(config.baseURL == validBaseURL)
        #expect(config.appleServiceID == "com.catlaser.auth")
        #expect(config.googleClientID == "12345.apps.googleusercontent.com")
        #expect(config.bundleID == "com.catlaser.app")
        #expect(config.universalLinkHost == "link.catlaser.example")
        #expect(config.universalLinkPath == "/app/magic-link")
        #expect(config.oauthRedirectHosts == ["auth.catlaser.example"])
    }

    @Test
    func rejectsHTTPURL() throws {
        #expect(throws: AuthConfigError.insecureBaseURL) {
            _ = try config(baseURL: URL(string: "http://auth.catlaser.example")!)
        }
    }

    @Test
    func rejectsFileURL() throws {
        #expect(throws: AuthConfigError.insecureBaseURL) {
            _ = try config(baseURL: URL(string: "file:///tmp")!)
        }
    }

    @Test
    func rejectsMissingHost() throws {
        #expect(throws: AuthConfigError.invalidBaseURL) {
            _ = try config(baseURL: URL(string: "https:///nohost")!)
        }
    }

    @Test
    func rejectsBlankAppleServiceID() {
        #expect(throws: AuthConfigError.missingAppleServiceID) {
            _ = try config(appleServiceID: "   ")
        }
    }

    @Test
    func rejectsBlankGoogleClientID() {
        #expect(throws: AuthConfigError.missingGoogleClientID) {
            _ = try config(googleClientID: "")
        }
    }

    @Test
    func rejectsBlankBundleID() {
        #expect(throws: AuthConfigError.missingBundleID) {
            _ = try config(bundleID: " ")
        }
    }

    @Test
    func trimsWhitespaceFromIDs() throws {
        let c = try config(
            appleServiceID: "  com.catlaser.auth\n",
            googleClientID: "\tclient.apps.googleusercontent.com ",
            bundleID: "   com.catlaser.app ",
        )
        #expect(c.appleServiceID == "com.catlaser.auth")
        #expect(c.googleClientID == "client.apps.googleusercontent.com")
        #expect(c.bundleID == "com.catlaser.app")
    }

    @Test
    func socialSignInURLIsCorrect() throws {
        let c = try config()
        #expect(c.socialSignInURL.absoluteString == "https://auth.catlaser.example/api/v1/auth/sign-in/social")
    }

    @Test
    func socialSignInURLPreservesBasePath() throws {
        let c = try config(baseURL: URL(string: "https://auth.catlaser.example/prefix")!)
        #expect(c.socialSignInURL.absoluteString == "https://auth.catlaser.example/prefix/api/v1/auth/sign-in/social")
    }

    @Test
    func signOutURLIsCorrect() throws {
        let c = try config()
        #expect(c.signOutURL.absoluteString == "https://auth.catlaser.example/api/v1/auth/sign-out")
    }

    @Test
    func deleteAccountURLIsCorrect() throws {
        let c = try config()
        #expect(
            c.deleteAccountURL.absoluteString
                == "https://auth.catlaser.example/api/v1/me/delete",
        )
    }

    @Test
    func acceptsUppercaseHTTPSScheme() throws {
        let c = try config(baseURL: URL(string: "HTTPS://auth.example")!)
        #expect(c.baseURL.absoluteString == "HTTPS://auth.example")
    }

    @Test
    func magicLinkRequestURLIsCorrect() throws {
        let c = try config()
        #expect(c.magicLinkRequestURL.absoluteString
            == "https://auth.catlaser.example/api/v1/auth/sign-in/magic-link")
    }

    @Test
    func magicLinkVerifyURLIsCorrect() throws {
        let c = try config()
        #expect(c.magicLinkVerifyURL.absoluteString
            == "https://auth.catlaser.example/api/v1/auth/magic-link/verify")
    }

    @Test
    func universalLinkHostLowercased() throws {
        let c = try config(universalLinkHost: "LINK.CatLaser.Example")
        #expect(c.universalLinkHost == "link.catlaser.example")
    }

    @Test
    func rejectsUniversalLinkHostWithScheme() {
        #expect(throws: AuthConfigError.invalidUniversalLinkHost) {
            _ = try config(universalLinkHost: "https://link.catlaser.example")
        }
    }

    @Test
    func rejectsUniversalLinkHostWithPort() {
        #expect(throws: AuthConfigError.invalidUniversalLinkHost) {
            _ = try config(universalLinkHost: "link.catlaser.example:443")
        }
    }

    @Test
    func rejectsUniversalLinkHostWithSlash() {
        #expect(throws: AuthConfigError.invalidUniversalLinkHost) {
            _ = try config(universalLinkHost: "link.catlaser.example/foo")
        }
    }

    @Test
    func rejectsUniversalLinkHostWithUserinfo() {
        #expect(throws: AuthConfigError.invalidUniversalLinkHost) {
            _ = try config(universalLinkHost: "user@link.catlaser.example")
        }
    }

    @Test
    func rejectsUniversalLinkHostWithSpace() {
        #expect(throws: AuthConfigError.invalidUniversalLinkHost) {
            _ = try config(universalLinkHost: "link.catlaser example")
        }
    }

    @Test
    func rejectsEmptyUniversalLinkHost() {
        #expect(throws: AuthConfigError.invalidUniversalLinkHost) {
            _ = try config(universalLinkHost: "   ")
        }
    }

    @Test
    func rejectsUniversalLinkPathWithoutLeadingSlash() {
        #expect(throws: AuthConfigError.invalidUniversalLinkPath) {
            _ = try config(universalLinkPath: "app/magic-link")
        }
    }

    @Test
    func rejectsUniversalLinkPathWithQuery() {
        #expect(throws: AuthConfigError.invalidUniversalLinkPath) {
            _ = try config(universalLinkPath: "/app/magic-link?token=x")
        }
    }

    @Test
    func rejectsUniversalLinkPathWithFragment() {
        #expect(throws: AuthConfigError.invalidUniversalLinkPath) {
            _ = try config(universalLinkPath: "/app/magic-link#frag")
        }
    }

    @Test
    func rejectsUniversalLinkPathWithSpace() {
        #expect(throws: AuthConfigError.invalidUniversalLinkPath) {
            _ = try config(universalLinkPath: "/app/magic link")
        }
    }

    @Test
    func rejectsUniversalLinkPathCollidingWithAPIVerify() {
        // THIS is the critical property of C2: if the universal-link path
        // equals the API verify endpoint's path, Safari reaching the URL
        // directly would be served by the API. The config must reject.
        #expect(throws: AuthConfigError.universalLinkPathCollidesWithAPI) {
            _ = try config(universalLinkPath: "/api/v1/auth/magic-link/verify")
        }
    }

    @Test
    func rejectsCollidingPathEvenWhenBaseHasPrefix() {
        #expect(throws: AuthConfigError.universalLinkPathCollidesWithAPI) {
            _ = try config(
                baseURL: URL(string: "https://auth.catlaser.example/tenants/42")!,
                universalLinkPath: "/tenants/42/api/v1/auth/magic-link/verify",
            )
        }
    }

    @Test
    func magicLinkCallbackURLComposedFromHostAndPath() throws {
        let c = try config(
            universalLinkHost: "link.catlaser.example",
            universalLinkPath: "/app/magic-link",
        )
        #expect(c.magicLinkCallbackURL.absoluteString == "https://link.catlaser.example/app/magic-link")
    }

    @Test
    func rejectsEmptyOAuthRedirectHosts() {
        #expect(throws: AuthConfigError.missingOAuthRedirectHost) {
            _ = try config(oauthRedirectHosts: [])
        }
    }

    @Test
    func rejectsOAuthRedirectHostWithScheme() {
        #expect(throws: AuthConfigError.invalidOAuthRedirectHost) {
            _ = try config(oauthRedirectHosts: ["https://oauth.example"])
        }
    }

    @Test
    func oauthRedirectHostsAreLowercased() throws {
        let c = try config(oauthRedirectHosts: ["AUTH.CatLaser.Example"])
        #expect(c.oauthRedirectHosts == ["auth.catlaser.example"])
    }
}
