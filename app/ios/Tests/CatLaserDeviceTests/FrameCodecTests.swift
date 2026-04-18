import Foundation
import Testing

@testable import CatLaserDevice

@Suite("FrameCodec")
struct FrameCodecTests {
    // MARK: - Encode

    @Test
    func encodesEmptyPayload() throws {
        let framed = try FrameCodec.encode(Data())
        #expect(framed == Data([0x00, 0x00, 0x00, 0x00]))
    }

    @Test
    func encodesOneBytePayload() throws {
        let framed = try FrameCodec.encode(Data([0x42]))
        #expect(framed == Data([0x01, 0x00, 0x00, 0x00, 0x42]))
    }

    @Test
    func encodesMultiBytePayloadAsLittleEndianLength() throws {
        let payload = Data(repeating: 0xAB, count: 300) // 300 = 0x012C
        let framed = try FrameCodec.encode(payload)
        #expect(framed.prefix(4) == Data([0x2C, 0x01, 0x00, 0x00]))
        #expect(framed.count == 304)
        #expect(framed.dropFirst(4) == payload)
    }

    @Test
    func encodesAtExactMaxBoundary() throws {
        let payload = Data(repeating: 0xAA, count: FrameCodec.maxMessageSize)
        let framed = try FrameCodec.encode(payload)
        #expect(framed.count == FrameCodec.maxMessageSize + FrameCodec.headerSize)
    }

    @Test
    func rejectsPayloadAboveMax() {
        let payload = Data(repeating: 0xFF, count: FrameCodec.maxMessageSize + 1)
        do {
            _ = try FrameCodec.encode(payload)
            Issue.record("expected throw")
        } catch let FrameCodecError.payloadTooLarge(length, limit) {
            #expect(length == FrameCodec.maxMessageSize + 1)
            #expect(limit == FrameCodec.maxMessageSize)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    // MARK: - Reader (happy path)

    @Test
    func decodesSingleCompleteFrame() throws {
        var reader = FrameReader()
        let framed = try FrameCodec.encode(Data([0xDE, 0xAD, 0xBE, 0xEF]))
        reader.feed(framed)
        let payload = try reader.nextFrame()
        #expect(payload == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(try reader.nextFrame() == nil)
    }

    @Test
    func decodesMultipleFramesInOneFeed() throws {
        var reader = FrameReader()
        let a = try FrameCodec.encode(Data([0x01, 0x02]))
        let b = try FrameCodec.encode(Data([0x03, 0x04, 0x05]))
        reader.feed(a + b)
        #expect(try reader.nextFrame() == Data([0x01, 0x02]))
        #expect(try reader.nextFrame() == Data([0x03, 0x04, 0x05]))
        #expect(try reader.nextFrame() == nil)
    }

    @Test
    func reassemblesPartialHeaderAcrossFeeds() throws {
        var reader = FrameReader()
        let framed = try FrameCodec.encode(Data([0xAB, 0xCD]))
        reader.feed(framed.prefix(2))
        #expect(try reader.nextFrame() == nil)
        reader.feed(framed.dropFirst(2))
        #expect(try reader.nextFrame() == Data([0xAB, 0xCD]))
    }

    @Test
    func reassemblesPartialPayloadAcrossFeeds() throws {
        var reader = FrameReader()
        let payload = Data((0 ..< 32).map { UInt8($0) })
        let framed = try FrameCodec.encode(payload)
        // Feed header + 10 bytes, then remainder.
        reader.feed(framed.prefix(14))
        #expect(try reader.nextFrame() == nil)
        reader.feed(framed.dropFirst(14))
        #expect(try reader.nextFrame() == payload)
    }

    @Test
    func byteByByteFeedYieldsCompleteFrame() throws {
        var reader = FrameReader()
        let payload = Data([0x01, 0x02, 0x03])
        let framed = try FrameCodec.encode(payload)
        for byte in framed {
            #expect(try reader.nextFrame() == nil)
            reader.feed(Data([byte]))
        }
        #expect(try reader.nextFrame() == payload)
    }

    @Test
    func emptyFrameRoundTrips() throws {
        var reader = FrameReader()
        let framed = try FrameCodec.encode(Data())
        reader.feed(framed)
        #expect(try reader.nextFrame() == Data())
    }

    // MARK: - Reader (overflow)

    @Test
    func readerThrowsOnOversizedFrame() throws {
        var reader = FrameReader()
        // Craft a header that declares max+1, followed by partial bytes.
        var header = Data(count: 4)
        let declared = UInt32(FrameCodec.maxMessageSize + 1).littleEndian
        withUnsafeBytes(of: declared) { header.replaceSubrange(0 ..< 4, with: $0) }
        reader.feed(header + Data(repeating: 0x00, count: 10))
        do {
            _ = try reader.nextFrame()
            Issue.record("expected throw")
        } catch let FrameCodecError.frameTooLarge(length, limit) {
            #expect(length == FrameCodec.maxMessageSize + 1)
            #expect(limit == FrameCodec.maxMessageSize)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test
    func readerDrainsBufferOnOverflow() throws {
        var reader = FrameReader()
        var header = Data(count: 4)
        let declared = UInt32(FrameCodec.maxMessageSize + 1).littleEndian
        withUnsafeBytes(of: declared) { header.replaceSubrange(0 ..< 4, with: $0) }
        // Feed header + 10 bytes of partial payload. After the throw,
        // the drain consumes (header + min(declared, buffered)) which
        // here is header + 10.
        reader.feed(header + Data(repeating: 0xCC, count: 10))
        #expect(throws: FrameCodecError.frameTooLarge(length: FrameCodec.maxMessageSize + 1, limit: FrameCodec.maxMessageSize)) {
            _ = try reader.nextFrame()
        }
        #expect(reader.bufferedByteCount == 0)
    }

    // MARK: - Parity with Python wire.py

    /// Cross-check against the Python reference implementation's byte
    /// layout — `[4 bytes LE u32 length][N bytes]`. Use a magic number
    /// that's asymmetric across bytes so a misbyte-ordered encoder
    /// would not accidentally pass.
    @Test
    func lengthIsLittleEndianU32() throws {
        // Byte-asymmetric payload length so a big-endian bug cannot
        // pass accidentally. Chosen below `maxMessageSize` so encode
        // doesn't refuse.
        let length = 0x0004_0203 // 262659 bytes, well under 1 MiB.
        let payload = Data(repeating: 0x00, count: length)
        let framed = try FrameCodec.encode(payload)
        #expect(framed.prefix(4) == Data([0x03, 0x02, 0x04, 0x00]))
    }
}
