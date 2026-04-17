import Foundation

/// Client-side email validation used to disable the "Send magic link"
/// button and surface an inline error before we burn a server round-trip.
///
/// The server is the authority — `AuthClient.requestMagicLink` re-checks
/// the same constraints and returns `.invalidEmail` on a 400. This pre-
/// flight exists solely so the user sees "enter a valid email address"
/// as feedback in the text field rather than as a post-request error
/// banner.
///
/// Rules match the `AuthClient` regex (`[^\s@]+@[^\s@]+\.[^\s@]+`) plus:
///
/// * Input is trimmed of surrounding whitespace before checking (a user
///   paste with a trailing newline is valid).
/// * Upper bound of 320 UTF-8 bytes per RFC 3696 §3 — anything longer
///   cannot possibly be a mailbox and we do not let the client
///   accidentally encode a multi-megabyte body.
public enum EmailValidator {
    /// Upper bound on the UTF-8 size of a valid email address. 320 is
    /// the longest address permitted by RFC 3696 §3: 64-octet local
    /// part + "@" + 255-octet domain.
    public static let maxBytes = 320

    private static let pattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#,
            options: [],
        )
    }()

    public static func isValid(_ candidate: String) -> Bool {
        let trimmed = normalized(candidate)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxBytes else {
            return false
        }
        // NSRegularExpression's `\s` matches only ASCII whitespace plus
        // a small Unicode whitespace set — it explicitly does NOT
        // include C0 control codes such as BEL (U+0007) or BS
        // (U+0008). Reject any remaining control character outright so
        // malformed input that happens to slip past the pattern is
        // still kicked out before we send it to the server.
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return false
        }
        guard let regex = pattern else { return false }
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        return regex.firstMatch(in: trimmed, options: [], range: range) != nil
    }

    /// Strip surrounding whitespace + newlines. Leaves internal content
    /// untouched — the regex will reject anything embedded-invalid.
    public static func normalized(_ candidate: String) -> String {
        candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
