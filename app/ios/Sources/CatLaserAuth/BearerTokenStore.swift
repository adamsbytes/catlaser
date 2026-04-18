import Foundation

public protocol BearerTokenStore: Sendable {
    func save(_ session: AuthSession) async throws
    func load() async throws -> AuthSession?
    func delete() async throws

    /// Return the session if it is already available in memory without
    /// any prompt, unlock, or keychain read. Returns nil when no
    /// in-memory cache is populated — even if a persisted session exists
    /// on disk. Used by UX-sensitive paths (notably `signOut`) where a
    /// biometric prompt would be a trap.
    ///
    /// Default implementation returns nil; stores that maintain an
    /// in-process cache (e.g. `GatedBearerTokenStore`, the test-only
    /// in-memory store) override this with the cached value.
    func cachedSession() async -> AuthSession?
}

public extension BearerTokenStore {
    func cachedSession() async -> AuthSession? { nil }
}

/// Opt-in narrow protocol for bearer stores that maintain an in-memory
/// cache and want to expose cache invalidation without disturbing the
/// persistent keychain row.
///
/// `AuthCoordinator.handleSessionExpired()` checks the configured
/// store for conformance at call time and invokes
/// `invalidateSession()` when present, so the in-memory bearer cache
/// is dropped after a server-side 401 and the next protected call
/// forces a fresh read (and, at that read, a biometric prompt via the
/// keychain's `.userPresence` ACL). The keychain row itself is
/// deliberately untouched: the token is still valid at rest, and the
/// keychain wipe belongs to the `delete()` path, which fires on
/// explicit sign-out, not on bearer rejection.
///
/// Not merged into `BearerTokenStore` because stores that have no
/// in-memory cache (the keychain-only variant, the test-only
/// in-memory store) have nothing to invalidate; making this a narrow
/// opt-in keeps the core protocol unchanged and lets the coordinator
/// feature-detect cleanly.
public protocol SessionInvalidating: Sendable {
    func invalidateSession() async
}

/// In-memory bearer token store. **Test-only**: intentionally internal so
/// it cannot be wired into production from outside the module. Production
/// callers must use `KeychainBearerTokenStore` (optionally wrapped by
/// `GatedBearerTokenStore`); an accidental downgrade to in-memory storage
/// would silently defeat the hardware-backed ACL that protects the bearer
/// token on a stolen unlocked phone. Tests reach this via
/// `@testable import CatLaserAuth`.
actor InMemoryBearerTokenStore: BearerTokenStore {
    private var session: AuthSession?

    init(initial: AuthSession? = nil) {
        self.session = initial
    }

    func save(_ session: AuthSession) async throws {
        self.session = session
    }

    func load() async throws -> AuthSession? {
        session
    }

    func delete() async throws {
        session = nil
    }

    func cachedSession() async -> AuthSession? {
        session
    }
}
