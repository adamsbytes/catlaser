import Foundation
import Testing

@testable import CatLaserAuth

@Suite("IDTokenClaims.verifyNonce")
struct IDTokenClaimsNonceTests {
    /// Build a JWT with whatever payload is supplied. The signature segment
    /// is junk — this module never verifies signatures, only structure and
    /// the `nonce` claim.
    private func makeToken(payload: [String: Any]) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"])
        let body = try JSONSerialization.data(withJSONObject: payload)
        let signature = Data("not-a-real-signature".utf8)
        return [header, body, signature].map(Self.base64URLNoPad).joined(separator: ".")
    }

    @Test
    func acceptsTokenWithMatchingNonce() throws {
        let token = try makeToken(payload: ["nonce": "abc-123", "sub": "user-1"])
        try IDTokenClaims.verifyNonce(idToken: token, expectedNonce: "abc-123")
    }

    @Test
    func rejectsTokenWithMismatchedNonce() throws {
        let token = try makeToken(payload: ["nonce": "other", "sub": "user-1"])
        expectMismatch(token: token, expectedNonce: "abc-123", matching: "match")
    }

    @Test
    func rejectsTokenWithoutNonceClaim() throws {
        let token = try makeToken(payload: ["sub": "user-1"])
        expectMismatch(token: token, expectedNonce: "abc-123", matching: "no `nonce`")
    }

    @Test
    func rejectsTokenWithNonStringNonce() throws {
        let token = try makeToken(payload: ["nonce": 42, "sub": "user-1"])
        expectMismatch(token: token, expectedNonce: "42", matching: "no `nonce`")
    }

    @Test
    func rejectsNonJWTString() {
        expectMismatch(token: "i am not a jwt", expectedNonce: "n", matching: "3 dot-separated")
    }

    @Test
    func rejectsTwoSegmentToken() {
        expectMismatch(token: "aaaa.bbbb", expectedNonce: "n", matching: "3 dot-separated")
    }

    @Test
    func rejectsInvalidBase64Payload() {
        let token = "aaaa.this$is$not$b64.signature"
        expectMismatch(token: token, expectedNonce: "n", matching: "base64url")
    }

    @Test
    func rejectsNonJSONPayload() throws {
        let header = Self.base64URLNoPad(try JSONSerialization.data(withJSONObject: ["alg": "none"]))
        let payload = Self.base64URLNoPad(Data("not json".utf8))
        let sig = Self.base64URLNoPad(Data("x".utf8))
        expectMismatch(
            token: "\(header).\(payload).\(sig)",
            expectedNonce: "n",
            matching: "json decode",
        )
    }

    @Test
    func rejectsPayloadThatIsAJSONArray() throws {
        let header = Self.base64URLNoPad(try JSONSerialization.data(withJSONObject: ["alg": "none"]))
        let payload = Self.base64URLNoPad(try JSONSerialization.data(withJSONObject: ["not", "an", "object"]))
        let sig = Self.base64URLNoPad(Data("x".utf8))
        expectMismatch(
            token: "\(header).\(payload).\(sig)",
            expectedNonce: "n",
            matching: "json object",
        )
    }

    @Test
    func acceptsNonceWithSpecialCharacters() throws {
        // Real magic-link nonces are base64url of random bytes; our match
        // must work on any string, including ones with `-` and `_`.
        let weird = "abc-DEF_123-xyz"
        let token = try makeToken(payload: ["nonce": weird])
        try IDTokenClaims.verifyNonce(idToken: token, expectedNonce: weird)
    }

    @Test
    func rejectsCloseButNotEqualNonce() throws {
        // Trailing-byte mismatch must still reject — defend against
        // length-equal partial matches.
        let near = "abc-DEF_123-xyz"
        let off = "abc-DEF_123-xyY"
        let token = try makeToken(payload: ["nonce": near])
        expectMismatch(token: token, expectedNonce: off, matching: "match")
    }

    @Test
    func rejectsExtraPaddingDifferencesAsMismatch() throws {
        // A common JWT variant adds '=' padding to base64url segments. Our
        // decoder tolerates both; if tolerance were broken, tokens would
        // either fail to decode or produce wrong payloads. Construct the
        // token with padding and verify it still works.
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256"])
        let payload = try JSONSerialization.data(withJSONObject: ["nonce": "x"])
        let sig = Data("s".utf8)
        let padded = [header, payload, sig]
            .map { $0.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") }
            .joined(separator: ".")
        try IDTokenClaims.verifyNonce(idToken: padded, expectedNonce: "x")
    }

    @Test
    func constantTimeEqualsBehavesLikeStandardEquals() {
        #expect(IDTokenClaims.constantTimeEquals("abc", "abc"))
        #expect(!IDTokenClaims.constantTimeEquals("abc", "abd"))
        #expect(!IDTokenClaims.constantTimeEquals("abc", "abcd"))
        #expect(!IDTokenClaims.constantTimeEquals("", "x"))
        #expect(IDTokenClaims.constantTimeEquals("", ""))
    }

    private func expectMismatch(
        token: String,
        expectedNonce: String,
        matching contains: String,
        sourceLocation: SourceLocation = #_sourceLocation,
    ) {
        do {
            try IDTokenClaims.verifyNonce(idToken: token, expectedNonce: expectedNonce)
            Issue.record("expected idTokenClaimMismatch", sourceLocation: sourceLocation)
        } catch let AuthError.idTokenClaimMismatch(message) {
            #expect(
                message.lowercased().contains(contains.lowercased()),
                "message '\(message)' did not contain '\(contains)'",
                sourceLocation: sourceLocation,
            )
        } catch {
            Issue.record("unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }

    private static func base64URLNoPad(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
