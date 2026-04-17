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
    case invalidEmail
    case invalidMagicLink(String?)
    /// Failed to assemble the device attestation: canonical JSON encoding,
    /// SHA-256 hashing, identity-store lookup, or SE signing failed.
    case attestationFailed(String)
    /// Hardware Secure Enclave is absent or refused key creation / signing.
    /// Unrecoverable on this device without a repair; the app cannot sign in.
    case secureEnclaveUnavailable(String)
    /// A provider's configured redirect URL failed the strict validation
    /// check (not https, host not in allowlist, etc.). Constructed at
    /// provider-init time; never thrown from a runtime sign-in path.
    case invalidRedirectURL(String)
    /// The identity provider's returned ID token failed a client-side
    /// sanity check (malformed JWT, nonce claim missing or mismatched).
    /// The server also verifies these; this is defence in depth against a
    /// compromised webview / hooked agent returning a tampered token.
    case idTokenClaimMismatch(String)
    /// User declined biometric/passcode auth, auth returned false, or the
    /// keychain read hit `errSecUserCanceled`/`errSecAuthFailed`. Carries
    /// the underlying OSStatus where available so callers can distinguish
    /// "user said no" (retryable) from "lockout" (not).
    case biometricFailed(status: Int32)
    /// The device has no enrolled biometrics AND no passcode, or
    /// `SecAccessControlCreateWithFlags` refused to build the ACL.
    /// Unrecoverable without user action in Settings.
    case biometricUnavailable(String)

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
