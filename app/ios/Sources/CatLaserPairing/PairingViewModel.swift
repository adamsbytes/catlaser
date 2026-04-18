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

    /// Default cadence between successive background ownership
    /// re-checks while the app is foregrounded. A daily check catches
    /// supersession without burning an attested HTTP call on every
    /// scene activation. The cadence matters because the lookup is
    /// read-only and attested, but not free — each call burns a
    /// Secure-Enclave signing op.
    public static let defaultReverifyInterval: TimeInterval = 24 * 60 * 60

    private let pairingClient: PairingClient
    private let pairedDevicesClient: PairedDevicesClient?
    private let store: any EndpointStore
    private let permissionGate: any CameraPermissionGate
    private let connectionManagerFactory: @Sendable (PairedDevice) -> ConnectionManager
    private let clock: @Sendable () -> Date
    private let reverifyInterval: TimeInterval

    private var manager: ConnectionManager?
    private var connectionStateTask: Task<Void, Never>?
    private var lastReverifyAt: Date?

    public init(
        pairingClient: PairingClient,
        pairedDevicesClient: PairedDevicesClient? = nil,
        store: any EndpointStore,
        permissionGate: any CameraPermissionGate,
        connectionManagerFactory: @escaping @Sendable (PairedDevice) -> ConnectionManager,
        clock: @escaping @Sendable () -> Date = { Date() },
        reverifyInterval: TimeInterval = PairingViewModel.defaultReverifyInterval,
    ) {
        self.pairingClient = pairingClient
        self.pairedDevicesClient = pairedDevicesClient
        self.store = store
        self.permissionGate = permissionGate
        self.connectionManagerFactory = connectionManagerFactory
        self.clock = clock
        self.reverifyInterval = reverifyInterval
    }

    /// Called when the screen first appears. Loads any persisted
    /// pairing, starts the connection manager if present, otherwise
    /// gates on camera permission to proceed to the QR scanner.
    ///
    /// Also fires an ownership re-verification against the server
    /// before adopting the persisted device (if a
    /// `PairedDevicesClient` is wired). If the server reports the
    /// stored `device_id` as no longer active — the most common cause
    /// is that the device was re-paired to a different user — the
    /// local row is wiped and the user is routed back to the pairing
    /// flow. An offline or transiently-failed re-check is tolerated
    /// silently: we adopt the cached pairing and try again on the
    /// next interval, so a flaky-network launch never locks the user
    /// out of a device they legitimately own.
    public func start() async {
        guard case .checkingExisting = phase else { return }

        let existing: PairedDevice?
        do {
            existing = try await store.load()
        } catch {
            // Corrupted / unreadable keychain row — surface, but
            // leave the caller a clean "try to re-scan" path. Clear
            // the row to ensure load does not re-fail next tick.
            try? await store.delete()
            phase = .failed(error)
            return
        }

        guard let existing else {
            await advanceToScanningOrPermission()
            return
        }

        // Verify the cached pairing against the server before
        // adopting it. An authoritative "not yours anymore" response
        // wipes and routes to re-pair; anything else (network, 5xx,
        // attestation hiccup) lets the cached pairing proceed and
        // retries on the next reverify window.
        switch await reverifyOwnership(of: existing) {
        case .stillOwned, .indeterminate:
            await adoptPaired(existing)
        case .noLongerOwned:
            try? await store.delete()
            await advanceToScanningOrPermission()
        }
    }

    /// Trigger an ownership re-check on demand. Safe to call from any
    /// lifecycle hook (scene foreground, daily timer, manual refresh).
    /// No-op if the client was constructed without a
    /// `PairedDevicesClient`, if no pairing is currently held, or if
    /// the last successful reverification was within
    /// `reverifyInterval`. A result of `.noLongerOwned` wipes the
    /// local row, tears down the active connection, and routes the
    /// user back to the scanner.
    public func reverifyOwnershipIfNeeded() async {
        guard let manager, pairedDevicesClient != nil else { return }
        guard case let .paired(device) = phase else { return }
        if let lastReverifyAt {
            let elapsed = clock().timeIntervalSince(lastReverifyAt)
            if elapsed < reverifyInterval { return }
        }
        switch await reverifyOwnership(of: device) {
        case .stillOwned, .indeterminate:
            break
        case .noLongerOwned:
            await manager.stop()
            connectionStateTask?.cancel()
            connectionStateTask = nil
            self.manager = nil
            connectionState = .idle
            try? await store.delete()
            await advanceToScanningOrPermission()
        }
        _ = manager
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

    /// Called by the QR scanner on a valid decode. Parks the decoded
    /// code in `.confirming(code)` and waits for an explicit
    /// `confirmPairing()` tap. The coordination server is NOT
    /// contacted at this point — the confirmation gate gives the user
    /// a chance to see which device they are about to claim before
    /// any network traffic fires, which defeats a class of
    /// swap-the-QR attacks and turns pairing into an explicit, visible
    /// action rather than a silent auto-submit on decode.
    public func submitScannedCode(_ code: PairingCode) async {
        guard !phase.isBusy else { return }
        switch phase {
        case .scanning, .manualEntry, .failed:
            phase = .confirming(code)
        default:
            return
        }
    }

    /// Submit a manually-typed pairing code. Parses the draft and
    /// parks the result in `.confirming(code)`; the user must tap
    /// `confirmPairing()` to actually hit the coordination server.
    /// Parse failures land on `.failed(.invalidCode(...))` with no
    /// network side effect.
    public func submitManualCode() async {
        guard case let .manualEntry(draft) = phase else { return }
        let code: PairingCode
        do {
            code = try PairingCode.parse(draft.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            phase = .failed(.invalidCode(error))
            return
        }
        phase = .confirming(code)
    }

    /// Consume the `.confirming(code)` phase and run the pair
    /// exchange. No-op from any other phase.
    public func confirmPairing() async {
        guard case let .confirming(code) = phase else { return }
        await runExchange(code: code)
    }

    /// Cancel a pending `.confirming(code)` and return to the
    /// scanner (respecting camera permission). No-op from any
    /// other phase.
    public func cancelPairingConfirmation() async {
        guard case .confirming = phase else { return }
        await advanceToScanningOrPermission()
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
        // Device-side revocation is terminal — the supervisor has
        // already given up and the server will reject any retry with
        // the same SPKI. Wipe the Keychain row and route the user
        // through the pairing flow automatically; anything else
        // would leave the app spinning against an endpoint that is
        // guaranteed to keep kicking it off.
        if case let .failed(error) = next, case .authRevoked = error {
            Task { [weak self] in
                await self?.unpairAfterRevocation()
            }
        }
    }

    /// Wipe local pairing state after the device declared our SPKI
    /// revoked. Synchronous analogue of `unpair()` but avoids a
    /// second stop-and-cleanup pass on the supervisor, which has
    /// already transitioned itself to `.failed(.authRevoked)`.
    private func unpairAfterRevocation() async {
        connectionStateTask?.cancel()
        connectionStateTask = nil
        manager = nil
        connectionState = .idle
        try? await store.delete()
        await advanceToScanningOrPermission()
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

    /// Outcome of a single server-side ownership re-check. A
    /// `.stillOwned` or `.noLongerOwned` answer is authoritative
    /// (2xx from the coordination server); `.indeterminate` is the
    /// fail-open bucket for network, 5xx, 429, or an attestation
    /// failure that would otherwise log the user out on a flaky
    /// launch. Callers that see `.indeterminate` keep the cached
    /// pairing and retry on the next scheduled reverification.
    private enum OwnershipCheckOutcome {
        case stillOwned
        case noLongerOwned
        case indeterminate
    }

    /// Ask the coordination server whether `device.id` is still among
    /// the signed-in user's active (non-revoked) claims. The "no
    /// client wired" path returns `.indeterminate` so the cached
    /// pairing survives when the host app hasn't plumbed the client
    /// — tests and migration surfaces can construct the view model
    /// without it.
    private func reverifyOwnership(of device: PairedDevice) async -> OwnershipCheckOutcome {
        guard let client = pairedDevicesClient else { return .indeterminate }
        let devices: [PairedDevice]
        do {
            devices = try await client.list()
        } catch {
            // `client.list()` is `throws(PairingError)`, so every
            // failure is already the right type. Classify it:
            // `missingSession` is authoritative "nothing owned";
            // everything else is transient and callers must keep the
            // cached pairing until the next window.
            switch error {
            case .missingSession:
                return .noLongerOwned
            case .network, .rateLimited, .serverError, .invalidServerResponse,
                 .storage, .attestation, .codeAlreadyUsed, .codeExpired,
                 .codeNotFound, .invalidCode, .authRevoked:
                // `.authRevoked` is a device-side-only signal —
                // `PairedDevicesClient` cannot synthesise it. If it
                // ever reaches here that's a library bug; mapping to
                // `.indeterminate` preserves the cached pairing
                // instead of double-wiping on a spurious signal.
                return .indeterminate
            }
        }
        lastReverifyAt = clock()
        let stillOwned = devices.contains(where: { $0.id == device.id })
        return stillOwned ? .stillOwned : .noLongerOwned
    }

    /// Exposed for tests / app lifecycle hooks: returns the
    /// underlying `ConnectionManager` currently bound to the paired
    /// device, if any. The host app can use this to tell the live-
    /// view screen which `DeviceClient` to target.
    public var currentConnectionManager: ConnectionManager? { manager }
}
