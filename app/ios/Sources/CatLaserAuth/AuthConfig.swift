import Foundation

public struct AuthConfig: Sendable, Equatable {
    public let baseURL: URL
    public let appleServiceID: String
    public let googleClientID: String
    /// The app's bundle identifier. Used to validate that the Google OIDC
    /// redirect URL belongs to this app. Taken explicitly (not from
    /// `Bundle.main`) so the config is deterministic in tests and cross-
    /// compilation builds.
    public let bundleID: String
    /// Host the magic-link email points at. This MUST be different from the
    /// API host path — the email link resolves via Universal Links (AASA)
    /// into the app, and must NOT double as a server API handler.
    ///
    /// Safari fallback (user taps link on a device without the app, or
    /// before AASA has loaded) must land on an inert handler that does
    /// nothing, so an attacker who redirects a victim to the link from
    /// outside the app cannot complete sign-in.
    public let universalLinkHost: String
    /// Path served by the Universal Link handler. Distinct from the API's
    /// verify endpoint path (which is `/api/auth/magic-link/verify`).
    public let universalLinkPath: String
    /// Hosts trusted to receive the Google OIDC redirect. Redirect URLs
    /// with an https scheme and a host in this set are accepted; all other
    /// redirects (custom schemes, http, mismatched hosts) are rejected at
    /// provider-init time.
    ///
    /// The host(s) listed here MUST serve an `apple-app-site-association`
    /// file associating the path with this app's bundle identifier, so
    /// that iOS routes the OAuth callback into the app rather than Safari.
    public let oauthRedirectHosts: Set<String>

    public init(
        baseURL: URL,
        appleServiceID: String,
        googleClientID: String,
        bundleID: String,
        universalLinkHost: String,
        universalLinkPath: String,
        oauthRedirectHosts: Set<String>,
    ) throws(AuthConfigError) {
        guard let scheme = baseURL.scheme?.lowercased(), scheme == "https" else {
            throw AuthConfigError.insecureBaseURL
        }
        guard let baseHost = baseURL.host, !baseHost.isEmpty else {
            throw AuthConfigError.invalidBaseURL
        }
        let trimmed = appleServiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AuthConfigError.missingAppleServiceID
        }
        let googleTrimmed = googleClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !googleTrimmed.isEmpty else {
            throw AuthConfigError.missingGoogleClientID
        }
        let bundleTrimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleTrimmed.isEmpty else {
            throw AuthConfigError.missingBundleID
        }
        let linkHost = universalLinkHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !linkHost.isEmpty, Self.isPlausibleHost(linkHost) else {
            throw AuthConfigError.invalidUniversalLinkHost
        }
        guard universalLinkPath.hasPrefix("/"),
              !universalLinkPath.contains("?"),
              !universalLinkPath.contains("#"),
              !universalLinkPath.contains(" ")
        else {
            throw AuthConfigError.invalidUniversalLinkPath
        }
        // The universal-link path must NOT be the API verify endpoint —
        // that would put Safari/non-AASA traffic on the same URL that
        // completes sign-in, defeating the device-binding check.
        let apiVerifyPath = Self.apiVerifyPath(baseURL: baseURL)
        guard universalLinkPath != apiVerifyPath else {
            throw AuthConfigError.universalLinkPathCollidesWithAPI
        }
        guard !oauthRedirectHosts.isEmpty else {
            throw AuthConfigError.missingOAuthRedirectHost
        }
        let redirectHosts = Set(oauthRedirectHosts.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        guard redirectHosts.allSatisfy(Self.isPlausibleHost) else {
            throw AuthConfigError.invalidOAuthRedirectHost
        }
        self.baseURL = baseURL
        self.appleServiceID = trimmed
        self.googleClientID = googleTrimmed
        self.bundleID = bundleTrimmed
        self.universalLinkHost = linkHost
        self.universalLinkPath = universalLinkPath
        self.oauthRedirectHosts = redirectHosts
    }

    public var socialSignInURL: URL {
        baseURL.appendingPathComponent("api/auth/sign-in/social")
    }

    public var signOutURL: URL {
        baseURL.appendingPathComponent("api/auth/sign-out")
    }

    public var magicLinkRequestURL: URL {
        baseURL.appendingPathComponent("api/auth/sign-in/magic-link")
    }

    public var magicLinkVerifyURL: URL {
        baseURL.appendingPathComponent("api/auth/magic-link/verify")
    }

    /// Absolute URL the server should embed in the magic-link email. This
    /// is the Universal Link entry point; the app extracts the token and
    /// then POSTs to `magicLinkVerifyURL` with the attestation header.
    public var magicLinkCallbackURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = universalLinkHost
        components.path = universalLinkPath
        guard let url = components.url else {
            preconditionFailure("universalLinkHost/Path validated at init but still failed to form URL")
        }
        return url
    }

    private static func apiVerifyPath(baseURL: URL) -> String {
        baseURL.appendingPathComponent("api/auth/magic-link/verify").path
    }

    private static func isPlausibleHost(_ candidate: String) -> Bool {
        guard !candidate.isEmpty, candidate.count <= 253 else { return false }
        // Reject anything that looks like it has a scheme, path, port, or
        // userinfo smuggled in. Host is host-only.
        let disallowed = CharacterSet(charactersIn: "/?#@:\\ ").union(.whitespacesAndNewlines).union(.controlCharacters)
        if candidate.unicodeScalars.contains(where: disallowed.contains) {
            return false
        }
        // RFC 1035: labels start/end with alphanumeric, contain alphanumeric
        // or hyphen, up to 63 chars. Accept Unicode via IDN would require
        // Punycode handling; keep hosts ASCII for simplicity.
        let labels = candidate.split(separator: ".")
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard label.first != "-", label.last != "-" else { return false }
            for scalar in label.unicodeScalars {
                let ok = (scalar.value >= 0x30 && scalar.value <= 0x39)
                    || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                    || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                    || scalar == "-"
                guard ok else { return false }
            }
        }
        return true
    }
}

public enum AuthConfigError: Error, Equatable, Sendable {
    case insecureBaseURL
    case invalidBaseURL
    case missingAppleServiceID
    case missingGoogleClientID
    case missingBundleID
    case invalidUniversalLinkHost
    case invalidUniversalLinkPath
    case universalLinkPathCollidesWithAPI
    case missingOAuthRedirectHost
    case invalidOAuthRedirectHost
}
