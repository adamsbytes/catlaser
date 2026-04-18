import CatLaserPairing
import Foundation

/// Scriptable `CameraPermissionGate` for VM tests.
///
/// Tests set an initial status, optionally queue a post-prompt
/// status, and observe the number of `requestAccess()` calls. A
/// queued post-prompt status is consumed once; subsequent
/// `requestAccess()` calls return the resting status.
public actor FakeCameraPermissionGate: CameraPermissionGate {
    public private(set) var resting: CameraPermissionStatus
    private var queuedPostPrompt: CameraPermissionStatus?
    private var requestCount: Int = 0

    public init(initial: CameraPermissionStatus) {
        self.resting = initial
    }

    public func status() async -> CameraPermissionStatus {
        resting
    }

    public func requestAccess() async -> CameraPermissionStatus {
        requestCount += 1
        if let queued = queuedPostPrompt {
            queuedPostPrompt = nil
            resting = queued
            return queued
        }
        return resting
    }

    // MARK: - Test hooks

    public func queuePostPromptStatus(_ status: CameraPermissionStatus) {
        queuedPostPrompt = status
    }

    public func setResting(_ status: CameraPermissionStatus) {
        resting = status
    }

    public func requestAccessCount() -> Int { requestCount }
}
