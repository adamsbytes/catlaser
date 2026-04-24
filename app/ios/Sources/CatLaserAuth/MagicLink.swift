import Foundation

/// Parsed, validated 6-digit backup code — the sibling path of the magic-
/// link URL for users whose email lives on a different device than the
/// one that requested the sign-in. Whitespace and hyphens are stripped
/// before validation so a user who types `"123 456"` or `"123-456"`
/// lands on the same canonical form the server HMAC-hashes.
///
/// The server binds every code to the requesting device's Secure-Enclave
/// key at request time and rejects any other device that attempts to
/// redeem it. Validation here is purely structural — the crypto binding
/// is enforced at the server.
public struct BackupCode: Sendable, Equatable {
    /// Expected digit count in the canonical form. Must match the
    /// server-side `MAGIC_LINK_CODE_DIGITS` constant; a drift between
    /// the two would surface as a body-validation rejection server-side
    /// rather than a silent misbehaviour.
    public static let digitCount = 6

    /// Canonicalised 6-digit value ready for submission. Never contains
    /// whitespace or hyphens regardless of what the user typed.
    public let canonical: String

    public init(_ raw: String) throws(AuthError) {
        let stripped = raw.unicodeScalars.reduce(into: "") { acc, scalar in
            if scalar == "-" { return }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return }
            acc.unicodeScalars.append(scalar)
        }
        guard stripped.count == Self.digitCount else {
            throw AuthError.invalidMagicLink("backup code must be \(Self.digitCount) digits")
        }
        for scalar in stripped.unicodeScalars {
            // ASCII '0'..'9'. Reject every non-digit scalar so a
            // fullwidth-digit paste (U+FF10..U+FF19) cannot sneak past a
            // `Int` parse that would otherwise accept it — the server's
            // HMAC is computed over the byte stream, not the parsed
            // integer, so we must match the canonical byte shape here.
            guard (0x30 ... 0x39).contains(scalar.value) else {
                throw AuthError.invalidMagicLink("backup code must be \(Self.digitCount) digits")
            }
        }
        self.canonical = stripped
    }
}

/// Parsed, validated Universal Link payload — the result of the user tapping
/// the magic-link button in their email. Host and path are checked against
/// `AuthConfig`; an attacker-controlled `auth.example.com.evil.com` or
/// `http://auth.example.com/...` must never produce a valid callback.
public struct MagicLinkCallback: Sendable, Equatable {
    /// Upper bound on the raw (percent-decoded) token UTF-8 byte count.
    ///
    /// Better-auth magic-link tokens are 32-byte base64url-no-pad values —
    /// 43 characters. 256 bytes is ~6× that, generous enough to absorb
    /// any reasonable server-side rotation (longer tokens, different
    /// encoding) while still small enough to shut down obvious abuse
    /// vectors: a crafted Universal Link with a multi-megabyte `token=`
    /// payload would otherwise be decoded and then echoed back to the
    /// server in the verify request URL. We fail fast at the callback
    /// boundary instead of letting `URLComponents` build a giant URL.
    public static let maxTokenBytes = 256

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
        // Length cap. Measured in UTF-8 bytes (not Character count) so
        // multi-byte scalars cannot bypass the limit.
        if raw.utf8.count > Self.maxTokenBytes {
            throw AuthError.invalidMagicLink(
                "token exceeds \(Self.maxTokenBytes) bytes (got \(raw.utf8.count))",
            )
        }
        self.token = raw
    }
}
