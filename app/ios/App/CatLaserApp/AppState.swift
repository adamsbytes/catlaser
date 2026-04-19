import CatLaserApp
import CatLaserPush
import Foundation
import Observation

/// Top-of-app state holder. Owned by ``CatLaserAppDelegate`` (held
/// alive for the duration of the process) and read by
/// ``AppRoot`` via ``@Bindable`` so SwiftUI re-renders when
/// bootstrap completes.
///
/// The state is populated once at cold launch by
/// ``bootstrapIfNeeded()``. On subsequent scene mounts (e.g. a new
/// scene added on iPad) the method is a no-op and the already-built
/// composition is reused.
@MainActor
@Observable
final class AppState {
    /// Composition once bootstrap has finished. Nil during the
    /// LaunchPlaceholder window.
    private(set) var composition: AppComposition?

    /// Long-lived PushViewModel. The ``CatLaserAppDelegate`` hands
    /// the APNs register / fail callbacks into this instance so the
    /// Settings screen's push toggle reflects fresh state across
    /// the app lifetime.
    private(set) var pushViewModel: PushViewModel?

    /// Phase state machine. Non-nil once bootstrap has finished.
    private(set) var shell: AppShell?

    /// Cached version tuple, surfaced on the Settings screen.
    private(set) var appVersion: String = "0.0.0"
    private(set) var buildNumber: String = "0"

    /// Cached legal-URL pair, surfaced on the Settings screen. Loaded
    /// once at bootstrap alongside the deployment config; a
    /// malformed entry is fatal at launch via the same
    /// ``preconditionFailure`` path that guards the network-facing
    /// config, so a running process is guaranteed to have usable
    /// legal links.
    private(set) var legalURLs: LegalURLs?

    /// True once ``bootstrapIfNeeded()`` has produced a composition.
    private(set) var isBootstrapped: Bool = false

    /// Reentrancy guard — a second concurrent `.task { bootstrap }`
    /// mount (which SwiftUI can issue on a scene re-mount) waits for
    /// the first one's completion via this flag.
    private var bootstrapping: Bool = false

    /// Build the composition on cold launch. Idempotent — a
    /// subsequent invocation is a no-op once ``isBootstrapped`` is
    /// true.
    func bootstrapIfNeeded() async {
        guard !isBootstrapped, !bootstrapping else { return }
        bootstrapping = true
        defer { bootstrapping = false }

        let (version, build) = DeploymentConfiguration.versionTuple()
        appVersion = version
        buildNumber = build

        let config: AppComposition.DeploymentConfig
        do {
            config = try DeploymentConfiguration.load()
        } catch {
            // Fail-loud: placeholder / malformed deployment config
            // means the app cannot safely reach the network. Crash
            // with the typed error so the launch log points at the
            // exact xcconfig key to fix.
            preconditionFailure(
                "DeploymentConfiguration.load() failed: \(String(describing: error))",
            )
        }

        let legal: LegalURLs
        do {
            legal = try DeploymentConfiguration.legalURLs()
        } catch {
            // Same fail-loud posture as the network-facing config —
            // App Store Review rejects any build whose privacy or
            // terms link 404s, so a missing/malformed URL at launch
            // is a release-blocker and must be surfaced immediately,
            // not papered over with a "Privacy policy unavailable"
            // row that would pass review and then break post-submit.
            preconditionFailure(
                "DeploymentConfiguration.legalURLs() failed: \(String(describing: error))",
            )
        }
        legalURLs = legal

        let builtComposition = await AppComposition.production(config: config)
        let builtPushVM = await builtComposition.pushViewModel()
        // Kick the push VM's state machine so an OS-level grant from
        // a previous session auto-restarts registration. The call
        // returns quickly — authorization status is a local OS read.
        await builtPushVM.start()

        let builtShell = AppShell(
            composition: builtComposition,
            pushViewModel: builtPushVM,
        )
        await builtShell.start()

        composition = builtComposition
        pushViewModel = builtPushVM
        shell = builtShell
        isBootstrapped = true
    }
}
