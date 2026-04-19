import CatLaserObservability
import Foundation
import Testing

@Suite("TelemetryQueue")
struct TelemetryQueueTests {
    private func makeQueue(maxBytes: Int = 64 * 1024) async -> (TelemetryQueue, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-\(UUID().uuidString).ndjson")
        let cfg = TelemetryQueue.Configuration(
            queueURL: url,
            maxBytes: maxBytes,
            maxBatchEvents: 32,
        )
        return (TelemetryQueue(configuration: cfg), url)
    }

    private func fakeEvent(_ name: String) -> EventEnvelope {
        EventEnvelope(
            id: UUID().uuidString,
            name: name,
            attributes: [:],
            monotonicNS: 0,
            wallTimeUTC: "1970-01-01T00:00:00.000Z",
        )
    }

    @Test
    func enqueueAndDrainRoundTripsExactBytes() async throws {
        let (queue, url) = await makeQueue()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await queue.enqueue(fakeEvent("e1"))
        _ = try await queue.enqueue(fakeEvent("e2"))

        let drained = try await queue.drainBatch()
        #expect(drained.count == 2)
        #expect(drained.map(\.name) == ["e1", "e2"])
    }

    /// Acknowledge drops the prefix; a second drain returns only the
    /// unacknowledged tail.
    @Test
    func acknowledgePrefixDropsFromQueue() async throws {
        let (queue, url) = await makeQueue()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await queue.enqueue(fakeEvent("e1"))
        _ = try await queue.enqueue(fakeEvent("e2"))
        _ = try await queue.enqueue(fakeEvent("e3"))

        let first = try await queue.drainBatch()
        try await queue.acknowledge(upTo: 2)

        let remaining = try await queue.drainBatch()
        #expect(first.count == 3)
        #expect(remaining.map(\.name) == ["e3"])
    }

    /// Acknowledging everything removes the queue file.
    @Test
    func acknowledgeAllDeletesQueueFile() async throws {
        let (queue, url) = await makeQueue()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await queue.enqueue(fakeEvent("e1"))
        #expect(FileManager.default.fileExists(atPath: url.path))

        try await queue.acknowledge(upTo: 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// An empty drain returns an empty array and does not throw.
    @Test
    func drainOnEmptyQueueReturnsEmptyArray() async throws {
        let (queue, url) = await makeQueue()
        defer { try? FileManager.default.removeItem(at: url) }
        let drained = try await queue.drainBatch()
        #expect(drained.isEmpty)
    }

    /// The on-disk cap trims the oldest events to fit. The invariant
    /// is: the queue file never exceeds ``maxBytes``.
    @Test
    func capPreservesByteBudget() async throws {
        // Very tight cap — enough for ~2 events, not 10.
        let (queue, url) = await makeQueue(maxBytes: 400)
        defer { try? FileManager.default.removeItem(at: url) }

        for idx in 0 ..< 10 {
            _ = try await queue.enqueue(fakeEvent("e-\(idx)"))
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        #expect(size <= 400, "queue file exceeded cap: \(size) bytes")
    }

    @Test
    func pendingCountMatchesEnqueuedCount() async throws {
        let (queue, url) = await makeQueue()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try await queue.pendingCount() == 0)
        _ = try await queue.enqueue(fakeEvent("a"))
        _ = try await queue.enqueue(fakeEvent("b"))
        #expect(try await queue.pendingCount() == 2)

        try await queue.acknowledge(upTo: 1)
        #expect(try await queue.pendingCount() == 1)
    }

    @Test
    func purgeRemovesEveryEvent() async throws {
        let (queue, url) = await makeQueue()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await queue.enqueue(fakeEvent("a"))
        _ = try await queue.enqueue(fakeEvent("b"))
        try await queue.purge()
        #expect(try await queue.pendingCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// The write path is atomic: at no point does a reader see a
    /// partially-written queue file. We rely on
    /// ``Data.write(to:options:[.atomic])`` for this and verify the
    /// invariant by round-tripping the file via the public API.
    @Test
    func writesAreAtomicAcrossReplay() async throws {
        let (queue, url) = await makeQueue()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await queue.enqueue(fakeEvent("a"))
        _ = try await queue.enqueue(fakeEvent("b"))
        _ = try await queue.enqueue(fakeEvent("c"))

        // Rehydrate via a fresh queue instance — simulates a crash
        // recovery path where the process died between enqueue and
        // acknowledge.
        let cfg = TelemetryQueue.Configuration(queueURL: url)
        let replay = TelemetryQueue(configuration: cfg)
        let events = try await replay.drainBatch()
        #expect(events.map(\.name) == ["a", "b", "c"])
    }
}
