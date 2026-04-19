import CatLaserObservability
import Foundation
import Testing

@Suite("TombstoneStore")
struct TombstoneStoreTests {
    private func makeStore() -> (TombstoneStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tombstones-\(UUID().uuidString)", isDirectory: true)
        return (TombstoneStore(directory: dir), dir)
    }

    private func fakeTombstone(id: String = UUID().uuidString) -> Tombstone {
        Tombstone(
            id: id,
            reason: .uncaughtException,
            capturedAt: "2026-04-19T00:00:00Z",
            summary: "NSInvalidArgumentException: unrecognized selector",
            callStack: ["0 CoreFoundation foo", "1 libobjc.A.dylib bar"],
            appVersion: "1.0.0",
            buildNumber: "1",
            osVersion: "17.0",
        )
    }

    @Test
    func writeReadAndDeleteRoundTrip() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let tombstone = fakeTombstone()
        try store.writeFromNormalContext(tombstone)

        let pending = try store.pending()
        #expect(pending.count == 1)
        #expect(pending.first?.id == tombstone.id)
        #expect(pending.first?.summary.contains("unrecognized selector") == true)

        try store.delete(id: tombstone.id)
        #expect(try store.pending().isEmpty)
    }

    @Test
    func pendingOnEmptyDirectoryReturnsEmpty() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.pending().isEmpty)
    }

    @Test
    func multipleTombstonesAreAllEnumerated() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = fakeTombstone(id: "a")
        let second = fakeTombstone(id: "b")
        try store.writeFromNormalContext(first)
        try store.writeFromNormalContext(second)

        let pending = try store.pending()
        let ids = Set(pending.map(\.id))
        #expect(ids == ["a", "b"])
    }

    @Test
    func purgeDropsEverything() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.writeFromNormalContext(fakeTombstone(id: "a"))
        try store.writeFromNormalContext(fakeTombstone(id: "b"))
        try store.purge()
        #expect(try store.pending().isEmpty)
    }

    @Test
    func reasonMappingCoversCommonSignals() {
        #expect(Tombstone.reason(for: 6) == .signalSIGABRT)
        #expect(Tombstone.reason(for: 11) == .signalSIGSEGV)
        #expect(Tombstone.reason(for: 4) == .signalSIGILL)
        #expect(Tombstone.reason(for: 8) == .signalSIGFPE)
        #expect(Tombstone.reason(for: 42) == .signalOther)
    }

    @Test
    func summaryIsCappedToOneKB() {
        let huge = String(repeating: "x", count: 10_000)
        let tombstone = Tombstone(
            id: "cap",
            reason: .uncaughtException,
            capturedAt: "",
            summary: huge,
            callStack: nil,
            appVersion: "1", buildNumber: "1", osVersion: "1",
        )
        #expect(tombstone.summary.count == 1024)
    }
}
