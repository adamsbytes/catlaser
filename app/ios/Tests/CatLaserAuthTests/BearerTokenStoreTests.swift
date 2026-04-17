import Foundation
import Testing

@testable import CatLaserAuth

@Suite("BearerTokenStore (in-memory)")
struct InMemoryBearerTokenStoreTests {
    private func makeSession(token: String = "t") -> AuthSession {
        AuthSession(
            bearerToken: token,
            user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
            provider: .apple,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
    }

    @Test
    func emptyLoadReturnsNil() async throws {
        let store = InMemoryBearerTokenStore()
        #expect(try await store.load() == nil)
    }

    @Test
    func saveThenLoad() async throws {
        let store = InMemoryBearerTokenStore()
        let session = makeSession()
        try await store.save(session)
        let loaded = try await store.load()
        #expect(loaded == session)
    }

    @Test
    func saveOverwrites() async throws {
        let store = InMemoryBearerTokenStore()
        try await store.save(makeSession(token: "a"))
        try await store.save(makeSession(token: "b"))
        let loaded = try await store.load()
        #expect(loaded?.bearerToken == "b")
    }

    @Test
    func deleteRemovesSession() async throws {
        let store = InMemoryBearerTokenStore()
        try await store.save(makeSession())
        try await store.delete()
        #expect(try await store.load() == nil)
    }

    @Test
    func deleteOnEmptyIsIdempotent() async throws {
        let store = InMemoryBearerTokenStore()
        try await store.delete()
        try await store.delete()
        #expect(try await store.load() == nil)
    }

    @Test
    func initialSessionLoadable() async throws {
        let session = makeSession(token: "initial")
        let store = InMemoryBearerTokenStore(initial: session)
        #expect(try await store.load() == session)
    }

    @Test
    func concurrentSavesSerialized() async throws {
        let store = InMemoryBearerTokenStore()
        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 32 {
                group.addTask {
                    try? await store.save(self.makeSession(token: "t\(index)"))
                }
            }
        }
        let loaded = try await store.load()
        #expect(loaded != nil)
        #expect(loaded!.bearerToken.hasPrefix("t"))
    }
}
