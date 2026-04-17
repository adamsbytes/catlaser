import Foundation

public enum AuthError: Error, Equatable, Sendable {
    case cancelled
    case credentialInvalid(String?)
    case missingIDToken
    case missingBearerToken
    case serverError(status: Int, message: String?)
    case network(NetworkFailure)
    case malformedResponse(String?)
    case keychain(OSStatusCode)
    case providerUnavailable(String)
    case providerInternal(String)

    public var isRetriable: Bool {
        switch self {
        case .network: true
        case let .serverError(status, _): status >= 500
        default: false
        }
    }
}

public struct NetworkFailure: Equatable, Sendable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

public struct OSStatusCode: Equatable, Sendable {
    public let rawValue: Int32

    public init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }
}
