import Foundation

/// Observer that is notified when the authenticated session ends or
/// is rejected server-side.
///
/// `AuthCoordinator.signOut()` invokes `sessionDidSignOut()` on every
/// registered observer after the local session material has been
/// wiped. `AuthCoordinator.handleSessionExpired()` invokes
/// `sessionDidExpire()` when a downstream protected call surfaces an
/// HTTP 401, allowing auxiliary modules to react (drop in-memory
/// caches, surface a sign-in prompt) WITHOUT wiping pairing state
/// that is orthogonal to session freshness.
///
/// Observers are the mechanism by which auxiliary modules — endpoint
/// persistence (`CatLaserPairing`), push-token registrations, any
/// module that caches per-session state outside `BearerTokenStore` —
/// can clear their rows without the auth module having to depend on
/// them.
///
/// ## Semantics
///
/// * `sessionDidSignOut()` is called exactly once per successful
///   `AuthCoordinator.signOut()` invocation. If the server-side
///   revocation call fails, observers are still called — the local
///   session is gone regardless of server acknowledgement.
/// * `sessionDidExpire()` fires once per 401 observed by the signed
///   HTTP client, via `AuthCoordinator.handleSessionExpired()`. It
///   does NOT wipe the keychain or trigger sign-out — the coordinator
///   only invalidates the in-memory bearer cache so the next
///   authenticated call prompts for re-authentication. Observers
///   that want to drive a UI re-sign-in flow implement this method;
///   observers that persist data orthogonal to sessions (pairing
///   endpoint, cat profiles cached client-side) MUST leave their
///   state untouched.
/// * Observers run serially, in registration order. A slow observer
///   does not block other observers; they all complete before the
///   triggering call returns.
/// * Observers MUST NOT throw. A failure to wipe local state inside
///   an observer is a diagnostic concern, not something to surface
///   up through the triggering call. Observers should swallow their
///   own errors (optionally logging them) so one module's storage
///   failure does not prevent propagation.
///
/// Observers are `Sendable` because `AuthCoordinator` is an `actor`
/// and calls them from its isolation domain; implementations that
/// hold mutable state must ensure the state is thread-safe (actor or
/// value-type).
public protocol SessionLifecycleObserver: Sendable {
    func sessionDidSignOut() async

    /// Called when the coordination server rejected the current
    /// bearer with HTTP 401 on a protected call.
    ///
    /// The default implementation is a no-op. Modules that care
    /// about re-authentication UX (the app-level coordinator) override
    /// it to route the user through sign-in. Modules whose state is
    /// orthogonal to session freshness (the pairing endpoint store)
    /// leave the default so a 401 never wipes their rows.
    func sessionDidExpire() async
}

public extension SessionLifecycleObserver {
    /// Default: do nothing. The rationale for the default is load-
    /// bearing to the pairing module's correctness story: an observer
    /// like `KeychainEndpointStore` that wipes on sign-out must NOT
    /// wipe on session expiry, and the easiest way to guarantee that
    /// is a default that simply does nothing. Observers that want to
    /// react to 401s override this method explicitly.
    func sessionDidExpire() async {}
}
