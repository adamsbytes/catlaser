import Foundation

/// Decision returned by the pairing-confirmation user-presence gate.
///
/// The pairing view model calls into a caller-supplied gate before
/// the HTTP exchange that adds a device to the user's account. The
/// gate reports one of three outcomes, and `PairingViewModel` maps
/// each to a distinct phase:
///
/// * `.allowed` — proceed with the exchange.
/// * `.cancelled` — return to the `.confirming(code)` phase silently
///   so the user can decide again or back out without being bounced
///   through an error banner. The decoded code is preserved.
/// * `.denied(reason)` — transition to `.failed(.attestation(...))`
///   with the reason embedded so the UI surfaces a recoverable
///   error path. Used for biometric-unavailable, lockout, or
///   anything else that is not a deliberate user cancel.
public enum PairingAuthOutcome: Sendable, Equatable {
    case allowed
    case cancelled
    case denied(String)
}

/// Builder-style closure the composition root threads into
/// ``PairingViewModel``. Mirrors ``LiveViewModel.AuthGate`` so the
/// two screens have a consistent shape; the composition binds this
/// to ``GatedBearerTokenStore/requirePairing()`` and maps thrown
/// errors to ``PairingAuthOutcome``. A failure to obtain user
/// presence MUST NEVER default-allow the exchange.
public typealias PairingAuthGate = @Sendable () async -> PairingAuthOutcome
