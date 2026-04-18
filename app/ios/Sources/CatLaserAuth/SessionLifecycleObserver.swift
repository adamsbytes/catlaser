import Foundation

/// Observer that is notified when the authenticated session ends.
///
/// `AuthCoordinator.signOut()` invokes every registered observer after
/// the local session material has been wiped. Observers are the
/// mechanism by which auxiliary modules — endpoint persistence
/// (`CatLaserPairing`), push-token registrations, any module that
/// caches per-session state outside `BearerTokenStore` — can clear
/// their rows without the auth module having to depend on them.
///
/// ## Semantics
///
/// * `sessionDidSignOut()` is called exactly once per successful
///   `AuthCoordinator.signOut()` invocation. If the server-side
///   revocation call fails, observers are still called — the local
///   session is gone regardless of server acknowledgement.
/// * Observers run serially, in registration order. A slow observer
///   does not block other observers; they all complete before
///   `signOut()` returns.
/// * Observers MUST NOT throw. A failure to wipe local state inside
///   an observer is a diagnostic concern, not something to surface
///   up through sign-out. Observers should swallow their own errors
///   (optionally logging them) so one module's storage failure does
///   not prevent sign-out from completing.
///
/// Observers are `Sendable` because `AuthCoordinator` is an `actor`
/// and calls them from its isolation domain; implementations that
/// hold mutable state must ensure the state is thread-safe (actor or
/// value-type).
public protocol SessionLifecycleObserver: Sendable {
    func sessionDidSignOut() async
}
