import Foundation
import Observation
#if canImport(LocalAuthentication) && !os(watchOS)
import LocalAuthentication
#endif

/// Probe the current device for biometric / passcode availability.
/// Abstracted behind a closure so tests can drive both branches
/// without a real ``LAContext``.
public typealias BiometricsAvailabilityProbe = @Sendable () -> Bool

/// Default probe: `true` iff Face ID / Touch ID / a passcode is set
/// up on this device. We check ``.deviceOwnerAuthentication`` (not
/// ``.deviceOwnerAuthenticationWithBiometrics``) because the user
/// can unlock with a passcode even without enrolled biometrics, and
/// the app gates every protected call on user presence — the passcode
/// is a sufficient auth factor for our threat model.
public let defaultBiometricsProbe: BiometricsAvailabilityProbe = {
    #if canImport(LocalAuthentication) && !os(watchOS)
    let context = LAContext()
    var error: NSError?
    return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    #else
    return false
    #endif
}

/// Observable view model backing ``FaceIDIntroView``. Owns one piece
/// of state:
///
/// * ``isCommitting`` — `true` while the persistent flag is being
///   written. Used to disable the buttons so a double-tap doesn't
///   race the store write.
///
/// The VM queries ``BiometricsAvailabilityProbe`` synchronously at
/// init time, so the view can decide which copy variant to render
/// without an async hop. The store write is async via ``commit``.
@MainActor
@Observable
public final class FaceIDIntroViewModel {
    public private(set) var isCommitting: Bool = false

    /// `true` when Face ID / Touch ID / a passcode is set up on the
    /// device. Drives the two copy variants in ``FaceIDIntroView``:
    ///
    /// * `true`  → "Only you can watch your home." with a single
    ///   Got it button.
    /// * `false` → "Lock your iPhone before you continue." with an
    ///   Open Settings primary button plus a Continue anyway
    ///   secondary.
    public let biometricsAvailable: Bool

    private let store: any FaceIDIntroductionStore
    private let onCompletion: @MainActor () -> Void

    public init(
        store: any FaceIDIntroductionStore,
        onCompletion: @escaping @MainActor () -> Void,
        biometricsProbe: BiometricsAvailabilityProbe = defaultBiometricsProbe,
    ) {
        self.store = store
        self.onCompletion = onCompletion
        self.biometricsAvailable = biometricsProbe()
    }

    /// Persist the "seen" state and fire the completion callback so
    /// the shell advances past this phase. Idempotent — a second
    /// tap while the write is in flight is dropped, matching the
    /// way the Continue button disables during ``isCommitting``.
    public func commit() async {
        guard !isCommitting else { return }
        isCommitting = true
        await store.save(.seen)
        isCommitting = false
        onCompletion()
    }
}
