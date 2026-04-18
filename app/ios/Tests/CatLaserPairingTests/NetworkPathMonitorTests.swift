import CatLaserPairing
import CatLaserPairingTestSupport
import Foundation
import Testing

@Suite("NetworkPathMonitor (fake)")
struct NetworkPathMonitorFakeTests {
    @Test
    func emitsInitialStatusOnStart() async {
        let monitor = FakeNetworkPathMonitor(currentAtStart: .satisfied)
        let stream = await monitor.start()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == .satisfied)
        await monitor.stop()
    }

    @Test
    func emitsSubsequentEventsInOrder() async {
        let monitor = FakeNetworkPathMonitor(currentAtStart: .unsatisfied)
        let stream = await monitor.start()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial == .unsatisfied)

        await monitor.emit(.satisfied)
        let satisfied = await iterator.next()
        #expect(satisfied == .satisfied)

        await monitor.emit(.unsatisfied)
        let dropped = await iterator.next()
        #expect(dropped == .unsatisfied)

        await monitor.stop()
    }

    @Test
    func stopFinishesTheStream() async {
        let monitor = FakeNetworkPathMonitor()
        let stream = await monitor.start()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // initial .satisfied
        await monitor.stop()
        let terminal = await iterator.next()
        #expect(terminal == nil)
    }
}

#if canImport(Network)
@Suite("SystemNetworkPathMonitor (construct)")
struct SystemNetworkPathMonitorTests {
    @Test
    func canBeConstructedAndTornDown() async {
        let monitor = SystemNetworkPathMonitor()
        let stream = await monitor.start()

        // Consume zero-or-one events within a tight timeout — we
        // cannot guarantee the system will emit on demand in a unit-
        // test environment, but `stop()` must finish the stream
        // regardless.
        let collector = Task<Int, Never> {
            var count = 0
            for await _ in stream {
                count += 1
                if count >= 2 { break }
            }
            return count
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        await monitor.stop()
        _ = await collector.value
    }

    @Test
    func secondStartReturnsEmptyStream() async {
        let monitor = SystemNetworkPathMonitor()
        _ = await monitor.start()
        let secondStream = await monitor.start()
        var iterator = secondStream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == nil)
        await monitor.stop()
    }
}
#endif
