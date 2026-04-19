import CatLaserObservability
import Foundation
import Testing

@Suite("BreadcrumbRing")
struct BreadcrumbRingTests {
    @Test
    func emptyRingReturnsEmptySnapshot() async {
        let ring = BreadcrumbRing(capacity: 8)
        #expect(await ring.snapshot().isEmpty)
    }

    @Test
    func preservesInsertionOrderBelowCapacity() async {
        let ring = BreadcrumbRing(capacity: 8)
        for idx in 0 ..< 5 {
            await ring.record(
                Breadcrumb(
                    monotonicMillis: UInt64(idx),
                    wallTimestamp: Date(timeIntervalSince1970: 0),
                    kind: .note,
                    name: "n.\(idx)",
                ),
            )
        }
        let snapshot = await ring.snapshot()
        #expect(snapshot.count == 5)
        #expect(snapshot.map(\.name) == ["n.0", "n.1", "n.2", "n.3", "n.4"])
    }

    @Test
    func overwritesOldestWhenCapacityExceeded() async {
        let ring = BreadcrumbRing(capacity: 3)
        for idx in 0 ..< 5 {
            await ring.record(
                Breadcrumb(
                    monotonicMillis: UInt64(idx),
                    wallTimestamp: Date(timeIntervalSince1970: 0),
                    kind: .note,
                    name: "n.\(idx)",
                ),
            )
        }
        let snapshot = await ring.snapshot()
        #expect(snapshot.count == 3)
        // Oldest two were evicted — only the last three survive.
        #expect(snapshot.map(\.name) == ["n.2", "n.3", "n.4"])
    }

    @Test
    func purgeEmptiesTheRingAndDeletesSnapshot() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ring-\(UUID().uuidString).json")
        let ring = BreadcrumbRing(capacity: 4, persistenceURL: url)
        for idx in 0 ..< 3 {
            await ring.record(
                Breadcrumb(
                    monotonicMillis: UInt64(idx),
                    wallTimestamp: Date(timeIntervalSince1970: 0),
                    kind: .auth,
                    name: "auth.\(idx)",
                ),
            )
        }
        #expect(FileManager.default.fileExists(atPath: url.path))

        await ring.purge()
        #expect(await ring.snapshot().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func snapshotIsPersistedToDiskAcrossInstances() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ring-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let original = BreadcrumbRing(capacity: 8, persistenceURL: url)
        await original.record(
            Breadcrumb(
                monotonicMillis: 1,
                wallTimestamp: Date(timeIntervalSince1970: 1_700_000_000),
                kind: .navigation,
                name: "screen.shown",
                attributes: ["screen": "sign_in"],
            ),
        )

        let rehydrated = BreadcrumbRing.restoreFromSnapshot(at: url)
        #expect(rehydrated.count == 1)
        #expect(rehydrated.first?.name == "screen.shown")
        #expect(rehydrated.first?.attributes["screen"] == "sign_in")
    }
}

@Suite("Breadcrumb")
struct BreadcrumbTests {
    @Test
    func attributesTruncateToCap() {
        var attrs: [String: String] = [:]
        for idx in 0 ..< 64 {
            attrs["k\(idx)"] = "v\(idx)"
        }
        let crumb = Breadcrumb(
            monotonicMillis: 0,
            wallTimestamp: Date(timeIntervalSince1970: 0),
            kind: .note,
            name: "test",
            attributes: attrs,
        )
        #expect(crumb.attributes.count == Breadcrumb.maxAttributeKeys + 1,
                "expected \(Breadcrumb.maxAttributeKeys) keys + _truncated marker")
        #expect(crumb.attributes["_truncated"] == "true")
    }

    @Test
    func longAttributeValueIsTruncated() {
        let longValue = String(repeating: "x", count: Breadcrumb.maxAttributeValueLength * 3)
        let crumb = Breadcrumb(
            monotonicMillis: 0,
            wallTimestamp: Date(timeIntervalSince1970: 0),
            kind: .note,
            name: "test",
            attributes: ["k": longValue],
        )
        #expect(crumb.attributes["k"]?.count == Breadcrumb.maxAttributeValueLength)
        #expect(crumb.attributes["_truncated"] == "true")
    }

    @Test
    func roundTripsThroughJSON() throws {
        let crumb = Breadcrumb(
            monotonicMillis: 42,
            wallTimestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .pairing,
            name: "pairing.started",
            attributes: ["entry": "qr"],
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(crumb)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Breadcrumb.self, from: data)
        #expect(decoded == crumb)
    }
}
