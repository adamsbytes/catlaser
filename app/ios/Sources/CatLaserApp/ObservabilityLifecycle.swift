import CatLaserAuth
import CatLaserObservability
import Foundation

/// Adapter that lets ``Observability`` participate in the auth
/// coordinator's lifecycle broadcast without requiring the
/// observability module to depend on the auth module.
///
/// Registered on the ``AuthCoordinator`` at composition time so:
///
/// - On sign-out: record a `signed_out` telemetry event, write a
///   final breadcrumb, and purge all local observability state so
///   the next user on the same device inherits nothing from the
///   previous session.
/// - On session expiry (401 from a protected call): record a
///   `session_expired` event + a breadcrumb; DO NOT purge local
///   state because a 401 is a short-lived re-auth nudge, not a
///   permanent session termination.
struct ObservabilityLifecycleObserver: SessionLifecycleObserver {
    let observability: Observability

    func sessionDidSignOut() async {
        await observability.record(event: .signedOut)
        // Write the final breadcrumb before the purge so it lands
        // in the in-memory ring; the purge then wipes the persisted
        // snapshot along with everything else.
        observability.record(.auth, "session.signed_out")
        await observability.purgeLocalState()
    }

    func sessionDidExpire() async {
        await observability.record(event: .sessionExpired)
        observability.record(.auth, "session.expired")
    }
}
