import Foundation

/// Strict policy for OAuth redirect URLs.
///
/// Accepts **only** HTTPS Universal Links whose host appears in an explicit
/// allowlist. Rejects:
///
/// * Custom URL schemes (iOS offers no ownership verification — another
///   app can claim the same scheme and intercept the authorization code).
/// * `http://` (no transport integrity).
/// * Any URL with userinfo (`user:password@host`) or an explicit port.
/// * Paths containing control characters.
///
/// Each allowed host MUST publish an `apple-app-site-association` file
/// registering the redirect path with this app's bundle identifier. If
/// AASA is absent or malformed, iOS falls back to Safari and the flow
/// fails closed — which is the desired behaviour on a device where the
/// association hasn't been verified.
public enum OAuthRedirectPolicy {
    public static func validate(_ url: URL, allowedHosts: Set<String>) throws(AuthError) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            throw .invalidRedirectURL(
                "redirect URL must use https scheme (got \(url.scheme ?? "nil"))",
            )
        }
        guard url.user == nil, url.password == nil else {
            throw .invalidRedirectURL("redirect URL must not contain userinfo")
        }
        if url.port != nil {
            throw .invalidRedirectURL("redirect URL must not specify a port")
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw .invalidRedirectURL("redirect URL has no host")
        }
        let normalizedAllowed = Set(allowedHosts.map { $0.lowercased() })
        guard !normalizedAllowed.isEmpty else {
            throw .invalidRedirectURL("redirect host allowlist is empty — refuse all")
        }
        guard normalizedAllowed.contains(host) else {
            throw .invalidRedirectURL(
                "redirect URL host '\(host)' is not in the allowed set \(normalizedAllowed.sorted())",
            )
        }
        if url.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw .invalidRedirectURL("redirect URL path contains control characters")
        }
    }
}
