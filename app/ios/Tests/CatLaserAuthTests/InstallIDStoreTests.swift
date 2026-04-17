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
}

#endif
