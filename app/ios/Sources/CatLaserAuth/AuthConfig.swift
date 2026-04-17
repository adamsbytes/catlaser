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
        guard baseURL.host?.isEmpty == false else {
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
}

public enum AuthConfigError: Error, Equatable, Sendable {
    case insecureBaseURL
    case invalidBaseURL
    case missingAppleServiceID
    case missingGoogleClientID
}
