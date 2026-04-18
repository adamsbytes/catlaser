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
/// * `.missingSession` — local bearer store is empty; the user is
///   genuinely signed out. UI routes to sign-in.
/// * `.sessionExpired` — server returned HTTP 401 on an otherwise-
///   valid protected call. The bearer stored locally was not accepted
///   server-side (expired, revoked, bearer/session mismatch). The
///   fix is to sign in again — the pairing itself is NOT invalidated
///   and the keychain row must NOT be wiped on this signal. Kept
///   distinct from `.missingSession` because the two require different
///   UI treatment (`.missingSession` may never have had a session;
///   `.sessionExpired` had one that stopped being accepted) and
///   because the pairing re-verification path treats only an
///   authoritative 2xx-list-that-omits-the-device as "no longer
///   owned" — a 401 is an authentication failure, not an ownership
///   revocation.
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
/// * `.authRevoked` — the device daemon reported that the current
///   user's SPKI is no longer authorized. The supervisor treats this
///   as terminal: no reconnect attempts, the pairing row is wiped,
///   the user is routed back through the pairing flow. Distinct from
///   `.missingSession` (which indicates the coordination server no
///   longer has a session for the bearer) because the signal arrives
///   from the device, not the coord server.
public enum PairingError: Error, Equatable, Sendable {
    case invalidCode(PairingCodeError)
    case missingSession
    case sessionExpired(message: String?)
    case codeAlreadyUsed(message: String?)
    case codeExpired(message: String?)
    case codeNotFound(message: String?)
    case rateLimited(message: String?)
    case serverError(status: Int, message: String?)
    case network(String)
    case invalidServerResponse(String)
    case storage(String)
    case attestation(String)
    case authRevoked(message: String)

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
