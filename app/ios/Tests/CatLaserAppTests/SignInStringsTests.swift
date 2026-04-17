import Foundation
import Testing

@testable import CatLaserApp
@testable import CatLaserAuth

@Suite("SignInStrings")
struct SignInStringsTests {
    @Test
    func everyAuthErrorCaseProducesNonEmptyMessage() {
        // Coverage sanity — any new `AuthError` case added in the auth
        // layer must remain user-presentable. If the switch in
        // `SignInStrings.message(for:)` ever goes non-exhaustive the
        // build breaks; this test guards against the complementary bug
        // of returning an empty string from a case.
        let cases: [AuthError] = [
            .cancelled,
            .credentialInvalid("msg"),
            .missingIDToken,
            .missingBearerToken,
            .serverError(status: 502, message: "bad gateway"),
            .serverError(status: 400, message: "bad request"),
            .network(NetworkFailure("offline")),
            .malformedResponse("bad json"),
            .keychain(OSStatusCode(-25300)),
            .providerUnavailable("apple"),
            .providerInternal("exploded"),
            .invalidEmail,
            .invalidMagicLink("expired"),
            .attestationFailed("bad"),
            .secureEnclaveUnavailable("no SE"),
            .invalidRedirectURL("custom scheme"),
            .idTokenClaimMismatch("bad nonce"),
            .biometricFailed(status: -128),
            .biometricUnavailable("not enrolled"),
        ]
        for err in cases {
            let msg = SignInStrings.message(for: err)
            #expect(!msg.isEmpty, "empty message for \(err)")
            #expect(!msg.contains("Optional("), "leaked optional-wrapper for \(err)")
        }
    }

    @Test
    func fiveHundredMapsToRetryMessage() {
        let msg = SignInStrings.message(for: .serverError(status: 500, message: nil))
        #expect(msg.lowercased().contains("try again"))
    }

    @Test
    func fourHundredMapsToRejectedMessage() {
        let msg = SignInStrings.message(for: .serverError(status: 400, message: nil))
        #expect(msg.lowercased().contains("rejected"))
    }

    @Test
    func invalidMagicLinkMessageHintsAtExpiryOrUse() {
        let msg = SignInStrings.message(for: .invalidMagicLink("expired"))
        // User-facing remediation implies the common root causes
        // without echoing the server's internal code.
        let lower = msg.lowercased()
        #expect(lower.contains("expired") || lower.contains("already been used") || lower.contains("valid"))
    }

    @Test
    func networkMessageMentionsConnection() {
        let msg = SignInStrings.message(for: .network(NetworkFailure("timeout")))
        let lower = msg.lowercased()
        #expect(lower.contains("connection") || lower.contains("offline"))
    }

    @Test
    func emailSentBodyInterpolatesAddress() {
        let body = SignInStrings.emailSentBody("cat@example.com")
        #expect(body.contains("cat@example.com"))
    }
}
