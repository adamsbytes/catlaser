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
/// each take a ``DeviceClient`` at construction and keep it as a
/// `let`. A supervisor reconnect produces a NEW ``DeviceClient``
/// instance even against the same endpoint, so the shell watches the
/// ``ConnectionState`` stream and rebuilds all three VMs whenever the
/// client identity changes. SwiftUI's `.id(_:)` modifier on
/// ``MainTabView`` forces a clean re-mount on the swap, so transient
/// in-flight requests on the old client do not race the new client's
/// state. This is a documented tradeoff: a reconnect mid-edit drops
/// any unsaved form state (the VM designs accept this because
/// reconnects are expected to be rare and short).
///
/// The push-token registrar is also notified on every client swap so
/// its in-actor ``(client, token)`` dedupe key is refreshed — without
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
    @State private var liveVM: LiveViewModel?
    @State private var historyVM: HistoryViewModel?
    @State private var scheduleVM: ScheduleViewModel?

    /// Monotonic identifier that ticks on every client swap. Used as
    /// the ``.id`` on ``MainTabView`` so SwiftUI tears down the tab
    /// bar + subviews cleanly on reconnect. A mere rebind of the
    /// underlying VMs would not cause SwiftUI to refresh
    /// ``.task``-driven subscriptions on the live / history screens;
    /// the identity bump is the load-bearing bit.
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
    /// Transitions into ``connected(newClient)`` rebuild the three
    /// VMs against the new client. Transitions out of ``connected``
    /// drop them so ``pairedContent`` falls back to the
    /// ``ConnectingView``; a subsequent ``.connected`` rebuilds with
    /// a fresh client instance. Any other transition is a no-op.
    @MainActor
    private func reconcile(connection: ConnectionState) {
        switch connection {
        case let .connected(newClient):
            if currentClient === newClient { return }
            let pairedDevice = currentPairedDevice()
            guard let pairedDevice else { return }
            liveVM = composition.liveViewModel(
                pairedDevice: pairedDevice,
                deviceClient: newClient,
            )
            historyVM = composition.historyViewModel(deviceClient: newClient)
            scheduleVM = composition.scheduleViewModel(deviceClient: newClient)
            currentClient = newClient
            sessionID = UUID()
            // Fire-and-forget: refresh the push-token registrar
            // against the new client. The registrar's actor isolation
            // dedupes a second attempt against the same `(client,
            // token)` tuple so this is safe to call on every swap.
            let registrar = composition.pushRegistrar
            Task { await registrar.setClient(newClient) }
        default:
            if currentClient != nil {
                liveVM = nil
                historyVM = nil
                scheduleVM = nil
                currentClient = nil
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
