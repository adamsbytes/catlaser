import Foundation

/// Minimal JWT payload inspection — enough to verify a pre-committed
/// claim without pulling in a full JWT library and without verifying the
/// signature (the server does that; this is defence-in-depth against a
/// compromised in-app browser or hooked SDK returning a tampered token).
///
/// The JOSE format is `header.payload.signature` where each segment is
/// base64url-no-pad. The middle segment is a JSON object of claims. We
/// only need string-valued claims here.
public enum IDTokenClaims {
    /// Decode the JWT payload and require that the `nonce` claim is
    /// present and byte-equal to `expectedNonce`. Signature validation is
    /// the server's responsibility.
    public static func verifyNonce(idToken: String, expectedNonce: String) throws(AuthError) {
        let segments = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else {
            throw .idTokenClaimMismatch(
                "ID token is not a JWT (expected 3 dot-separated segments, got \(segments.count))",
            )
        }
        guard let payload = decodeBase64URL(String(segments[1])) else {
            throw .idTokenClaimMismatch("ID token payload segment is not valid base64url")
        }
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                throw AuthError.idTokenClaimMismatch("ID token payload is not a JSON object")
            }
            object = parsed
        } catch let error as AuthError {
            throw error
        } catch {
            throw .idTokenClaimMismatch(
                "ID token payload JSON decode failed: \(error.localizedDescription)",
            )
        }
        guard let nonceClaim = object["nonce"] as? String else {
            throw .idTokenClaimMismatch("ID token has no `nonce` claim")
        }
        guard constantTimeEquals(nonceClaim, expectedNonce) else {
            throw .idTokenClaimMismatch(
                "ID token `nonce` claim does not match the value sent in the authorization request",
            )
        }
    }

    /// Constant-time string compare. The nonce is effectively a
    /// pre-committed secret; leaking length-matched prefix information via
    /// timing could help an adversary craft a forged token. Constant-time
    /// here is belt-and-suspenders against exotic side channels.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var diff: UInt8 = 0
        for index in 0 ..< lhsBytes.count {
            diff |= lhsBytes[index] ^ rhsBytes[index]
        }
        return diff == 0
    }

    static func decodeBase64URL(_ segment: String) -> Data? {
        var s = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.utf8.count % 4
        if remainder != 0 {
            s.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: s)
    }
}
