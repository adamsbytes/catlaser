import Foundation

public protocol BearerTokenStore: Sendable {
    func save(_ session: AuthSession) async throws
    func load() async throws -> AuthSession?
    func delete() async throws
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
}
