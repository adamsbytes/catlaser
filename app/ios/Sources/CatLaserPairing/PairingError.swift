import CatLaserAuth
import CatLaserDevice
import Foundation

/// Failure modes for the pairing + connection flows.
///
/// Surfaced by `PairingClient`, `PairingViewModel`, `ConnectionManager`,
/// and the Keychain endpoint store. The categories are deliberately
/// coarser than the underlying library errors (`AuthError`,
/// `DeviceEndpointError`, `PairingCodeError`) — tests and the UI
/// assert on a category, not on every wrapped string.
///
/// Each case exists because a caller needs to distinguish it for
/// either a localised message or a recovery action:
///
/// * `.invalidCode` — user-scanned QR was malformed; UI prompts to
///   scan again or tap manual entry.
/// * `.missingSession` — user is signed out; UI routes to sign-in.
/// * `.codeAlreadyUsed` — server 409; UI prompts to get a fresh QR
///   from the device.
/// * `.codeExpired` — server 410; same remediation as above.
/// * `.codeNotFound` — server 404; same.
/// * `.rateLimited` — server 429; UI prompts to wait.
/// * `.serverError` — 5xx; UI prompts to retry.
/// * `.network` — underlying HTTP client failed; retry.
/// * `.invalidServerResponse` — protocol mismatch; log & retry.
/// * `.storage` — keychain or disk write failed; UI prompts to retry.
/// * `.attestation` — device attestation signing failed; propagates
///   from `SignedHTTPClient` (e.g. SE unavailable).
public enum PairingError: Error, Equatable, Sendable {
    case invalidCode(PairingCodeError)
    case missingSession
    case codeAlreadyUsed(message: String?)
    case codeExpired(message: String?)
    case codeNotFound(message: String?)
    case rateLimited(message: String?)
    case serverError(status: Int, message: String?)
    case network(String)
    case invalidServerResponse(String)
    case storage(String)
    case attestation(String)

    /// Lift an `AuthError` arising from the signed HTTP client into a
    /// `PairingError`. Centralised so every call site renders the same
    /// user-facing category for the same underlying cause.
    public static func from(_ authError: AuthError) -> PairingError {
        switch authError {
        case .missingBearerToken:
            .missingSession
        case let .network(failure):
            .network(failure.description)
        case let .malformedResponse(message):
            .invalidServerResponse(message ?? "malformed response")
        case let .serverError(status, message):
            .serverError(status: status, message: message)
        case let .attestationFailed(message):
            .attestation(message)
        case let .secureEnclaveUnavailable(message):
            .attestation(message)
        case let .providerInternal(message):
            .invalidServerResponse(message)
        case let .providerUnavailable(message):
            .attestation(message)
        case let .keychain(status):
            .storage("keychain OSStatus \(status.rawValue)")
        case let .biometricFailed(status):
            .storage("biometric failed status \(status)")
        case let .biometricUnavailable(message):
            .storage(message)
        case .cancelled:
            // A cancelled auth flow inside a pairing exchange is a
            // protocol bug — pairing itself never presents the sign-in
            // sheet, so `cancelled` should not surface here. Map to a
            // distinctive bucket so diagnostics can flag it.
            .invalidServerResponse("auth flow reported cancelled during pairing")
        case .invalidEmail,
             .invalidMagicLink,
             .invalidRedirectURL,
             .credentialInvalid,
             .missingIDToken,
             .idTokenClaimMismatch:
            // These cases belong to the sign-in ceremonies, not the
            // pairing exchange. Defensive fallback only.
            .invalidServerResponse(String(describing: authError))
        }
    }
}
