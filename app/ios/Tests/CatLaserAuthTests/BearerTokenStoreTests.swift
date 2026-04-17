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
    func cachedSessionReflectsCurrentState() async throws {
        let store = InMemoryBearerTokenStore()
        #expect(await store.cachedSession() == nil)

        let session = makeSession(token: "cached")
        try await store.save(session)
        #expect(await store.cachedSession() == session)

        try await store.delete()
        #expect(await store.cachedSession() == nil)
    }

    @Test
    func cachedSessionDefaultReturnsNil() async {
        // A store that inherits the default `cachedSession()` from the
        // protocol extension must return nil. Regression guard for
        // implementations that forget to override the default (e.g. the
        // production `KeychainBearerTokenStore`, which has no in-process
        // cache and therefore must report a cold cache — `signOut` then
        // silently skips the server call instead of prompting).
        struct NoCacheStore: BearerTokenStore {
            func save(_: AuthSession) async throws {}
            func load() async throws -> AuthSession? { nil }
            func delete() async throws {}
            // Deliberately NOT overriding cachedSession().
        }
        let store = NoCacheStore()
        #expect(await store.cachedSession() == nil)
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
