import Foundation

/// Pure encode/decode for the app-to-device TCP wire protocol.
///
/// Mirrors `python/catlaser_brain/network/wire.py` byte-for-byte:
///
/// ```
/// [4 bytes: length (LE u32)][N bytes: protobuf]
/// ```
///
/// The `AppRequest` / `DeviceEvent` envelopes handle message-type
/// discrimination, so unlike the Rust↔Python IPC protocol there is no
/// leading type byte. The 1 MiB payload cap matches the Python
/// implementation; larger than the IPC cap because this channel
/// carries JPEG thumbnails inside `CatProfile` and `NewCatDetected`.
public enum FrameCodec {
    /// Four little-endian bytes for the length header.
    public static let headerSize = 4

    /// 1 MiB. Matches `wire.MAX_MESSAGE_SIZE`. Anything larger is
    /// treated as protocol corruption — we do not extend on demand.
    public static let maxMessageSize = 1_048_576

    /// Encode a payload into a framed blob.
    ///
    /// - Parameter payload: Serialized protobuf bytes.
    /// - Returns: `header ++ payload`.
    /// - Throws: `FrameCodecError.payloadTooLarge` when `payload.count`
    ///   exceeds `maxMessageSize`.
    public static func encode(_ payload: Data) throws(FrameCodecError) -> Data {
        let length = payload.count
        guard length <= maxMessageSize else {
            throw .payloadTooLarge(length: length, limit: maxMessageSize)
        }
        var framed = Data(capacity: headerSize + length)
        var lengthLE = UInt32(length).littleEndian
        withUnsafeBytes(of: &lengthLE) { framed.append(contentsOf: $0) }
        framed.append(payload)
        return framed
    }
}

public enum FrameCodecError: Error, Equatable, Sendable {
    /// Outbound payload exceeded `FrameCodec.maxMessageSize`.
    case payloadTooLarge(length: Int, limit: Int)

    /// A frame on the wire declared a length exceeding
    /// `FrameCodec.maxMessageSize`. The decoder drains the offending
    /// frame's bytes before surfacing this so the caller can either
    /// recover (it won't — the framing invariant is broken) or tear
    /// the connection down cleanly without re-parsing the same bytes.
    case frameTooLarge(length: Int, limit: Int)
}

/// Stateful decoder that reassembles TCP reads into complete frames.
///
/// A single `recv()` can deliver a partial header, a complete header
/// plus partial payload, a complete frame, or several back-to-back
/// frames. `feed` accepts any byte slice; `nextFrame` returns one
/// complete payload per call, or `nil` when the buffer does not yet
/// contain a full frame.
///
/// Design mirrors `wire.FrameReader` so that wire-behavior tests on
/// either side (Swift, Python) are directly comparable. The decoder
/// is NOT `Sendable` — it owns a mutable buffer and is expected to
/// live inside an actor.
public struct FrameReader {
    private var buffer: Data

    public init() {
        self.buffer = Data()
        self.buffer.reserveCapacity(FrameCodec.headerSize + 2048)
    }

    /// Append raw bytes to the reassembly buffer.
    public mutating func feed(_ data: Data) {
        buffer.append(data)
    }

    /// Try to extract one complete frame.
    ///
    /// - Returns: The payload, or `nil` when fewer than one complete
    ///   frame is buffered.
    /// - Throws: `FrameCodecError.frameTooLarge` when the declared
    ///   length exceeds the cap. The offending bytes are discarded
    ///   up to the declared length (capped at the buffered size) so
    ///   the caller does not re-hit the same error on retry — though
    ///   in practice the protocol is desynchronised and the caller
    ///   should tear the connection down.
    public mutating func nextFrame() throws(FrameCodecError) -> Data? {
        guard buffer.count >= FrameCodec.headerSize else {
            return nil
        }

        let declared = decodeLength(at: buffer.startIndex)
        let length = Int(declared)

        if length > FrameCodec.maxMessageSize {
            let drain = min(FrameCodec.headerSize + length, buffer.count)
            buffer.removeFirst(drain)
            throw .frameTooLarge(length: length, limit: FrameCodec.maxMessageSize)
        }

        let total = FrameCodec.headerSize + length
        guard buffer.count >= total else {
            return nil
        }

        let payload = buffer.subdata(in: (buffer.startIndex + FrameCodec.headerSize) ..< (buffer.startIndex + total))
        buffer.removeFirst(total)
        return payload
    }

    /// Total bytes currently buffered (header + partial payload). Used
    /// by tests and diagnostics; not part of the decode contract.
    public var bufferedByteCount: Int { buffer.count }

    private func decodeLength(at offset: Data.Index) -> UInt32 {
        let b0 = UInt32(buffer[offset])
        let b1 = UInt32(buffer[offset + 1])
        let b2 = UInt32(buffer[offset + 2])
        let b3 = UInt32(buffer[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}
