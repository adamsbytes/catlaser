import Foundation
import Testing

@testable import CatLaserPush

@Suite("PushToken")
struct PushTokenTests {
    @Test
    func hexEncodesLowerCaseWithPaddingForSmallBytes() throws {
        // 32 byte tokens with every low-bit representation. APNs hex
        // is always lowercase with zero-padding; a regression that
        // dropped the pad would produce a shorter string and fail
        // the server-side dedupe.
        let bytes = Data([
            0x00, 0x0F, 0x10, 0xFF,
            0x01, 0xAB, 0x7F, 0x80,
            0x12, 0x34, 0x56, 0x78,
            0x9A, 0xBC, 0xDE, 0xF0,
            0x00, 0x01, 0x02, 0x03,
            0xFC, 0xFD, 0xFE, 0xFF,
            0xAA, 0x55, 0x11, 0x22,
            0x33, 0x44, 0x88, 0x99,
        ])
        let token = try PushToken(rawBytes: bytes)
        let expected = "000f10ff"
            + "01ab7f80"
            + "12345678"
            + "9abcdef0"
            + "00010203"
            + "fcfdfeff"
            + "aa551122"
            + "33448899"
        #expect(token.hex == expected)
        #expect(token.hex.count == 64)
    }

    @Test
    func roundTripFromHexPreservesValue() throws {
        // Construct via hex and via raw bytes — the two must produce
        // byte-identical canonical forms. This pins the no-uppercase
        // invariant the rest of the stack relies on.
        let bytes = Data((0 ..< 32).map { UInt8($0) })
        let fromBytes = try PushToken(rawBytes: bytes)
        let fromHex = try PushToken(hex: fromBytes.hex)
        #expect(fromBytes == fromHex)
    }

    @Test
    func rejectsEmptyBytes() {
        #expect(throws: PushError.self) { _ = try PushToken(rawBytes: Data()) }
    }

    @Test
    func rejectsTooShortBytes() {
        // 31 bytes — historically APNs always sent 32. Anything
        // shorter is a client bug or a hostile input.
        let bytes = Data(repeating: 0xAB, count: PushToken.minimumLength - 1)
        #expect(throws: PushError.self) { _ = try PushToken(rawBytes: bytes) }
    }

    @Test
    func rejectsTooLongBytes() {
        // 101 bytes — exceeds the APNs-documented ceiling.
        let bytes = Data(repeating: 0x42, count: PushToken.maximumLength + 1)
        #expect(throws: PushError.self) { _ = try PushToken(rawBytes: bytes) }
    }

    @Test
    func acceptsExactlyMaxLength() throws {
        // Corner: exactly 100 bytes is ALLOWED so a future APNs
        // widening up to the documented ceiling still works without
        // an app update.
        let bytes = Data(repeating: 0x42, count: PushToken.maximumLength)
        let token = try PushToken(rawBytes: bytes)
        #expect(token.hex.count == PushToken.maximumLength * 2)
    }

    @Test
    func rejectsOddLengthHex() {
        let hex = String(repeating: "a", count: 65)
        #expect(throws: PushError.self) { _ = try PushToken(hex: hex) }
    }

    @Test
    func rejectsUpperCaseHex() {
        // Uppercase must be rejected — the device-side row and the
        // server-side FCM target use lowercase exclusively. A silent
        // accept would produce a duplicate row on every register.
        let hex = String(repeating: "AB", count: 32)
        #expect(throws: PushError.self) { _ = try PushToken(hex: hex) }
    }

    @Test
    func rejectsNonHexCharacter() {
        let hex = String(repeating: "g", count: 64)
        #expect(throws: PushError.self) { _ = try PushToken(hex: hex) }
    }

    @Test
    func rejectsEmptyHex() {
        #expect(throws: PushError.self) { _ = try PushToken(hex: "") }
    }

    @Test
    func valuesAreEquatable() throws {
        let lhs = try PushToken(rawBytes: Data(repeating: 0x01, count: 32))
        let rhs = try PushToken(rawBytes: Data(repeating: 0x01, count: 32))
        let different = try PushToken(rawBytes: Data(repeating: 0x02, count: 32))
        #expect(lhs == rhs)
        #expect(lhs != different)
    }
}
