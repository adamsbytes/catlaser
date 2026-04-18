import Foundation
import Testing

@testable import CatLaserDevice

@Suite("AppRequestIDFactory")
struct AppRequestIDTests {
    @Test
    func firstIDIsOne() async {
        let factory = AppRequestIDFactory()
        #expect(await factory.next() == 1)
    }

    @Test
    func sequentialIDsIncrement() async {
        let factory = AppRequestIDFactory()
        for expected in UInt32(1) ... 5 {
            #expect(await factory.next() == expected)
        }
    }

    @Test
    func wrapsFromMaxBackToOne() async {
        let factory = AppRequestIDFactory()
        await factory._setCounterForTest(UInt32.max - 1)
        #expect(await factory.next() == UInt32.max)
        #expect(await factory.next() == 1)
        #expect(await factory.next() == 2)
    }

    @Test
    func neverReturnsZero() async {
        // Scan a narrow window including the wrap boundary and
        // confirm 0 never appears.
        let factory = AppRequestIDFactory()
        await factory._setCounterForTest(UInt32.max - 2)
        for _ in 0 ..< 5 {
            #expect(await factory.next() != 0)
        }
    }
}
