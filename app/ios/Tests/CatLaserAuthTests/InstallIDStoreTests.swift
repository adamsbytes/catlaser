import Foundation
import Testing

@testable import CatLaserAuth

@Suite("InMemoryInstallIDStore")
struct InMemoryInstallIDStoreTests {
    @Test
    func generatesIDOnFirstUseAndPersists() async throws {
        let store = InMemoryInstallIDStore()
        let first = try await store.currentID()
        let second = try await store.currentID()
        #expect(first == second)
        #expect(!first.isEmpty)
    }

    @Test
    func respectsInitialValue() async throws {
        let store = InMemoryInstallIDStore(initial: "pre-seeded")
        let id = try await store.currentID()
        #expect(id == "pre-seeded")
    }

    @Test
    func resetForcesRegeneration() async throws {
        // Custom generator lets us assert the new ID differs from the old.
        let counter = Counter()
        let store = InMemoryInstallIDStore(
            initial: nil,
            generator: { "id-\(counter.next())" },
        )
        let first = try await store.currentID()
        #expect(first == "id-0")
        try await store.reset()
        let second = try await store.currentID()
        #expect(second == "id-1")
        #expect(first != second)
    }

    @Test
    func defaultGeneratorReturnsValidUUID() async throws {
        let store = InMemoryInstallIDStore()
        let id = try await store.currentID()
        #expect(UUID(uuidString: id) != nil, "expected UUID string, got \(id)")
    }

    @Test
    func concurrentAccessReturnsSameID() async throws {
        let store = InMemoryInstallIDStore()
        let ids = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    (try? await store.currentID()) ?? ""
                }
            }
            var collected: [String] = []
            for await id in group {
                collected.append(id)
            }
            return collected
        }
        #expect(ids.count == 32)
        let unique = Set(ids)
        #expect(unique.count == 1, "32 concurrent readers must see the same ID; saw \(unique.count)")
        let expected = try await store.currentID()
        #expect(unique == [expected])
    }
}

// Counter actor used by tests above — not a production type.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}

#if canImport(Security) && canImport(Darwin)
import Security

@Suite("KeychainInstallIDStore")
struct KeychainInstallIDStoreTests {
    private func uniqueStore(generator: @escaping @Sendable () -> String = { UUID().uuidString }) -> KeychainInstallIDStore {
        let service = "com.catlaser.tests.install.\(UUID().uuidString)"
        return KeychainInstallIDStore(
            service: service,
            account: "install-id",
            accessGroup: nil,
            generator: generator,
        )
    }

    @Test
    func generatesOnFirstUse() async throws {
        let store = uniqueStore()
        let id = try await store.currentID()
        #expect(UUID(uuidString: id) != nil)
        try await store.reset()
    }

    @Test
    func stableAcrossReads() async throws {
        let store = uniqueStore()
        let a = try await store.currentID()
        let b = try await store.currentID()
        #expect(a == b)
        try await store.reset()
    }

    @Test
    func resetThenReadGeneratesNewID() async throws {
        let store = uniqueStore()
        let a = try await store.currentID()
        try await store.reset()
        let b = try await store.currentID()
        #expect(a != b)
        try await store.reset()
    }

    @Test
    func resetOnEmptyStoreIsNoOp() async throws {
        let store = uniqueStore()
        try await store.reset()
        try await store.reset()
        let id = try await store.currentID()
        #expect(!id.isEmpty)
        try await store.reset()
    }

    @Test
    func emptyGeneratedIDIsRejected() async throws {
        let store = uniqueStore(generator: { "" })
        do {
            _ = try await store.currentID()
            Issue.record("expected failure for empty generated id")
        } catch let AuthError.fingerprintCaptureFailed(msg) {
            #expect(msg.contains("empty"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        try await store.reset()
    }

    // MARK: - H1: kSecAttrSynchronizable enforcement

    @Test
    func persistedItemIsNotSynchronizable() async throws {
        // Security-critical: the install ID must never land in an iCloud-Keychain-
        // synchronizing slot. If it does, every device paired to the user's iCloud
        // account reads the same install ID, collapsing the per-device fingerprint
        // defence against email-interception phishing.
        let uuid = UUID().uuidString
        let service = "com.catlaser.tests.install.\(uuid)"
        let store = KeychainInstallIDStore(
            service: service,
            account: "install-id",
            accessGroup: nil,
            generator: { "unit-test-id" },
        )
        _ = try await store.currentID()
        defer { Task { try? await store.reset() } }

        // Query for synchronizable items only — must not see ours.
        let syncQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "install-id",
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let syncStatus = SecItemCopyMatching(syncQuery as CFDictionary, &item)
        #expect(syncStatus == errSecItemNotFound, "install ID was written with synchronizable=true — leaks across iCloud Keychain paired devices")

        // Query explicitly for non-synchronizable items — must see ours.
        let nonSyncQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "install-id",
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var found: CFTypeRef?
        let nonSyncStatus = SecItemCopyMatching(nonSyncQuery as CFDictionary, &found)
        #expect(nonSyncStatus == errSecSuccess, "install ID must be findable under synchronizable=false")
        if let data = found as? Data, let value = String(data: data, encoding: .utf8) {
            #expect(value == "unit-test-id")
        } else {
            Issue.record("expected Data with UTF-8 content")
        }
    }

    @Test
    func ignoresPreExistingSynchronizableItemUnderSameServiceAndAccount() async throws {
        // Attacker scenario: a previous build (or a buggy restore-from-backup)
        // left a synchronizable item under the same (service, account). Our
        // store must ignore it entirely — read must fall through to
        // generation, and write must not silently update the sync item.
        let uuid = UUID().uuidString
        let service = "com.catlaser.tests.install.\(uuid)"
        let account = "install-id"

        // Inject a synchronizable value by hand.
        let injected = "POISONED-SYNC-VALUE"
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(injected.utf8),
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        // May fail in some test environments that don't permit synchronizable
        // writes (no iCloud keychain entitlement). In that case the scenario
        // we're defending against can't occur on this machine, and the test
        // is vacuously satisfied — skip.
        guard addStatus == errSecSuccess else { return }
        defer {
            let cleanup: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            ]
            _ = SecItemDelete(cleanup as CFDictionary)
        }

        let store = KeychainInstallIDStore(
            service: service,
            account: account,
            accessGroup: nil,
            generator: { "CORRECT-NONSYNC-VALUE" },
        )
        let read = try await store.currentID()
        #expect(read == "CORRECT-NONSYNC-VALUE", "store must not return the synchronizable poisoned value")
        #expect(read != injected)
        try await store.reset()

        // Poisoned sync item must still be intact — our delete must not have
        // purged it (defence-in-depth: we don't touch items that aren't ours).
        let verifyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecReturnData as String: kCFBooleanTrue as Any,
        ]
        var leftover: CFTypeRef?
        let verifyStatus = SecItemCopyMatching(verifyQuery as CFDictionary, &leftover)
        #expect(verifyStatus == errSecSuccess, "non-synchronizable reset must not touch the synchronizable item")
    }
}

#endif
