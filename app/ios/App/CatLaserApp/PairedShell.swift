import CatLaserAuth
import CatLaserDesign
import CatLaserDevice
import CatLaserHistory
import CatLaserLive
import CatLaserPairing
import CatLaserPush
import CatLaserSchedule
import SwiftUI

/// Shell that lives "inside the signed-in half of the app" and
/// dispatches between:
///
///  * the pairing flow (QR scan / manual entry / confirm) when there
///    is no ``PairedDevice`` on record, and
///  * the connected tabs (Live / History / Schedule / Settings) when
///    the ``ConnectionManager`` yields a live ``DeviceClient``.
///
/// Between those two the view also renders a short-lived
/// ``ConnectingView`` that covers the supervisor's
/// ``connecting`` / ``waitingForNetwork`` / ``backingOff`` states so
/// the user never sees an empty tab bar spinning on a dead socket.
///
/// ## Session VM lifecycle
///
/// ``LiveViewModel``, ``HistoryViewModel``, and ``ScheduleViewModel``
/// each take a ``DeviceClient`` at construction. A supervisor
/// reconnect produces a NEW ``DeviceClient`` instance even against the
/// same endpoint, so the shell watches the ``ConnectionState`` stream
/// and reconciles in two distinct ways:
///
/// * **Same paired device, fresh client** — the user is mid-stream /
///   mid-edit and the supervisor just rebuilt the transport (network
///   blip, foregrounding from a stale socket). The shell hands each
///   VM the new client via its `swapDeviceClient(_:eventBroker:)` API.
///   The user-visible streaming state, the loaded cat list, the
///   pending naming sheets, and the in-progress schedule draft are all
///   preserved. SwiftUI's `.id(_:)` on ``MainTabView`` does NOT change
///   on this path so the tab subtree stays mounted and `.task`-driven
///   subscriptions on the live / history screens are not re-armed.
/// * **First connect, or new paired device** — there is nothing to
///   preserve; the shell mints fresh VMs against the new client and
///   bumps `sessionID` so the tab subtree re-mounts cleanly.
///
/// The push-token registrar is notified on every client swap so its
/// in-actor ``(client, token)`` dedupe key is refreshed — without
/// this the registrar would keep trying to register against the dead
/// client and the device would never receive the fresh token.
struct PairedShell: View {
    @Bindable var pairingViewModel: PairingViewModel
    @Bindable var pushViewModel: PushViewModel
    let composition: AppComposition
    let appVersion: String
    let buildNumber: String

    /// Currently-bound device client. Tracked alongside the three VMs
    /// so a reconnect-induced swap is detected by reference identity
    /// (`===`) rather than value equality. Nil until the first
    /// `.connected` event lands.
    @State private var currentClient: DeviceClient?
    /// Currently-bound event broker — the single consumer of the
    /// current client's events stream. Rebuilt alongside (or beside)
    /// the VMs on every client swap; ``stop()``-ed when the supervisor
    /// leaves the ``.connected`` state so its subscriber streams finish
    /// and downstream for-await loops exit cleanly.
    @State private var currentBroker: DeviceEventBroker?
    /// Identity of the paired device the current VMs were minted
    /// against. Used by ``reconcile`` to decide whether a fresh
    /// ``.connected(newClient)`` is "same device, new transport" (in
    /// which case the existing VMs are kept and the new client is
    /// swapped in) or "fresh device" (in which case the VMs are
    /// rebuilt). Nil before the first connect.
    @State private var lastPairedDeviceID: String?
    @State private var liveVM: LiveViewModel?
    @State private var historyVM: HistoryViewModel?
    @State private var scheduleVM: ScheduleViewModel?

    /// Monotonic identifier that ticks ONLY on a fresh-device build —
    /// not on a same-device transport swap. Used as the ``.id`` on
    /// ``MainTabView`` so SwiftUI tears down the tab bar + subviews
    /// cleanly when the underlying VMs are replaced, but does NOT
    /// re-mount on a same-device reconnect (which would throw away
    /// the streaming + form state the swap is specifically intended
    /// to preserve).
    @State private var sessionID: UUID = .init()

    var body: some View {
        Group {
            switch pairingViewModel.phase {
            case .paired:
                pairedContent
            default:
                PairingView(viewModel: pairingViewModel)
            }
        }
        .onChange(of: pairingViewModel.connectionState) { _, newState in
            reconcile(connection: newState)
        }
    }

    @ViewBuilder
    private var pairedContent: some View {
        if let liveVM, let historyVM, let scheduleVM, currentClient != nil {
            MainTabView(
                liveViewModel: liveVM,
                historyViewModel: historyVM,
                scheduleViewModel: scheduleVM,
                pushViewModel: pushViewModel,
                pairingViewModel: pairingViewModel,
                authCoordinator: composition.authCoordinator,
                appVersion: appVersion,
                buildNumber: buildNumber,
            )
            .id(sessionID)
        } else {
            ConnectingView(
                connectionState: pairingViewModel.connectionState,
                onUnpair: { Task { await pairingViewModel.unpair() } },
            )
        }
    }

    /// Fold an incoming ``ConnectionState`` into the session VMs.
    ///
    /// On ``connected(newClient)``:
    ///
    /// * If the new client lands against the SAME paired device as the
    ///   current one, the existing VMs are kept and only the device
    ///   client + event broker references are swapped in. The user's
    ///   active stream, loaded data, and in-progress form edits all
    ///   survive — a momentary network blip doesn't reset the screen.
    /// * Otherwise (first connect after pairing, fresh paired device
    ///   after re-pair) the VMs are rebuilt and ``sessionID`` ticks so
    ///   ``MainTabView`` re-mounts cleanly.
    ///
    /// On any non-connected transition the broker is stopped, the VMs
    /// are explicitly torn down (LiveStreamSession is teared via
    /// ``LiveViewModel/stop`` so the LiveKit room finishes cleanly),
    /// and the references are cleared so ``pairedContent`` falls back
    /// to ``ConnectingView``.
    private func reconcile(connection: ConnectionState) {
        switch connection {
        case let .connected(newClient):
            if currentClient === newClient { return }
            let pairedDevice = currentPairedDevice()
            guard let pairedDevice else { return }
            // Tear down the previous broker before swapping in a new
            // one. Each broker is a single consumer of its client's
            // events stream; the previous client's stream will finish
            // on its own disconnect, but calling stop here also
            // finishes every subscriber's fanout so old VM tasks exit
            // without waiting on a stale stream.
            currentBroker?.stop()
            let broker = composition.deviceEventBroker(for: newClient)
            broker.start()

            let isSameDeviceReconnect =
                lastPairedDeviceID == pairedDevice.id
                    && liveVM != nil
                    && historyVM != nil
                    && scheduleVM != nil
            if isSameDeviceReconnect,
               let liveVM,
               let historyVM,
               let scheduleVM {
                // Same paired device, new transport — preserve all
                // user-visible state by swapping the client and broker
                // into the existing VMs. ``sessionID`` deliberately
                // does NOT change so ``MainTabView`` keeps its identity
                // and the streaming chrome stays put.
                liveVM.swapDeviceClient(newClient, eventBroker: broker)
                historyVM.swapDeviceClient(newClient, eventBroker: broker)
                scheduleVM.swapDeviceClient(newClient)
            } else {
                // Fresh build path: first-ever connect, or a re-pair
                // landed against a different paired device. Either way
                // there is nothing to preserve.
                liveVM = composition.liveViewModel(
                    pairedDevice: pairedDevice,
                    deviceClient: newClient,
                    eventBroker: broker,
                )
                historyVM = composition.historyViewModel(
                    deviceClient: newClient,
                    eventBroker: broker,
                )
                scheduleVM = composition.scheduleViewModel(deviceClient: newClient)
                sessionID = UUID()
            }
            currentClient = newClient
            currentBroker = broker
            lastPairedDeviceID = pairedDevice.id
            // Fire-and-forget: refresh the push-token registrar
            // against the new client. The registrar's actor isolation
            // dedupes a second attempt against the same `(client,
            // token)` tuple so this is safe to call on every swap.
            let registrar = composition.pushRegistrar
            Task { await registrar.setClient(newClient) }
        default:
            if currentClient != nil {
                // Tear the live stream down explicitly before dropping
                // the VM reference. ``LiveViewModel`` cannot do this
                // from deinit (it is ``@MainActor`` and its events /
                // status tasks are MainActor-isolated); the only
                // authorised teardown path is ``stop()``. Without this
                // call the LiveKit room would survive a sign-out /
                // unpair until ARC eventually collected the VM, which
                // is non-deterministic and visibly leaks audio/video
                // bandwidth on the device side.
                if let liveVM {
                    Task { await liveVM.stop() }
                }
                if let historyVM { historyVM.stop() }
                currentBroker?.stop()
                currentBroker = nil
                liveVM = nil
                historyVM = nil
                scheduleVM = nil
                currentClient = nil
                lastPairedDeviceID = nil
            }
        }
    }

    /// Pull the currently-bound ``PairedDevice`` out of the pairing
    /// VM. The connection state is authoritative on *which* client
    /// to use; the device slug (for expected LiveKit identity, etc.)
    /// comes from the pairing VM's paired phase.
    private func currentPairedDevice() -> PairedDevice? {
        if case let .paired(device) = pairingViewModel.phase { return device }
        return nil
    }
}
