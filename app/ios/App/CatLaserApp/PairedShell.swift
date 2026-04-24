import CatLaserApp
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
    let legalURLs: LegalURLs

    /// Scene-phase observer used to drive the
    /// background→foreground auto-refresh. When the app comes back to
    /// the front after a real background trip, the History and
    /// Schedule VMs refetch their lists so a user who checks the app
    /// in the morning after backgrounding it overnight sees today's
    /// state rather than yesterday's — the device almost certainly
    /// ran sessions or accepted schedule commits in the interval.
    ///
    /// An ``.inactive`` pass-through (control-center swipe,
    /// notification-centre peek, incoming call) is NOT a background
    /// trip and does not trigger a refresh: ``.background`` is the
    /// only phase we gate on, and iOS only enters it when the app is
    /// genuinely suspended.
    @Environment(\.scenePhase) private var scenePhase

    /// Timestamp at which the app entered ``.background`` in the
    /// current lifecycle. Nil when the app has been foreground-only
    /// since launch, or after the return-from-background refresh has
    /// been handled. Tracking a timestamp rather than a bare flag
    /// keeps the door open for a future "only refresh if we were
    /// backgrounded for more than N seconds" policy without reworking
    /// the observer shape; today's implementation refreshes on every
    /// real background trip because the VMs' ``canRefresh`` gates
    /// coalesce rapid calls themselves.
    @State private var backgroundEnteredAt: Date?

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
    /// Whether the post-pair tabs tour should be visible on this
    /// mount. Read from ``OnboardingTourStore`` on the first
    /// ``MainTabView`` render; flipped to `false` inline the moment
    /// the user completes (or dismisses) the tour, with the
    /// persistent flag write deferred to a fire-and-forget Task.
    @State private var showTabsTour: Bool = false
    /// Whether the Schedule first-run hint banner should render on
    /// this mount. Read from the same store as ``showTabsTour``;
    /// threaded into ``ScheduleView`` via ``ScheduleFirstRunHint``.
    @State private var showScheduleHint: Bool = false
    /// True once we've read the onboarding-tour store at least once
    /// on this paired-shell lifecycle. Stops the ``.task`` below
    /// from re-firing on every view update.
    @State private var tourStoreHydrated: Bool = false

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
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhase(newPhase)
        }
    }

    @ViewBuilder
    private var pairedContent: some View {
        // Broker is assigned alongside ``currentClient`` in
        // ``reconcile(connection:)`` and cleared in the same branch
        // that clears the client, so the two nils move in lockstep.
        // Gating on both here just makes the invariant visible at the
        // call site and gives SwiftUI a total of three non-optional
        // dependencies to bind into ``MainTabView``.
        if let liveVM, let historyVM, let scheduleVM,
           currentClient != nil, let currentBroker {
            ZStack {
                MainTabView(
                    liveViewModel: liveVM,
                    historyViewModel: historyVM,
                    scheduleViewModel: scheduleVM,
                    pushViewModel: pushViewModel,
                    pairingViewModel: pairingViewModel,
                    deviceEventBroker: currentBroker,
                    authCoordinator: composition.authCoordinator,
                    scheduleFirstRunHint: scheduleFirstRunHint,
                    appVersion: appVersion,
                    buildNumber: buildNumber,
                    legalURLs: legalURLs,
                )
                .id(sessionID)
                if showTabsTour {
                    TabsTourOverlay(onComplete: markTabsTourSeen)
                        .transition(.opacity)
                }
            }
            .task(id: sessionID) {
                // Hydrate the onboarding flags the first time we mount
                // a live tab view in this paired-shell lifecycle. The
                // `.task(id:)` variant re-runs on a fresh-device build
                // (sessionID ticks) but not on a same-device transport
                // swap — correct, because we want the tour to appear
                // once per pairing, not on every reconnect.
                await hydrateOnboardingFlags()
            }
        } else {
            ConnectingView(
                connectionState: pairingViewModel.connectionState,
                onUnpair: { Task { await pairingViewModel.unpair() } },
            )
        }
    }

    private var scheduleFirstRunHint: ScheduleFirstRunHint? {
        guard showScheduleHint else { return nil }
        let store = composition.onboardingTourStore
        return ScheduleFirstRunHint(
            isVisible: true,
            onDismiss: { [store] in
                Task { await store.markScheduleHintSeen() }
            },
        )
    }

    private func hydrateOnboardingFlags() async {
        guard !tourStoreHydrated else { return }
        tourStoreHydrated = true
        let state = await composition.onboardingTourStore.load()
        // SwiftUI reads these on next frame; no animation hop needed
        // because the overlay's .transition modifier handles the
        // visual appearance.
        showTabsTour = !state.hasSeenTabsTour
        showScheduleHint = !state.hasSeenScheduleHint
    }

    private func markTabsTourSeen() {
        guard showTabsTour else { return }
        showTabsTour = false
        let store = composition.onboardingTourStore
        Task { await store.markTabsTourSeen() }
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
                // The VMs' ``.task`` modifiers only fire once per
                // subview mount; a same-device reconnect keeps the
                // mount alive so the initial ``start()`` never re-runs.
                // After a multi-minute backoff (``backingOff``) the
                // device may have logged sessions, accepted schedule
                // commits from another signed-in surface, or otherwise
                // advanced its state — refetch so the UI converges on
                // the device's truth rather than serving stale reads.
                // ``refreshConnectedViewModels`` is fire-and-forget and
                // the VMs' ``canRefresh`` gates coalesce concurrent
                // calls, so this is safe regardless of what the user
                // happens to be doing in the moment.
                refreshConnectedViewModels()
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

    /// Fold a scene-phase transition into the background-refresh
    /// policy. We arm ``backgroundEnteredAt`` on every entry into
    /// ``.background`` (the only phase iOS guarantees has actually
    /// suspended the app's run loop) and fire the refresh on the
    /// subsequent return to ``.active``. ``.inactive`` is a
    /// pass-through — a notification-centre peek, a control-centre
    /// swipe, or a brief incoming-call UI does not clear the
    /// backgrounded flag, so a user who merely glanced at the
    /// notification shade does not trigger a refresh round-trip.
    ///
    /// The refresh only fires when we're actually connected — the
    /// VMs are nil otherwise, and calling into a disconnected state
    /// would serve a typed ``notConnected`` error banner the user did
    /// nothing to provoke. When the app returns from background while
    /// disconnected, the ``ConnectionManager`` will pick the transport
    /// back up on its own via ``NetworkPathMonitor``; the fresh
    /// ``.connected(newClient)`` that follows routes through
    /// ``reconcile`` and the refresh on the same-device branch picks
    /// up the refetch.
    private func handleScenePhase(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            if backgroundEnteredAt == nil {
                backgroundEnteredAt = Date()
            }
        case .active:
            guard backgroundEnteredAt != nil else { return }
            backgroundEnteredAt = nil
            refreshConnectedViewModels()
        case .inactive:
            // Intentional pass-through. A control-centre swipe or a
            // notification-centre peek stops at ``.inactive`` and
            // returns to ``.active`` without the app ever being
            // suspended, so there is no stale-data risk to address.
            break
        @unknown default:
            break
        }
    }

    /// Fire the post-background / post-reconnect refetch on every VM
    /// that owns a list. Fire-and-forget: the VMs' ``canRefresh``
    /// gates already coalesce concurrent callers (pull-to-refresh
    /// racing with this one, two rapid reconnects, etc.) so the
    /// unordered start is safe. A ``notConnected`` error raised by a
    /// refetch against a flapping transport still surfaces via each
    /// VM's own ``lastActionError`` / ``failed`` mapping — it's the
    /// same path a manual pull-to-refresh takes, so we don't need a
    /// bespoke error surface here.
    ///
    /// No live-VM refresh: the LiveViewModel's state transitions are
    /// driven by user action and LiveKit events, not by polled data.
    /// A backgrounded stream surfaces as ``.disconnected`` on return
    /// (see ``LiveViewModel.apply(event:)`` for the network-class
    /// mapping) and the user resumes with a tap on "Watch live."
    private func refreshConnectedViewModels() {
        if let historyVM {
            Task {
                await historyVM.refreshCats()
                await historyVM.refreshHistory()
            }
        }
        if let scheduleVM {
            Task { await scheduleVM.refresh() }
        }
    }
}
