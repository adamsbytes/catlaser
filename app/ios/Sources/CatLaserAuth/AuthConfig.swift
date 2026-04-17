import Foundation

public struct AuthConfig: Sendable, Equatable {
    public let baseURL: URL
    public let appleServiceID: String
    public let googleClientID: String

    public init(
        baseURL: URL,
        appleServiceID: String,
        googleClientID: String,
    ) throws(AuthConfigError) {
        guard let scheme = baseURL.scheme?.lowercased(), scheme == "https" else {
            throw AuthConfigError.insecureBaseURL
        }
        guard let host = baseURL.host, !host.isEmpty else {
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
        self.baseURL = baseURL
        self.appleServiceID = trimmed
        self.googleClientID = googleTrimmed
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

    /// The exact host (lowercased) the app should accept a Universal Link callback from.
    public var universalLinkHost: String {
        (baseURL.host ?? "").lowercased()
    }

    /// The exact path (including base-URL prefix if any) the app should accept a Universal Link
    /// callback at. The email link resolves to this path with a `token` query parameter.
    public var universalLinkPath: String {
        magicLinkVerifyURL.path
    }
}

public enum AuthConfigError: Error, Equatable, Sendable {
    case insecureBaseURL
    case invalidBaseURL
    case missingAppleServiceID
    case missingGoogleClientID
}
