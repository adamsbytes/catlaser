import CatLaserDevice
import CatLaserProto
import Foundation
import SwiftProtobuf

/// Bidirectional in-memory `DeviceTransport` for tests.
///
/// The transport wires the app-side `DeviceClient` to an optional
/// `ScriptedDeviceServer` (or to direct test injections) without
/// going anywhere near a real socket. All behavior exercised by
/// tests — framing, correlation, timeout, half-close, malformed
/// payloads — is reproducible on Linux CI this way.
///
/// The transport enforces a few behaviours that real `NWConnection`
/// gives for free but would otherwise drift between target and test:
///
/// * Multiple consumers of `receiveStream` are refused. The
///   `DeviceClient` assumes sole ownership.
/// * `send` before `open` throws `DeviceClientError.notConnected`,
///   matching the NWConnection transport.
/// * `close` is idempotent.
public final class InMemoryDeviceTransport: DeviceTransport, @unchecked Sendable {
    private let state = State()

    // Inbound bytes (server -> client). Yielded into by test code
    // (directly or via `ScriptedDeviceServer`). Consumed by `DeviceClient`
    // via `receiveStream`.
    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    // Outbound bytes (client -> server). Each `send(_:)` call appends
    // one complete frame; tests drain via `nextSentFrame()` / `pullAllSentFrames()`.
    private let outgoing = OutgoingBuffer()

    public init() {
        var captured: AsyncThrowingStream<Data, any Error>.Continuation!
        self.stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            captured = continuation
        }
        self.continuation = captured
    }

    /// Finish the inbound stream on deallocation. Swift 6.3 on Linux
    /// does not auto-finish a leftover ``AsyncThrowingStream`` when
    /// the producer-side continuation goes out of scope, so a
    /// ``DeviceClient`` ``for await`` loop keeps a Task parked in the
    /// cooperative thread pool; across the parallel test suite the
    /// pool saturates and deadlocks. Calling ``finish`` here
    /// terminates every consumer cleanly once the last reference to
    /// the transport is released.
    deinit {
        continuation.finish()
    }

    public func open() async throws {
        try await state.open()
    }

    public func send(_ data: Data) async throws {
        try await state.requireOpen()
        await outgoing.append(data)
    }

    public var receiveStream: AsyncThrowingStream<Data, any Error> {
        get async { stream }
    }

    public func close() async {
        await state.close()
        continuation.finish()
        await outgoing.finish()
    }

    // MARK: - Test injection

    /// Yield arbitrary bytes onto the inbound path as if the peer sent
    /// them. Tests can split a single frame across many calls to
    /// exercise the reassembly logic.
    public func deliver(_ data: Data) {
        continuation.yield(data)
    }

    /// Deliver a complete `DeviceEvent` to the client, framed per wire
    /// protocol. `requestID` on the event is preserved; tests that
    /// need to match a specific outbound request should first pull
    /// the request with `nextAppRequest()` to read its ID.
    public func deliver(event: Catlaser_App_V1_DeviceEvent) throws {
        let payload = try event.serializedData()
        let frame = try FrameCodec.encode(payload)
        continuation.yield(frame)
    }

    /// Simulate a clean server-side half-close.
    public func finishPeer() {
        continuation.finish()
    }

    /// Simulate a transport error on the inbound path.
    public func finishPeer(throwing error: any Error) {
        continuation.finish(throwing: error)
    }

    /// Drain the next complete outbound frame (blocking up to `timeout`).
    /// The returned `Data` is the payload only — the 4-byte length
    /// header has been stripped.
    public func nextSentPayload(timeout: TimeInterval = 1.0) async throws -> Data {
        try await outgoing.nextPayload(timeout: timeout)
    }

    /// Drain and decode the next outbound frame as an `AppRequest`.
    public func nextAppRequest(timeout: TimeInterval = 1.0) async throws -> Catlaser_App_V1_AppRequest {
        let payload = try await nextSentPayload(timeout: timeout)
        return try Catlaser_App_V1_AppRequest(serializedBytes: payload)
    }

    /// All outbound frames currently buffered, as raw `Data` blobs
    /// (headers stripped). Does not wait.
    public var sentPayloads: [Data] {
        get async { await outgoing.snapshot() }
    }
}

/// Internal state actor. Drop-in replacement for the NWConnection
/// state machine exposed by the production transport.
private actor State {
    private enum Phase { case idle, open, closed }
    private var phase: Phase = .idle

    func open() throws(DeviceClientError) {
        switch phase {
        case .idle:
            phase = .open
        case .open:
            throw .alreadyConnected
        case .closed:
            throw .notConnected
        }
    }

    func requireOpen() throws(DeviceClientError) {
        switch phase {
        case .open:
            return
        case .idle, .closed:
            throw .notConnected
        }
    }

    func close() {
        phase = .closed
    }
}

/// Outbound frame buffer with async consumption semantics.
private actor OutgoingBuffer {
    private var frames: [Data] = []
    private var waiters: [UUID: CheckedContinuation<Data, any Error>] = [:]
    private var finished = false

    func append(_ framed: Data) {
        if let payload = stripHeader(framed), let waiterID = waiters.keys.first {
            let continuation = waiters.removeValue(forKey: waiterID)
            continuation?.resume(returning: payload)
            return
        }
        frames.append(framed)
    }

    func nextPayload(timeout: TimeInterval) async throws -> Data {
        if let framed = frames.first, let payload = stripHeader(framed) {
            frames.removeFirst()
            return payload
        }
        if finished {
            throw DeviceClientError.closedByPeer
        }

        let nanos = UInt64(timeout * 1_000_000_000)
        let waiterID = UUID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            waiters[waiterID] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: nanos)
                await self?.timeout(id: waiterID)
            }
        }
    }

    func snapshot() -> [Data] {
        frames.compactMap(stripHeader)
    }

    func finish() {
        finished = true
        let snapshot = waiters
        waiters.removeAll()
        for continuation in snapshot.values {
            continuation.resume(throwing: DeviceClientError.closedByPeer)
        }
    }

    private func timeout(id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: DeviceClientError.requestTimedOut)
    }

    private func stripHeader(_ framed: Data) -> Data? {
        guard framed.count >= FrameCodec.headerSize else { return nil }
        let b0 = UInt32(framed[framed.startIndex])
        let b1 = UInt32(framed[framed.startIndex + 1])
        let b2 = UInt32(framed[framed.startIndex + 2])
        let b3 = UInt32(framed[framed.startIndex + 3])
        let declared = b0 | b1 << 8 | b2 << 16 | b3 << 24
        guard framed.count >= FrameCodec.headerSize + Int(declared) else { return nil }
        return framed.subdata(in: (framed.startIndex + FrameCodec.headerSize) ..< (framed.startIndex + FrameCodec.headerSize + Int(declared)))
    }
}
