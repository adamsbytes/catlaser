import Foundation

public protocol BearerTokenStore: Sendable {
    func save(_ session: AuthSession) async throws
    func load() async throws -> AuthSession?
    func delete() async throws
}

public actor InMemoryBearerTokenStore: BearerTokenStore {
    private var session: AuthSession?

    public init(initial: AuthSession? = nil) {
        self.session = initial
    }

    public func save(_ session: AuthSession) async throws {
        self.session = session
    }

    public func load() async throws -> AuthSession? {
        session
    }

    public func delete() async throws {
        session = nil
    }
}
