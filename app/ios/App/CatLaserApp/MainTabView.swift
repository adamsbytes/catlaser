import CatLaserAuth
import CatLaserDesign
import CatLaserHistory
import CatLaserLive
import CatLaserPairing
import CatLaserPush
import CatLaserSchedule
import SwiftUI
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Primary tab shell for the paired + connected app.
///
/// Four tabs: Live, History, Schedule, Settings. The ``ConnectionStatusPill``
/// overlays every tab at the top safe-area edge so a network drop or
/// reconnect is always visible, not just on the Live screen. Push
/// notification taps route here via ``PushViewModel/pendingDeepLinks``;
/// the view consumes each pending route and flips the selected tab
/// accordingly.
struct MainTabView: View {
    @Bindable var liveViewModel: LiveViewModel
    @Bindable var historyViewModel: HistoryViewModel
    @Bindable var scheduleViewModel: ScheduleViewModel
    @Bindable var pushViewModel: PushViewModel
    @Bindable var pairingViewModel: PairingViewModel
    let authCoordinator: AuthCoordinator
    let appVersion: String
    let buildNumber: String

    enum Tab: Hashable {
        case live
        case history
        case schedule
        case settings
    }

    @State private var selected: Tab = .live

    var body: some View {
        TabView(selection: $selected) {
            liveTabContent
                .tabItem {
                    Label("Live", systemImage: "video.fill")
                }
                .tag(Tab.live)

            HistoryView(viewModel: historyViewModel)
                .tabItem {
                    Label("History", systemImage: "pawprint.fill")
                }
                .tag(Tab.history)

            ScheduleView(viewModel: scheduleViewModel)
                .tabItem {
                    Label("Schedule", systemImage: "calendar")
                }
                .tag(Tab.schedule)

            SettingsView(
                pushViewModel: pushViewModel,
                pairingViewModel: pairingViewModel,
                authCoordinator: authCoordinator,
                appVersion: appVersion,
                buildNumber: buildNumber,
            )
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .tag(Tab.settings)
        }
        .tint(SemanticColor.accent)
        .overlay(alignment: .top) {
            ConnectionStatusPill(state: pairingViewModel.connectionState)
        }
        .onChange(of: pushViewModel.pendingDeepLinks.count) { _, newValue in
            guard newValue > 0 else { return }
            consumeDeepLinks()
        }
        .task {
            // On first mount, drain any routes queued while the VM
            // was constructed (cold launch from a tapped push).
            consumeDeepLinks()
        }
    }

    /// Drain the FIFO of pending routes and apply each one. The VM
    /// pops the queue on ``consumePendingDeepLink``; we stop when the
    /// pop returns nil. A single push triggers one tab flip; a user
    /// who taps multiple pushes while offline still lands on the
    /// most recent route (last-write-wins via loop).
    private func consumeDeepLinks() {
        while let route = pushViewModel.consumePendingDeepLink() {
            switch route {
            case .home, .liveView:
                selected = .live
            case .history:
                selected = .history
            case .hopperStatus:
                // No dedicated hopper tab in v1 — route to Settings,
                // where the device section surfaces connectivity
                // status. A future Devices tab would own the detailed
                // hopper view.
                selected = .settings
            }
        }
    }

    /// Live tab content with per-screen orientation policy.
    ///
    /// The Live tab is the only surface that needs landscape — the
    /// video feed fills the phone screen at 16:9 when rotated. The
    /// ``allowOrientations`` modifier updates the shared
    /// ``OrientationLock`` on appear and restores portrait on
    /// disappear so sibling tabs keep their portrait-first layouts
    /// intact. On platforms where UIKit is unavailable the modifier
    /// is compiled out and the Live tab just renders the view.
    @ViewBuilder
    private var liveTabContent: some View {
        #if canImport(UIKit) && !os(watchOS) && os(iOS)
        LiveView(viewModel: liveViewModel)
            .allowOrientations(.allButUpsideDown)
        #else
        LiveView(viewModel: liveViewModel)
        #endif
    }
}
