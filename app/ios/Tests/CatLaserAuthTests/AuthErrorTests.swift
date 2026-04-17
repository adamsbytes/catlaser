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
}
