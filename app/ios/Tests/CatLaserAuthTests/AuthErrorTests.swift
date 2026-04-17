import Foundation
import Testing

@testable import CatLaserAuth

@Suite("AuthError")
struct AuthErrorTests {
    @Test
    func equality() {
        #expect(AuthError.cancelled == AuthError.cancelled)
        #expect(AuthError.cancelled != AuthError.missingIDToken)
        #expect(AuthError.credentialInvalid("x") == AuthError.credentialInvalid("x"))
        #expect(AuthError.credentialInvalid("x") != AuthError.credentialInvalid("y"))
        #expect(AuthError.serverError(status: 500, message: "m") == AuthError.serverError(status: 500, message: "m"))
        #expect(AuthError.serverError(status: 500, message: nil) != AuthError.serverError(status: 502, message: nil))
    }

    @Test
    func networkFailureEquality() {
        let a = AuthError.network(NetworkFailure("timeout"))
        let b = AuthError.network(NetworkFailure("timeout"))
        let c = AuthError.network(NetworkFailure("other"))
        #expect(a == b)
        #expect(a != c)
    }

    @Test
    func keychainEquality() {
        let a = AuthError.keychain(OSStatusCode(-25_300))
        let b = AuthError.keychain(OSStatusCode(-25_300))
        let c = AuthError.keychain(OSStatusCode(-25_301))
        #expect(a == b)
        #expect(a != c)
    }

    @Test
    func isRetriableFlagsServerErrors() {
        #expect(AuthError.network(NetworkFailure("x")).isRetriable)
        #expect(AuthError.serverError(status: 500, message: nil).isRetriable)
        #expect(AuthError.serverError(status: 503, message: nil).isRetriable)
        #expect(AuthError.serverError(status: 499, message: nil).isRetriable == false)
        #expect(AuthError.serverError(status: 400, message: nil).isRetriable == false)
        #expect(AuthError.cancelled.isRetriable == false)
        #expect(AuthError.credentialInvalid(nil).isRetriable == false)
        #expect(AuthError.missingIDToken.isRetriable == false)
        #expect(AuthError.missingBearerToken.isRetriable == false)
        #expect(AuthError.keychain(OSStatusCode(-1)).isRetriable == false)
    }

    @Test
    func doesNotLeakSensitiveTokenInEquality() {
        let err = AuthError.credentialInvalid("server rejected token abc123")
        #expect(err == AuthError.credentialInvalid("server rejected token abc123"))
    }

    @Test
    func invalidMagicLinkEquality() {
        #expect(AuthError.invalidMagicLink("host mismatch") == AuthError.invalidMagicLink("host mismatch"))
        #expect(AuthError.invalidMagicLink(nil) == AuthError.invalidMagicLink(nil))
        #expect(AuthError.invalidMagicLink("a") != AuthError.invalidMagicLink("b"))
    }

    @Test
    func invalidMagicLinkNotRetriable() {
        #expect(AuthError.invalidMagicLink(nil).isRetriable == false)
        #expect(AuthError.invalidEmail.isRetriable == false)
        #expect(AuthError.attestationFailed("x").isRetriable == false)
    }

    @Test
    func attestationFailedEquality() {
        #expect(AuthError.attestationFailed("x") == AuthError.attestationFailed("x"))
        #expect(AuthError.attestationFailed("x") != AuthError.attestationFailed("y"))
        #expect(AuthError.attestationFailed("x") != AuthError.invalidEmail)
    }

    @Test
    func secureEnclaveUnavailableEquality() {
        #expect(AuthError.secureEnclaveUnavailable("no SE") == AuthError.secureEnclaveUnavailable("no SE"))
        #expect(AuthError.secureEnclaveUnavailable("a") != AuthError.secureEnclaveUnavailable("b"))
        #expect(AuthError.secureEnclaveUnavailable("x").isRetriable == false)
    }

    @Test
    func invalidRedirectURLEquality() {
        #expect(AuthError.invalidRedirectURL("bad scheme") == AuthError.invalidRedirectURL("bad scheme"))
        #expect(AuthError.invalidRedirectURL("a") != AuthError.invalidRedirectURL("b"))
        #expect(AuthError.invalidRedirectURL("x").isRetriable == false)
    }

    @Test
    func idTokenClaimMismatchEquality() {
        #expect(AuthError.idTokenClaimMismatch("nonce") == AuthError.idTokenClaimMismatch("nonce"))
        #expect(AuthError.idTokenClaimMismatch("a") != AuthError.idTokenClaimMismatch("b"))
        #expect(AuthError.idTokenClaimMismatch("x").isRetriable == false)
    }
}
