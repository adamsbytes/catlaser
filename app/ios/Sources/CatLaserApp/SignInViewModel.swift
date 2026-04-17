import CatLaserAuth
import Foundation
import Observation

/// Observable view model backing the sign-in screen.
///
/// Owns:
///
/// * The `phase` state machine (see `SignInPhase`).
/// * The `emailInput` text buffer.
/// * The `emailSheetPresented` bool that drives `.sheet(isPresented:)`
///   on the magic-link entry sheet.
///
/// Delegates every credential flow to `AuthCoordinator`. This VM does
/// not talk to the network directly, does not hold the bearer token,
/// and does not reach into the keychain — those responsibilities live
/// in the `CatLaserAuth` layer.
///
/// ## Reentrancy
///
/// Every async action guards on `phase.isBusy` before starting. A
/// second tap on a sign-in button while one is already in flight is
/// dropped on the floor — we never kick off two coordinator calls from
/// one VM, which means no two concurrent Secure-Enclave signing
/// attempts, no two concurrent nonce generations, and no ambiguity
/// about which `succeeded(_)` value to publish. The UI enforces the
/// same by binding button disable state to `phase.isBusy`; the VM
/// guard exists as a belt-and-suspenders check that tests drive
/// directly without needing a SwiftUI environment.
///
/// ## Cancellation
///
/// `AuthError.cancelled` is mapped to `.idle`, not to `.failed`. A user
/// dismissing the system auth sheet is expressing intent to not sign
/// in — showing them a red error banner would be punishing behaviour.
/// Every other `AuthError` (including `.providerInternal` wrapping a
/// non-AuthError) maps to `.failed(error)`; the view presents the
/// message from `SignInStrings.message(for:)`.
///
/// ## Universal Links
///
/// `completeMagicLink(url:)` is safe to call from `.idle`,
/// `.emailSent`, and `.failed`. It is a no-op from any busy phase and
/// from `.succeeded`. That lets the host app forward every
/// `.onOpenURL` event unconditionally without coordinating with the
/// VM's current state — the VM decides whether the URL is actionable.
@MainActor
@Observable
public final class SignInViewModel {
    public private(set) var phase: SignInPhase = .idle
    public var emailInput: String = ""
    public var emailSheetPresented: Bool = false

    private let coordinator: AuthCoordinator

    public init(coordinator: AuthCoordinator) {
        self.coordinator = coordinator
    }

    init(coordinator: AuthCoordinator, initialPhase: SignInPhase) {
        self.coordinator = coordinator
        self.phase = initialPhase
    }

    /// True when `emailInput` passes client-side validation.
    public var isEmailInputValid: Bool {
        EmailValidator.isValid(emailInput)
    }

    /// True iff the "Send sign-in link" button should be enabled: no
    /// operation is in flight AND the email text is valid.
    public var canRequestMagicLink: Bool {
        !phase.isBusy && isEmailInputValid
    }

    /// Presentable message when `phase == .failed(_)`, nil otherwise.
    public var currentErrorMessage: String? {
        guard case let .failed(error) = phase else { return nil }
        return SignInStrings.message(for: error)
    }

    public func signInWithApple(context: ProviderPresentationContext) async {
        guard !phase.isBusy else { return }
        if case .succeeded = phase { return }
        phase = .authenticating(.apple)
        await runSocialSignIn {
            try await self.coordinator.signInWithApple(context: context)
        }
    }

    public func signInWithGoogle(context: ProviderPresentationContext) async {
        guard !phase.isBusy else { return }
        if case .succeeded = phase { return }
        phase = .authenticating(.google)
        await runSocialSignIn {
            try await self.coordinator.signInWithGoogle(context: context)
        }
    }

    /// Validate `emailInput`, then post a magic-link request through the
    /// coordinator. Transitions:
    ///
    /// * invalid email → `.failed(.invalidEmail)` without any network call
    /// * success → `.emailSent(normalized)` and closes the entry sheet
    /// * server / attestation / provider failure → `.failed(error)`,
    ///   sheet stays open so the user can correct and retry
    /// * user cancelled → `.idle`
    public func requestMagicLink() async {
        guard !phase.isBusy else { return }
        if case .succeeded = phase { return }
        let normalized = EmailValidator.normalized(emailInput)
        guard EmailValidator.isValid(normalized) else {
            phase = .failed(.invalidEmail)
            return
        }
        phase = .requestingMagicLink
        do {
            try await coordinator.requestMagicLink(email: normalized)
            emailSheetPresented = false
            phase = .emailSent(normalized)
        } catch AuthError.cancelled {
            phase = .idle
        } catch let error as AuthError {
            phase = .failed(error)
        } catch {
            phase = .failed(.providerInternal(error.localizedDescription))
        }
    }

    /// Complete a magic-link sign-in from a Universal Link payload.
    ///
    /// Accepts the URL unconditionally — validation happens inside
    /// `AuthCoordinator.completeMagicLink(url:)` via `MagicLinkCallback`,
    /// which rejects host mismatches, bad paths, and malformed tokens.
    /// A URL that doesn't parse flows through as `.invalidMagicLink` and
    /// lands the VM in `.failed`.
    ///
    /// Idempotent and host-safe: the app can call this from every
    /// `.onOpenURL` firing without first checking the current phase.
    /// Already-busy and already-succeeded phases drop the call on the
    /// floor so spurious `.onOpenURL` events don't disrupt an in-flight
    /// Apple sign-in or undo a completed one.
    public func completeMagicLink(url: URL) async {
        guard !phase.isBusy else { return }
        if case .succeeded = phase { return }
        phase = .verifyingMagicLink
        do {
            let session = try await coordinator.completeMagicLink(url: url)
            emailSheetPresented = false
            phase = .succeeded(session)
        } catch AuthError.cancelled {
            phase = .idle
        } catch let error as AuthError {
            phase = .failed(error)
        } catch {
            phase = .failed(.providerInternal(error.localizedDescription))
        }
    }

    /// Close the error banner and return to `.idle`. No-op from any
    /// non-failed phase — the banner only exists when `phase == .failed`.
    public func dismissError() {
        if case .failed = phase {
            phase = .idle
        }
    }

    /// Drop out of the "check your email" state back to the idle sign-in
    /// screen. Clears `emailInput` so the next magic-link flow starts
    /// clean.
    public func useDifferentEmail() {
        if case .emailSent = phase {
            phase = .idle
            emailInput = ""
        }
    }

    /// Re-send the magic-link email to the address already captured in
    /// `.emailSent`. Pulls the address from the phase rather than
    /// `emailInput` so the user cannot accidentally resend to a
    /// different address by editing the field behind the "check your
    /// email" screen.
    ///
    /// Uses a dedicated `.resendingMagicLink(address)` phase so the
    /// "check your email" screen can stay visible (showing a spinner
    /// on its Resend button) instead of flickering back to the main
    /// sign-in screen for the duration of the network call.
    public func resendMagicLink() async {
        guard case let .emailSent(address) = phase else { return }
        phase = .resendingMagicLink(address)
        do {
            try await coordinator.requestMagicLink(email: address)
            phase = .emailSent(address)
        } catch AuthError.cancelled {
            phase = .emailSent(address)
        } catch let error as AuthError {
            phase = .failed(error)
        } catch {
            phase = .failed(.providerInternal(error.localizedDescription))
        }
    }

    public func presentEmailSheet() {
        guard !phase.isBusy else { return }
        if case .succeeded = phase { return }
        if case .emailSent = phase { return }
        emailSheetPresented = true
    }

    public func dismissEmailSheet() {
        emailSheetPresented = false
    }

    /// Load any session the coordinator already knows about. Called
    /// once on screen-mount so a restart of the app with an existing
    /// keychain-backed session moves straight to `.succeeded` and the
    /// host navigates out without showing the sign-in UI.
    public func resume() async {
        if case .succeeded = phase { return }
        do {
            if let existing = try await coordinator.currentSession() {
                phase = .succeeded(existing)
            }
        } catch AuthError.cancelled {
            // User declined a biometric prompt on a gated store. Stay
            // on the sign-in screen — they'll tap a button to retry.
        } catch {
            // Any other failure (keychain read error, attestation store
            // offline): leave phase at .idle. The user can still sign
            // in fresh; we won't surface this as a banner because it
            // isn't an error of the *current* user action.
        }
    }

    private func runSocialSignIn(
        _ body: @escaping @Sendable () async throws -> AuthSession,
    ) async {
        do {
            let session = try await body()
            phase = .succeeded(session)
        } catch AuthError.cancelled {
            phase = .idle
        } catch let error as AuthError {
            phase = .failed(error)
        } catch {
            phase = .failed(.providerInternal(error.localizedDescription))
        }
    }
}
