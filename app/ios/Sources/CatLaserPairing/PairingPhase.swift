import CatLaserDevice
import Foundation

/// Observable phase of the pairing flow.
///
/// The view model drives through these in order:
///
/// * `.checkingExisting` — on first appear, while we read the
///   keychain to see if a prior pairing exists. Transient.
/// * `.needsCameraPermission(status)` — on appear with an
///   un-authorised camera, or mid-scan after a denial. The UI
///   shows either the permission prompt button (for
///   `.notDetermined`) or a Settings-redirect explanation (for
///   `.denied` / `.restricted`).
/// * `.scanning` — the live camera preview is on screen; waiting
///   for a valid QR.
/// * `.manualEntry(code)` — fallback when the camera path is not
///   viable; the user is typing the code in by hand.
/// * `.exchanging(code)` — we have a code; the HTTP exchange with
///   the coordination server is in flight. UI shows a spinner.
/// * `.paired(device)` — exchange succeeded AND the result was
///   persisted. Connection manager may still be dialling; a
///   separate `ConnectionState` observer in the UI shows its
///   state.
/// * `.failed(error)` — exchange or persistence failed. UI shows
///   the error; tapping "try again" returns to `.scanning` (or
///   `.manualEntry` if we were there before).
public enum PairingPhase: Sendable, Equatable {
    case checkingExisting
    case needsCameraPermission(CameraPermissionStatus)
    case scanning
    case manualEntry(draft: String)
    case exchanging(PairingCode)
    case paired(PairedDevice)
    case failed(PairingError)

    public var isBusy: Bool {
        switch self {
        case .checkingExisting, .exchanging: true
        case .needsCameraPermission, .scanning, .manualEntry, .paired, .failed: false
        }
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
