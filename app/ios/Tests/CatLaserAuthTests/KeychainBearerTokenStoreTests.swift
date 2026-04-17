#if canImport(Security) && canImport(Darwin)
import Foundation
import Security
import Testing

@testable import CatLaserAuth

@Suite("KeychainBearerTokenStore")
struct KeychainBearerTokenStoreTests {
    private func uniqueStore(
        policy: KeychainBearerTokenStore.AccessPolicy = .accessibilityOnly,
    ) -> (KeychainBearerTokenStore, String) {
        let service = "com.catlaser.tests.bearer.\(UUID().uuidString)"
        return (
            KeychainBearerTokenStore(
                service: service,
                account: "session",
                accessGroup: nil,
                policy: policy,
            ),
            service,
        )
    }

    private func makeSession(token: String = "bearer-token") -> AuthSession {
        AuthSession(
            bearerToken: token,
            user: AuthUser(id: "u-1", email: "e@example.com", name: "N", image: nil, emailVerified: true),
            provider: .apple,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
    }

    // MARK: - Basic roundtrip (accessibilityOnly policy, no biometric prompts)

    @Test
    func saveThenLoadReturnsSameSession() async throws {
        let (store, _) = uniqueStore()
        let session = makeSession()
        try await store.save(session)
        defer { Task { try? await store.delete() } }
        let loaded = try await store.load()
        #expect(loaded == session)
    }

    @Test
    func loadWhenEmptyReturnsNil() async throws {
        let (store, _) = uniqueStore()
        let loaded = try await store.load()
        #expect(loaded == nil)
    }

    @Test
    func saveOverwritesExisting() async throws {
        let (store, _) = uniqueStore()
        try await store.save(makeSession(token: "first"))
        try await store.save(makeSession(token: "second"))
        defer { Task { try? await store.delete() } }
        let loaded = try await store.load()
        #expect(loaded?.bearerToken == "second")
    }

    @Test
    func deleteRemovesItem() async throws {
        let (store, _) = uniqueStore()
        try await store.save(makeSession())
        try await store.delete()
        #expect(try await store.load() == nil)
    }

    @Test
    func deleteOnEmptyIsIdempotent() async throws {
        let (store, _) = uniqueStore()
        try await store.delete()
        try await store.delete()
        #expect(try await store.load() == nil)
    }

    // MARK: - H1: synchronizable enforcement

    @Test
    func persistedItemIsNotSynchronizable() async throws {
        let (store, service) = uniqueStore()
        try await store.save(makeSession())
        defer { Task { try? await store.delete() } }

        let syncQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "session",
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(syncQuery as CFDictionary, &item)
        #expect(status == errSecItemNotFound, "bearer token wrote to iCloud-Keychain slot — would sync across paired devices")
    }

    @Test
    func loadIgnoresSynchronizableItemUnderSameServiceAndAccount() async throws {
        // Poisoning scenario: a synced item exists under (service, account).
        // The store's queries must not match it.
        let uuid = UUID().uuidString
        let service = "com.catlaser.tests.bearer.\(uuid)"
        let account = "session"
        let poisonSession = AuthSession(
            bearerToken: "ATTACKER-SYNCED-TOKEN",
            user: AuthUser(id: "evil", email: nil, name: nil, image: nil, emailVerified: false),
            provider: .apple,
            establishedAt: Date(timeIntervalSince1970: 1),
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(poisonSession)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { return } // skip if the test env forbids sync writes
        defer {
            let cleanup: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            ]
            _ = SecItemDelete(cleanup as CFDictionary)
        }

        let store = KeychainBearerTokenStore(
            service: service,
            account: account,
            accessGroup: nil,
            policy: .accessibilityOnly,
        )
        // Load must not return the poisoned sync item.
        let loaded = try await store.load()
        #expect(loaded == nil, "store read matched a synchronizable item — leaked attacker-injected token")
    }

    // MARK: - Save semantics (delete-then-add)

    @Test
    func saveReplacesAccessControlOnExistingItem() async throws {
        // A save of an item that currently exists with a different access
        // policy must succeed (by deleting and re-adding), not fail with
        // errSecDuplicateItem nor silently keep the old ACL.
        let uuid = UUID().uuidString
        let service = "com.catlaser.tests.bearer.\(uuid)"
        let first = KeychainBearerTokenStore(
            service: service,
            account: "session",
            accessGroup: nil,
            policy: .accessibilityOnly,
        )
        try await first.save(makeSession(token: "first-policy-accessibilityOnly"))
        defer { Task { try? await first.delete() } }

        // Re-save using the same store should succeed.
        try await first.save(makeSession(token: "second"))
        let loaded = try await first.load()
        #expect(loaded?.bearerToken == "second")
    }
}

#endif
