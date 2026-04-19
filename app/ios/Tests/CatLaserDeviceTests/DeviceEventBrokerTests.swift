import CatLaserDevice
import CatLaserDeviceTestSupport
import CatLaserProto
import Foundation
import Testing

/// Behaviour tests for ``DeviceEventBroker``.
///
/// The broker is the single consumer of ``DeviceClient.events`` and
/// fans the stream out to:
///
/// 1. Observable "latest X" properties (``latestStatus``,
///    ``latestSessionSummary``, ``latestHopperEmptyAt``), read by
///    screens like the live-view overlay.
/// 2. Per-subscriber ``AsyncStream`` handles returned from
///    ``events()``, consumed by flow-shaped observers like
///    ``HistoryViewModel`` for ``NewCatDetected``.
///
/// Every test spins a real ``DeviceClient`` + ``InMemoryDeviceTransport``
/// so the broker's interaction with the actual stream object is
/// covered (not a mocked-out shape).
@MainActor
@Suite("DeviceEventBroker")
struct DeviceEventBrokerTests {
    // MARK: - Harness

    /// Wait up to `timeout` for `predicate()` to become true. Matches
    /// the pattern used by the other VM test suites so a cross-actor
    /// delivery (cooperative pool -> MainActor) has time to settle.
    private func eventually(
        _ predicate: () -> Bool,
        timeout: TimeInterval = 1.0,
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func makeHarness(
        clock: @escaping @Sendable () -> Date = { Date() },
    ) async throws -> (InMemoryDeviceTransport, DeviceClient, DeviceEventBroker) {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport, requestTimeout: 2.0)
        try await client.connect()
        let broker = DeviceEventBroker(client: client, clock: clock)
        return (transport, client, broker)
    }

    private nonisolated func statusEvent(
        sessionActive: Bool,
        cats: [String] = [],
        hopper: Catlaser_App_V1_HopperLevel = .ok,
        uptime: UInt64 = 100,
    ) -> Catlaser_App_V1_DeviceEvent {
        var status = Catlaser_App_V1_StatusUpdate()
        status.sessionActive = sessionActive
        status.activeCatIds = cats
        status.hopperLevel = hopper
        status.uptimeSec = uptime
        status.firmwareVersion = "1.0.0"
        var event = Catlaser_App_V1_DeviceEvent()
        event.statusUpdate = status
        event.requestID = 0
        return event
    }

    private nonisolated func summaryEvent(
        duration: UInt32 = 120,
        pounces: UInt32 = 7,
    ) -> Catlaser_App_V1_DeviceEvent {
        var summary = Catlaser_App_V1_SessionSummary()
        summary.durationSec = duration
        summary.pounceCount = pounces
        summary.engagementScore = 0.8
        summary.endedAt = 1_700_000_000
        var event = Catlaser_App_V1_DeviceEvent()
        event.sessionSummary = summary
        event.requestID = 0
        return event
    }

    private nonisolated func newCatEvent(trackID: UInt32 = 42) -> Catlaser_App_V1_DeviceEvent {
        var payload = Catlaser_App_V1_NewCatDetected()
        payload.trackIDHint = trackID
        payload.confidence = 0.91
        var event = Catlaser_App_V1_DeviceEvent()
        event.newCatDetected = payload
        event.requestID = 0
        return event
    }

    private nonisolated func hopperEmptyEvent() -> Catlaser_App_V1_DeviceEvent {
        var event = Catlaser_App_V1_DeviceEvent()
        event.hopperEmpty = Catlaser_App_V1_HopperEmpty()
        event.requestID = 0
        return event
    }

    // MARK: - Initial state

    @Test
    func initialStateIsNilBeforeStart() async throws {
        let (transport, client, broker) = try await makeHarness()
        defer {
            Task {
                await client.disconnect()
                await transport.close()
            }
        }
        #expect(broker.latestStatus == nil)
        #expect(broker.latestStatusReceivedAt == nil)
        #expect(broker.latestSessionSummary == nil)
        #expect(broker.latestHopperEmptyAt == nil)
        #expect(!broker.isPumping)
        #expect(broker.subscriberCount == 0)
    }

    @Test
    func startIsIdempotent() async throws {
        let (transport, client, broker) = try await makeHarness()
        defer {
            Task {
                broker.stop()
                await client.disconnect()
                await transport.close()
            }
        }
        broker.start()
        broker.start()
        broker.start()
        #expect(broker.isPumping)
    }

    // MARK: - Latest-value properties

    @Test
    func latestStatusUpdatesOnPush() async throws {
        let (transport, client, broker) = try await makeHarness()
        defer {
            Task {
                broker.stop()
                await client.disconnect()
                await transport.close()
            }
        }
        broker.start()

        try transport.deliver(event: statusEvent(sessionActive: true, cats: ["cat-a"]))
        await eventually { broker.latestStatus != nil }

        #expect(broker.latestStatus?.sessionActive == true)
        #expect(broker.latestStatus?.activeCatIds == ["cat-a"])
        #expect(broker.latestStatusReceivedAt != nil)
    }

    @Test
    func latestStatusOverwritesWithNewerPush() async throws {
        let fixedNow: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_000) }
        let (transport, client, broker) = try await makeHarness(clock: fixedNow)
        defer {
            Task {
                broker.stop()
                await client.disconnect()
                await transport.close()
            }
        }
        broker.start()

        try transport.deliver(event: statusEvent(sessionActive: false))
        await eventually { broker.latestStatus != nil }
        #expect(broker.latestStatus?.sessionActive == false)

        try transport.deliver(event: statusEvent(sessionActive: true, cats: ["cat-b"]))
        await eventually { broker.latestStatus?.sessionActive == true }
        #expect(broker.latestStatus?.activeCatIds == ["cat-b"])
        #expect(broker.latestStatusReceivedAt == Date(timeIntervalSince1970: 1_000))
    }

    @Test
    func latestSessionSummaryPublishedOnPush() async throws {
        let (transport, client, broker) = try await makeHarness()
        defer {
            Task {
                broker.stop()
                await client.disconnect()
                await transport.close()
            }
        }
        broker.start()

        try transport.deliver(event: summaryEvent(duration: 180, pounces: 5))
        await eventually { broker.latestSessionSummary != nil }

        #expect(broker.latestSessionSummary?.durationSec == 180)
        #expect(broker.latestSessionSummary?.pounceCount == 5)
        #expect(broker.latestSessionSummaryReceivedAt != nil)
    }

    @Test
    func latestHopperEmptyTimestampPublished() async throws {
        let (transport, client, broker) = try await makeHarness()
        defer {
            Task {
                broker.stop()
                await client.disconnect()
                await transport.close()
            }
        }
        broker.start()

        try transport.deliver(event: hopperEmptyEvent())
        await eventually { broker.latestHopperEmptyAt != nil }
        #expect(broker.latestHopperEmptyAt != nil)
    }

    // MARK: - Fanout subscriptions

    @Test
    func eventsFanoutDeliversToMultipleSubscribers() async throws {
        let (transport, client, broker) = try await makeHarness()
        defer {
            Task {
                broker.stop()
                await client.disconnect()
                await transport.close()
            }
        }
        broker.start()

        let subA = broker.events()
        let subB = broker.events()
        #expect(broker.subscriberCount == 2)

        let taskA = Task {
            var ids: [UInt32] = []
            for await event in subA {
                if case let .newCatDetected(p) = event.event {
                    ids.append(p.trackIDHint)
                    if ids.count >= 2 { break }
                }
            }
            return ids
        }
        let taskB = Task {
            var ids: [UInt32] = []
            for await event in subB {
                if case let .newCatDetected(p) = event.event {
                    ids.append(p.trackIDHint)
                    if ids.count >= 2 { break }
                }
            }
            return ids
        }

        try transport.deliver(event: newCatEvent(trackID: 1))
        try transport.deliver(event: newCatEvent(trackID: 2))

        let resultA = await taskA.value
        let resultB = await taskB.value
        #expect(resultA == [1, 2])
        #expect(resultB == [1, 2])
    }

    @Test
    func subscriberRegisteredAfterStartSeesOnlySubsequentEvents() async throws {
        let (transport, client, broker) = try await makeHarness()
        defer {
            Task {
                broker.stop()
                await client.disconnect()
                await transport.close()
            }
        }
        broker.start()

        // First event flows before anyone subscribes — the fanout
        // therefore drops it (no subscribers). The broker's observable
        // state does still advance; consumers of the flow-shaped
        // subscription surface have documented "from subscribe point
        // forward" semantics.
        try transport.deliver(event: newCatEvent(trackID: 99))
        await eventually { broker.subscriberCount == 0 && broker.isPumping }
        // Allow pump to ingest the first event.
        try await Task.sleep(nanoseconds: 60_000_000)

        let sub = broker.events()
        let task = Task {
            var ids: [UInt32] = []
            for await event in sub {
                if case let .newCatDetected(p) = event.event {
                    ids.append(p.trackIDHint)
                    if ids.count >= 1 { break }
                }
            }
            return ids
        }

        try transport.deliver(event: newCatEvent(trackID: 101))
        let ids = await task.value
        #expect(ids == [101])
    }

    @Test
    func subscriberStreamFinishesOnStop() async throws {
        let (transport, client, broker) = try await makeHarness()
        defer {
            Task {
                await client.disconnect()
                await transport.close()
            }
        }
        broker.start()

        let sub = broker.events()
        let task = Task {
            var count = 0
            for await _ in sub { count += 1 }
            return count
        }

        broker.stop()
        let count = await task.value
        #expect(count == 0)
        #expect(broker.subscriberCount == 0)
    }

    @Test
    func subscriberStreamFinishesOnUnderlyingStreamClose() async throws {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport, requestTimeout: 2.0)
        try await client.connect()
        let broker = DeviceEventBroker(client: client)
        broker.start()

        let sub = broker.events()
        let task = Task {
            var count = 0
            for await _ in sub { count += 1 }
            return count
        }

        // Close the device-side stream.
        await client.disconnect()
        let count = await task.value
        #expect(count == 0)
        await transport.close()
    }

    @Test
    func stopIsIdempotent() async throws {
        let (transport, client, broker) = try await makeHarness()
        defer {
            Task {
                await client.disconnect()
                await transport.close()
            }
        }
        broker.start()
        broker.stop()
        broker.stop()
        broker.stop()
        #expect(!broker.isPumping)
    }

    @Test
    func startAfterStopIsRejected() async throws {
        let (transport, client, broker) = try await makeHarness()
        defer {
            Task {
                await client.disconnect()
                await transport.close()
            }
        }
        broker.start()
        broker.stop()
        broker.start()
        #expect(!broker.isPumping)
    }

    @Test
    func eventsAfterStopReturnsImmediatelyFinishedStream() async throws {
        let (transport, client, broker) = try await makeHarness()
        defer {
            Task {
                await client.disconnect()
                await transport.close()
            }
        }
        broker.start()
        broker.stop()

        let sub = broker.events()
        var count = 0
        for await _ in sub {
            count += 1
        }
        #expect(count == 0)
    }

    // MARK: - Defensive: correlated responses do not leak

    @Test
    func correlatedResponsesAreIgnoredByBroker() async throws {
        let (transport, client, broker) = try await makeHarness()
        defer {
            Task {
                broker.stop()
                await client.disconnect()
                await transport.close()
            }
        }
        broker.start()

        // A correlated (request_id != 0) status event should NOT move
        // the broker's latest-state. The DeviceClient routes these to
        // the matching request continuation; the fact that one could
        // land on the events stream — e.g. a late-arrival after a
        // local timeout — is defended against by the broker's
        // request_id=0 filter.
        var status = Catlaser_App_V1_StatusUpdate()
        status.sessionActive = true
        var event = Catlaser_App_V1_DeviceEvent()
        event.statusUpdate = status
        event.requestID = 12345

        try transport.deliver(event: event)
        try await Task.sleep(nanoseconds: 60_000_000)

        #expect(broker.latestStatus == nil)
    }
}
