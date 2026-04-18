import Foundation

/// Platform-independent camera authorisation gate.
///
/// Abstracts `AVCaptureDevice.authorizationStatus(for: .video)` and
/// `AVCaptureDevice.requestAccess(for: .video)` into a protocol so
/// the pairing view-model can be unit-tested on Linux without
/// AVFoundation. The concrete Apple-platform implementation
/// (`SystemCameraPermissionGate`) lives alongside the QR scanner.
public protocol CameraPermissionGate: Sendable {
    /// Current OS-reported camera authorisation status. Never
    /// prompts.
    func status() async -> CameraPermissionStatus

    /// Request camera access. Returns the post-prompt status. On
    /// already-authorised devices the call is synchronous-ish and
    /// returns `.authorized` immediately. On `.denied` /
    /// `.restricted` devices this returns the existing status
    /// verbatim without prompting — the OS refuses to re-prompt a
    /// user who has previously denied.
    func requestAccess() async -> CameraPermissionStatus
}

public enum CameraPermissionStatus: Sendable, Equatable {
    /// Status not yet queried — call `requestAccess()` to get an
    /// answer.
    case notDetermined
    case authorized
    case denied
    case restricted
}

#if canImport(AVFoundation)
import AVFoundation

/// `AVCaptureDevice`-backed permission gate.
///
/// Thin translation layer: `AVAuthorizationStatus` → Swift-native
/// enum with `Sendable` guarantees. No state of its own; multiple
/// instances are trivially equivalent.
public struct SystemCameraPermissionGate: CameraPermissionGate {
    public init() {}

    public func status() async -> CameraPermissionStatus {
        Self.translate(AVCaptureDevice.authorizationStatus(for: .video))
    }

    public func requestAccess() async -> CameraPermissionStatus {
        let current = AVCaptureDevice.authorizationStatus(for: .video)
        switch current {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            return granted ? .authorized : .denied
        default:
            return Self.translate(current)
        }
    }

    private static func translate(_ status: AVAuthorizationStatus) -> CameraPermissionStatus {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }
}
#endif
