import Foundation

/// Parsed, validated Universal Link payload — the result of the user tapping
/// the magic-link button in their email. Host and path are checked against
/// `AuthConfig`; an attacker-controlled `auth.example.com.evil.com` or
/// `http://auth.example.com/...` must never produce a valid callback.
public struct MagicLinkCallback: Sendable, Equatable {
    public let token: String

    public init(
        url: URL,
        config: AuthConfig,
        tokenParam: String = "token",
    ) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            throw AuthError.invalidMagicLink("expected https scheme")
        }
        // Reject userinfo (credential smuggling) — `https://evil@host/...` can
        // mislead a lax host check.
        guard url.user == nil, url.password == nil else {
            throw AuthError.invalidMagicLink("userinfo not permitted in callback URL")
        }
        guard let host = url.host?.lowercased(), host == config.universalLinkHost else {
            throw AuthError.invalidMagicLink("host mismatch")
        }
        // Reject non-default ports — the Universal Link AASA registration is
        // host-only; any port suggests a forged URL.
        if let port = url.port {
            throw AuthError.invalidMagicLink("unexpected port: \(port)")
        }
        // Compare against the configured path. `url.path` is already
        // percent-decoded; the config path is literal.
        guard url.path == config.universalLinkPath else {
            throw AuthError.invalidMagicLink("path mismatch")
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AuthError.invalidMagicLink("unparseable URL")
        }
        let items = components.queryItems ?? []
        let matches = items.filter { $0.name == tokenParam }
        guard matches.count == 1 else {
            throw AuthError.invalidMagicLink(
                matches.isEmpty ? "missing token" : "duplicate token parameter",
            )
        }
        guard let raw = matches[0].value,
              !raw.isEmpty
        else {
            throw AuthError.invalidMagicLink("empty token")
        }
        // `URLComponents.queryItems` already percent-decodes values. Reject
        // control characters and whitespace — better-auth tokens are base64-
        // url safe and never contain them, so any appearance is a signal of
        // tampering.
        let disallowed = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        if raw.unicodeScalars.contains(where: disallowed.contains) {
            throw AuthError.invalidMagicLink("token contains control characters")
        }
        self.token = raw
    }
}
