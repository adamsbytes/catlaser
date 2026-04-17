import Foundation
import Testing

@testable import CatLaserAuth

@Suite("AuthConfig")
struct AuthConfigTests {
    private let validBaseURL = URL(string: "https://auth.catlaser.example")!

    @Test
    func acceptsHTTPSURL() throws {
        let config = try AuthConfig(
            baseURL: validBaseURL,
            appleServiceID: "com.catlaser.auth",
            googleClientID: "12345.apps.googleusercontent.com",
        )
        #expect(config.baseURL == validBaseURL)
        #expect(config.appleServiceID == "com.catlaser.auth")
        #expect(config.googleClientID == "12345.apps.googleusercontent.com")
    }

    @Test
    func rejectsHTTPURL() {
        let url = URL(string: "http://auth.catlaser.example")!
        #expect(throws: AuthConfigError.insecureBaseURL) {
            _ = try AuthConfig(
                baseURL: url,
                appleServiceID: "com.catlaser.auth",
                googleClientID: "client",
            )
        }
    }

    @Test
    func rejectsFileURL() {
        let url = URL(string: "file:///tmp")!
        #expect(throws: AuthConfigError.insecureBaseURL) {
            _ = try AuthConfig(
                baseURL: url,
                appleServiceID: "com.catlaser.auth",
                googleClientID: "client",
            )
        }
    }

    @Test
    func rejectsMissingHost() {
        let url = URL(string: "https:///nohost")!
        #expect(throws: AuthConfigError.invalidBaseURL) {
            _ = try AuthConfig(
                baseURL: url,
                appleServiceID: "com.catlaser.auth",
                googleClientID: "client",
            )
        }
    }

    @Test
    func rejectsBlankAppleServiceID() {
        #expect(throws: AuthConfigError.missingAppleServiceID) {
            _ = try AuthConfig(
                baseURL: validBaseURL,
                appleServiceID: "   ",
                googleClientID: "client",
            )
        }
    }

    @Test
    func rejectsBlankGoogleClientID() {
        #expect(throws: AuthConfigError.missingGoogleClientID) {
            _ = try AuthConfig(
                baseURL: validBaseURL,
                appleServiceID: "com.catlaser.auth",
                googleClientID: "",
            )
        }
    }

    @Test
    func trimsWhitespaceFromIDs() throws {
        let config = try AuthConfig(
            baseURL: validBaseURL,
            appleServiceID: "  com.catlaser.auth\n",
            googleClientID: "\tclient.apps.googleusercontent.com ",
        )
        #expect(config.appleServiceID == "com.catlaser.auth")
        #expect(config.googleClientID == "client.apps.googleusercontent.com")
    }

    @Test
    func socialSignInURLIsCorrect() throws {
        let config = try AuthConfig(
            baseURL: validBaseURL,
            appleServiceID: "a",
            googleClientID: "b",
        )
        #expect(config.socialSignInURL.absoluteString == "https://auth.catlaser.example/api/auth/sign-in/social")
    }

    @Test
    func socialSignInURLPreservesBasePath() throws {
        let base = URL(string: "https://auth.catlaser.example/prefix")!
        let config = try AuthConfig(
            baseURL: base,
            appleServiceID: "a",
            googleClientID: "b",
        )
        #expect(config.socialSignInURL.absoluteString == "https://auth.catlaser.example/prefix/api/auth/sign-in/social")
    }

    @Test
    func signOutURLIsCorrect() throws {
        let config = try AuthConfig(
            baseURL: validBaseURL,
            appleServiceID: "a",
            googleClientID: "b",
        )
        #expect(config.signOutURL.absoluteString == "https://auth.catlaser.example/api/auth/sign-out")
    }

    @Test
    func acceptsUppercaseHTTPSScheme() throws {
        let url = URL(string: "HTTPS://auth.example")!
        let config = try AuthConfig(
            baseURL: url,
            appleServiceID: "a",
            googleClientID: "b",
        )
        #expect(config.baseURL == url)
    }

    @Test
    func magicLinkRequestURLIsCorrect() throws {
        let config = try AuthConfig(
            baseURL: validBaseURL,
            appleServiceID: "a",
            googleClientID: "b",
        )
        #expect(config.magicLinkRequestURL.absoluteString
            == "https://auth.catlaser.example/api/auth/sign-in/magic-link")
    }

    @Test
    func magicLinkVerifyURLIsCorrect() throws {
        let config = try AuthConfig(
            baseURL: validBaseURL,
            appleServiceID: "a",
            googleClientID: "b",
        )
        #expect(config.magicLinkVerifyURL.absoluteString
            == "https://auth.catlaser.example/api/auth/magic-link/verify")
    }

    @Test
    func universalLinkHostIsLowercaseOfBaseHost() throws {
        let url = URL(string: "HTTPS://Auth.CatLaser.Example")!
        let config = try AuthConfig(
            baseURL: url,
            appleServiceID: "a",
            googleClientID: "b",
        )
        #expect(config.universalLinkHost == "auth.catlaser.example")
    }

    @Test
    func universalLinkPathMatchesVerifyURLPath() throws {
        let config = try AuthConfig(
            baseURL: validBaseURL,
            appleServiceID: "a",
            googleClientID: "b",
        )
        #expect(config.universalLinkPath == "/api/auth/magic-link/verify")
    }

    @Test
    func universalLinkPathRespectsBaseURLPrefix() throws {
        let base = URL(string: "https://auth.catlaser.example/tenants/42")!
        let config = try AuthConfig(
            baseURL: base,
            appleServiceID: "a",
            googleClientID: "b",
        )
        #expect(config.universalLinkPath == "/tenants/42/api/auth/magic-link/verify")
    }
}
