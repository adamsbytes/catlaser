import CatLaserDevice
import Foundation
import Observation

/// Observable view model backing the pairing screen.
///
/// Responsibilities:
///
/// 1. On `start()`, load any existing `PairedDevice` from the
///    `EndpointStore`. If present, hand it to the
///    `ConnectionManager` and jump straight to `.paired(device)` —
///    re-scanning is not required.
/// 2. Gate the QR scanner on camera permission. The VM itself
///    never touches AVFoundation; `CameraPermissionGate` is the
///    seam.
/// 3. On a successful scan (or manual-entry submit), run the
///    exchange through `PairingClient`, persist the result,
///    transition to `.paired`.
/// 4. On failure, transition to `.failed(error)` with a retry
///    path.
/// 5. On `unpair()`, wipe the stored endpoint and return to
///    `.scanning`. (The app-level sign-out flow ALSO wipes
///    via `SessionLifecycleObserver`.)
///
/// Reentrancy guard: every public action drops through when the VM
/// is already busy (`phase.isBusy`) so a second tap or a duplicate
/// scan does not kick off two concurrent exchanges.
///
/// Threading: `@MainActor` for observability. All async work
/// awaits into actor-isolated dependencies and hops back.
@MainActor
@Observable
public final class PairingViewModel {
    public private(set) var phase: PairingPhase = .checkingExisting
    public private(set) var connectionState: ConnectionState = .idle

    private let pairingClient: PairingClient
    private let store: any EndpointStore
    private let permissionGate: any CameraPermissionGate
    private let connectionManagerFactory: @Sendable (PairedDevice) -> ConnectionManager
    private let clock: @Sendable () -> Date

    private var manager: ConnectionManager?
    private var connectionStateTask: Task<Void, Never>?

    public init(
        pairingClient: PairingClient,
        store: any EndpointStore,
        permissionGate: any CameraPermissionGate,
        connectionManagerFactory: @escaping @Sendable (PairedDevice) -> ConnectionManager,
        clock: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.pairingClient = pairingClient
        self.store = store
        self.permissionGate = permissionGate
        self.connectionManagerFactory = connectionManagerFactory
        self.clock = clock
    }

    /// Called when the screen first appears. Loads any persisted
    /// pairing, starts the connection manager if present, otherwise
    /// gates on camera permission to proceed to the QR scanner.
    public func start() async {
        guard case .checkingExisting = phase else { return }

        do {
            if let existing = try await store.load() {
                await adoptPaired(existing)
                return
            }
        } catch {
            // Corrupted / unreadable keychain row — surface, but
            // leave the caller a clean "try to re-scan" path. Clear
            // the row to ensure load does not re-fail next tick.
            try? await store.delete()
            phase = .failed(error)
            return
        }

        await advanceToScanningOrPermission()
    }

    /// Explicitly request camera permission when in
    /// `.needsCameraPermission(.notDetermined)`. No-op otherwise.
    public func requestCameraPermission() async {
        guard case .needsCameraPermission(.notDetermined) = phase else { return }
        let post = await permissionGate.requestAccess()
        if post == .authorized {
            phase = .scanning
        } else {
            phase = .needsCameraPermission(post)
        }
    }

    /// Called by the QR scanner on a valid decode. Kicks off the
    /// pair exchange.
    public func submitScannedCode(_ code: PairingCode) async {
        guard !phase.isBusy else { return }
        switch phase {
        case .scanning, .manualEntry, .failed:
            break
        default:
            return
        }
        await runExchange(code: code)
    }

    /// Submit a manually-typed pairing code. Returns without
    /// side-effects if parsing fails; the UI surfaces the failure
    /// via `phase = .failed(.invalidCode(...))`.
    public func submitManualCode() async {
        guard case let .manualEntry(draft) = phase else { return }
        let code: PairingCode
        do {
            code = try PairingCode.parse(draft.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            phase = .failed(.invalidCode(error))
            return
        }
        await runExchange(code: code)
    }

    /// Update the manual-entry draft buffer. The VM keeps the draft
    /// so the view doesn't have to thread a SwiftUI `@State`
    /// bridging back in; observability covers the refresh.
    public func setManualDraft(_ text: String) {
        if case .manualEntry = phase {
            phase = .manualEntry(draft: text)
        } else if case .failed = phase {
            phase = .manualEntry(draft: text)
        }
    }

    /// Switch from the scanner to manual entry. No-op if the current
    /// phase is busy.
    public func switchToManualEntry() {
        guard !phase.isBusy else { return }
        phase = .manualEntry(draft: "")
    }

    /// Switch from manual entry back to the scanner. Asks for
    /// camera permission first if needed.
    public func switchToScanner() async {
        guard !phase.isBusy else { return }
        await advanceToScanningOrPermission()
    }

    /// Dismiss a `.failed` phase. Decides the next phase based on
    /// whether we have an existing pairing that should still be
    /// active. If we do, we go back to `.paired(device)`; otherwise
    /// we go back to the scanner (or permission prompt).
    public func dismissError() async {
        guard case .failed = phase else { return }
        let existing: PairedDevice?
        do {
            existing = try await store.load()
        } catch {
            existing = nil
        }
        if let existing {
            await adoptPaired(existing)
        } else {
            await advanceToScanningOrPermission()
        }
    }

    /// Tear down the active pairing: stop the connection manager,
    /// wipe the stored endpoint, move back to the scanner.
    public func unpair() async {
        if let manager {
            await manager.stop()
        }
        connectionStateTask?.cancel()
        connectionStateTask = nil
        manager = nil
        connectionState = .idle
        do {
            try await store.delete()
        } catch {
            // A wipe failure is worth surfacing; a stale row would
            // shadow a future re-pair.
            phase = .failed(error)
            return
        }
        await advanceToScanningOrPermission()
    }

    // MARK: - Internal

    private func runExchange(code: PairingCode) async {
        phase = .exchanging(code)
        let device: PairedDevice
        do {
            device = try await pairingClient.exchange(code: code, now: clock())
        } catch {
            phase = .failed(error)
            return
        }

        do {
            try await store.save(device)
        } catch {
            phase = .failed(error)
            return
        }

        await adoptPaired(device)
    }

    private func adoptPaired(_ device: PairedDevice) async {
        // Release any prior manager (could exist if the user
        // unpaired-and-repaired without re-instantiating the VM,
        // which the navigation stack does not currently expose but
        // is the safe path).
        if let manager {
            await manager.stop()
        }
        connectionStateTask?.cancel()

        let newManager = connectionManagerFactory(device)
        manager = newManager
        await newManager.start()

        phase = .paired(device)

        let stream = newManager.states
        connectionStateTask = Task { [weak self] in
            for await next in stream {
                guard !Task.isCancelled else { return }
                self?.applyConnectionState(next)
            }
        }
    }

    private func applyConnectionState(_ next: ConnectionState) {
        connectionState = next
    }

    private func advanceToScanningOrPermission() async {
        let status = await permissionGate.status()
        switch status {
        case .authorized:
            phase = .scanning
        case .notDetermined, .denied, .restricted:
            phase = .needsCameraPermission(status)
        }
    }

    /// Exposed for tests / app lifecycle hooks: returns the
    /// underlying `ConnectionManager` currently bound to the paired
    /// device, if any. The host app can use this to tell the live-
    /// view screen which `DeviceClient` to target.
    public var currentConnectionManager: ConnectionManager? { manager }
}
