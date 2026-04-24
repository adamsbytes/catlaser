import CatLaserApp
import CatLaserAuth
import CatLaserPairing
import CatLaserPush
import Foundation
import Observation

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Top-level phase state machine for the shipping app.
///
/// Transitions, in order:
///
///     resolvingInitial
///         → needsConsent(PrivacyConsentViewModel)  [first launch only]
///         → signedOut(SignInViewModel)             [no stored session]
///         → signedIn(PairingViewModel)             [session resume succeeded]
///
/// The shell also registers itself as a ``SessionLifecycleObserver``
/// on the ``AuthCoordinator`` so an explicit sign-out (from the
/// Settings tab) flips the phase back to ``signedOut``. Session
/// *expiry* (401 on a protected call) is handled one layer down —
/// the bearer cache is invalidated and the next protected call
/// re-prompts via the Secure-Enclave gate; the shell does not
/// force-unmount the paired tabs on a 401.
///
/// ``@MainActor`` because every phase transition mutates an
/// ``@Observable`` property that SwiftUI reads from the main
/// run-loop. The coordinator's observer callbacks are `async` and
/// cross-actor safe, so the protocol conformance compiles without
/// isolation warnings.
@MainActor
@Observable
final class AppShell: SessionLifecycleObserver {
    /// Visible state. The root view renders the case it sees; the
    /// shell is the only writer.
    enum Phase {
        case resolvingInitial
        case needsConsent(PrivacyConsentViewModel)
        case needsFaceIDIntroduction(FaceIDIntroViewModel)
        case signedOut(SignInViewModel)
        case signedIn(PairingViewModel)
    }

    private(set) var phase: Phase = .resolvingInitial

    /// Retained so the root view can thread the composition into
    /// the paired shell without also carrying it on the AppState.
    let composition: AppComposition
    let pushViewModel: PushViewModel

    init(composition: AppComposition, pushViewModel: PushViewModel) {
        self.composition = composition
        self.pushViewModel = pushViewModel
    }

    /// Resolve the phase to show at cold-launch time. Safe to call
    /// once per process; re-entry while ``resolvingInitial`` is a
    /// no-op, and any non-initial phase means someone already ran
    /// us (likely a re-mount of ``AppRoot``).
    func start() async {
        guard case .resolvingInitial = phase else { return }

        // Wire the sign-out observer BEFORE resolving the initial
        // phase so an in-flight sign-out that might land during
        // bootstrap doesn't get dropped. The coordinator holds
        // observers by strong reference; the observation lives as
        // long as the shell does.
        await composition.authCoordinator.addLifecycleObserver(self)

        if await composition.needsPrivacyConsent() {
            let vm = composition.privacyConsentViewModel { [weak self] in
                Task { @MainActor in await self?.advancePastConsent() }
            }
            phase = .needsConsent(vm)
            return
        }
        await advancePastConsent()
    }

    /// Called from the view layer when the sign-in VM transitions to
    /// ``.succeeded``. Flips the shell to the paired phase.
    func advancePastSignIn() async {
        if case .signedIn = phase { return }
        phase = .signedIn(makePairingVM())
    }

    // MARK: - SessionLifecycleObserver

    /// Sign-out flips us back to a fresh sign-in VM. We do NOT
    /// bounce through ``resolvingInitial`` — the consent screen is a
    /// once-per-install gate, not a once-per-sign-in gate.
    func sessionDidSignOut() async {
        let vm = SignInViewModel(coordinator: composition.authCoordinator)
        phase = .signedOut(vm)
    }

    /// Session expiry does NOT force a phase change. The bearer-store
    /// invalidation already happened inside the coordinator; the
    /// next protected call re-prompts via the keychain's
    /// ``.userPresence`` ACL. Keeping the paired phase intact means
    /// the user lands back on the tab they were on after re-auth
    /// rather than restarting at sign-in, which is the right UX for
    /// an idle-timeout-shaped failure.
    func sessionDidExpire() async {
        // Intentional no-op. Logging lives in the composition's
        // observability observer.
    }

    /// Called from the view layer when the Face ID intro VM commits.
    /// Falls through to the existing sign-in-resume path.
    func advancePastFaceIDIntroduction() async {
        await resumeSignInOrRoute()
    }

    // MARK: - Internal

    private func advancePastConsent() async {
        // After consent, gate on the Face ID / passcode intro card.
        // The card is shown once per install (tracked in
        // ``FaceIDIntroductionStore``); if already seen, fall straight
        // through to the sign-in resume path.
        if await composition.needsFaceIDIntroduction() {
            let vm = composition.faceIDIntroViewModel { [weak self] in
                Task { @MainActor in await self?.advancePastFaceIDIntroduction() }
            }
            phase = .needsFaceIDIntroduction(vm)
            return
        }
        await resumeSignInOrRoute()
    }

    /// Build a sign-in VM, resume any persisted session, and route
    /// to either ``.signedIn`` or ``.signedOut``. Shared between the
    /// post-consent and post-Face-ID-intro transitions so the
    /// resume semantics (biometric-cancelled fallback, etc.) stay
    /// consistent.
    private func resumeSignInOrRoute() async {
        let signInVM = SignInViewModel(coordinator: composition.authCoordinator)
        await signInVM.resume()
        if case .succeeded = signInVM.phase {
            phase = .signedIn(makePairingVM())
        } else {
            phase = .signedOut(signInVM)
        }
    }

    private func makePairingVM() -> PairingViewModel {
        PairingViewModel(
            pairingClient: composition.pairingClient,
            pairedDevicesClient: composition.pairedDevicesClient,
            store: composition.endpointStore,
            permissionGate: permissionGate(),
            connectionManagerFactory: { [composition] device in
                composition.connectionManager(for: device)
            },
            pairingAuthGate: composition.pairingAuthGate,
        )
    }

    private func permissionGate() -> any CameraPermissionGate {
        #if canImport(AVFoundation) && !os(watchOS)
        return SystemCameraPermissionGate()
        #else
        preconditionFailure(
            "AppShell requires a SystemCameraPermissionGate; this platform has no AVFoundation",
        )
        #endif
    }
}
