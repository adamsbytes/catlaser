import CatLaserApp
import CatLaserAuth
import CatLaserPairing
import CatLaserDesign
import SwiftUI

/// Root view rendered beneath the ``WindowGroup``. Switches on the
/// ``AppShell/Phase`` and delegates to the corresponding screen —
/// or to the ``PairedShell`` once the user is signed in.
///
/// Every phase has exactly one owner; the enum pattern here keeps
/// that one-owner rule visible. A phase transition flips the enum
/// case under the hood and SwiftUI re-renders the right branch.
struct RootView: View {
    @Bindable var shell: AppShell
    let appVersion: String
    let buildNumber: String

    var body: some View {
        switch shell.phase {
        case .resolvingInitial:
            LaunchPlaceholder()
        case let .needsConsent(vm):
            PrivacyConsentView(viewModel: vm)
        case let .signedOut(vm):
            SignedOutScreen(signInViewModel: vm, shell: shell)
        case let .signedIn(vm):
            PairedShell(
                pairingViewModel: vm,
                pushViewModel: shell.pushViewModel,
                composition: shell.composition,
                appVersion: appVersion,
                buildNumber: buildNumber,
            )
        }
    }
}

/// Wrapper that hosts ``SignInView`` and advances the shell as soon
/// as the VM reports ``.succeeded``.
///
/// The phase transition has to happen at the view layer because
/// ``SignInViewModel.phase`` is observable — there is no coordinator
/// callback we can hang off when sign-in completes — and watching it
/// from a detached task inside the shell would require re-arming
/// ``withObservationTracking`` in a loop, which is more moving parts
/// than the same `.onChange` one line here gets us.
private struct SignedOutScreen: View {
    @Bindable var signInViewModel: SignInViewModel
    let shell: AppShell

    var body: some View {
        SignInView(viewModel: signInViewModel)
            .onChange(of: signInIsComplete) { _, completed in
                if completed {
                    Task { await shell.advancePastSignIn() }
                }
            }
    }

    /// Projection of ``signInViewModel.phase`` to a bool so
    /// ``.onChange`` has a stable Equatable comparator. Reading the
    /// enum directly in `.onChange` requires the whole
    /// ``SignInPhase`` to be equatable (it is), but the bool
    /// projection makes the intent explicit and avoids firing on
    /// every intermediate failure state.
    private var signInIsComplete: Bool {
        if case .succeeded = signInViewModel.phase { return true }
        return false
    }
}
