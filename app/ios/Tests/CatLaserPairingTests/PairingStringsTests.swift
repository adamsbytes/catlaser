import Foundation
import Testing

@testable import CatLaserPairing

@Suite("PairingStrings.humanizedDeviceID")
struct PairingStringsHumanizedDeviceIDTests {
    @Test
    func shortAlphanumericRunPassesThrough() {
        // Under the 8-character grouping threshold — spaces would
        // produce noise with no legibility win.
        #expect(PairingStrings.humanizedDeviceID("abc") == "abc")
        #expect(PairingStrings.humanizedDeviceID("abc1") == "abc1")
        #expect(PairingStrings.humanizedDeviceID("1234567") == "1234567")
    }

    @Test
    func alphanumericRunIsChunkedByFours() {
        #expect(PairingStrings.humanizedDeviceID("abcd1234") == "abcd 1234")
        #expect(PairingStrings.humanizedDeviceID("abcd1234ef") == "abcd 1234 ef")
        #expect(PairingStrings.humanizedDeviceID("A4B293F7ABCD") == "A4B2 93F7 ABCD")
    }

    @Test
    func hyphenatedSlugIsNotRegrouped() {
        // Firmware-chosen format must survive byte-for-byte so a
        // printed or spoken identifier matches support tickets.
        let raw = "catlaser-abc123def456"
        #expect(PairingStrings.humanizedDeviceID(raw) == raw)
    }

    @Test
    func underscoredSlugIsNotRegrouped() {
        let raw = "lab_unit_0042"
        #expect(PairingStrings.humanizedDeviceID(raw) == raw)
    }
}
