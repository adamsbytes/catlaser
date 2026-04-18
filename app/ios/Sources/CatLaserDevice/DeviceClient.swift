import CatLaserProto
import Foundation
import SwiftProtobuf

/// Actor that owns one `DeviceTransport` and drives the app-to-device
/// request/response protocol.
///
/// Responsibilities:
///
/// 1. Assign a `request_id` to every outbound `AppRequest` that expects
///    a response, and register a continuation keyed on that ID.
/// 2. Dispatch every inbound `DeviceEvent` either to the waiting
///    continuation (if `request_id != 0`) or to the unsolicited-event
///    stream (if `request_id == 0`).
/// 3. Surface transport failures as `DeviceClientError` to every
///    pending continuation, finish the event stream, and transition to
///    the closed state.
///
/// Only one consumer of `events` is supported; the stream is
/// constructed at init and handed out by reference. Multiple
/// subscribers would need a broadcast wrapper, which the current
/// feature surface does not require.
///
/// Lifecycle: `connect()` → many `request(...)` / `send(_:)` /
/// `events` iterations → `disconnect()`. Calling `request` before
/// `connect` throws `.notConnected`; calling `connect` twice throws
/// `.alreadyConnected`. `disconnect` is idempotent.
public actor DeviceClient {
    public typealias ClientClock = @Sendable () -> Date

    /// Default per-request timeout. The wire protocol is request/response
    /// over a healthy Tailscale link; real responses are sub-second.
    /// 10 seconds gives room for transient RTT spikes without stalling
    /// the UI indefinitely when the server drops a request on the floor.
    public static let defaultRequestTimeout: TimeInterval = 10

    private let transport: any DeviceTransport
    private let idFactory: AppRequestIDFactory
    private let requestTimeout: TimeInterval
    private let clock: ClientClock

    private enum State {
        case idle
        case connecting
        case connected
        case closed
    }

    private var state: State = .idle
    private var reader = FrameReader()
    private var pending: [UInt32: CheckedContinuation<Catlaser_App_V1_DeviceEvent, any Error>] = [:]
    private var receiveTask: Task<Void, Never>?
    private var timeoutTasks: [UInt32: Task<Void, Never>] = [:]

    // Unsolicited event plumbing. Single consumer.
    private let eventStream: AsyncStream<Catlaser_App_V1_DeviceEvent>
    private let eventContinuation: AsyncStream<Catlaser_App_V1_DeviceEvent>.Continuation

    public init(
        transport: any DeviceTransport,
        idFactory: AppRequestIDFactory = AppRequestIDFactory(),
        requestTimeout: TimeInterval = DeviceClient.defaultRequestTimeout,
        clock: @escaping ClientClock = { Date() },
    ) {
        self.transport = transport
        self.idFactory = idFactory
        self.requestTimeout = requestTimeout
        self.clock = clock

        var captured: AsyncStream<Catlaser_App_V1_DeviceEvent>.Continuation!
        self.eventStream = AsyncStream(bufferingPolicy: .unbounded) { continuation in
            captured = continuation
        }
        self.eventContinuation = captured
    }

    /// Unsolicited device events — heartbeats, session summaries,
    /// new-cat notifications, hopper-empty alerts. Terminates when
    /// the connection closes or an unrecoverable transport error
    /// occurs; by then every call to `request` will also be failing
    /// so the caller can treat the end-of-stream as a connection
    /// teardown signal.
    public nonisolated var events: AsyncStream<Catlaser_App_V1_DeviceEvent> {
        eventStream
    }

    /// Open the underlying transport and start the receive loop.
    public func connect() async throws {
        switch state {
        case .connecting, .connected:
            throw DeviceClientError.alreadyConnected
        case .closed:
            // Closed clients are terminal; callers must build a new
            // client rather than reuse one across session lifetimes.
            throw DeviceClientError.notConnected
        case .idle:
            break
        }
        state = .connecting
        do {
            try await transport.open()
        } catch let error as DeviceClientError {
            state = .closed
            throw error
        } catch {
            state = .closed
            throw DeviceClientError.connectFailed(error.localizedDescription)
        }
        state = .connected
        let stream = await transport.receiveStream
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop(stream)
        }
    }

    /// Tear the transport down and fail all outstanding requests.
    public func disconnect() async {
        guard state != .closed else { return }
        state = .closed
        receiveTask?.cancel()
        receiveTask = nil
        await transport.close()
        await failAllPending(.cancelled)
        eventContinuation.finish()
    }

    /// Current connection state — inspected by tests and diagnostics.
    public var isConnected: Bool { state == .connected }

    /// Send a request that expects exactly one response. The response
    /// is returned as a raw `DeviceEvent` so the caller can inspect the
    /// full oneof surface (`stream_offer`, `status_update`, `error`,
    /// etc.) itself; `DeviceError` payloads are surfaced as the typed
    /// `DeviceClientError.remote` rather than wrapped in an event.
    ///
    /// - Parameter request: populated `AppRequest` oneof. `request_id`
    ///   is overwritten by this call — callers cannot pre-assign.
    public func request(
        _ request: Catlaser_App_V1_AppRequest,
    ) async throws -> Catlaser_App_V1_DeviceEvent {
        guard state == .connected else {
            throw DeviceClientError.notConnected
        }
        var outbound = request
        let id = await idFactory.next()
        outbound.requestID = id

        let payload: Data
        do {
            payload = try outbound.serializedData()
        } catch {
            throw DeviceClientError.encodingFailed(error.localizedDescription)
        }

        let frame: Data
        do {
            frame = try FrameCodec.encode(payload)
        } catch {
            throw DeviceClientError.fromCodec(error)
        }

        let event: Catlaser_App_V1_DeviceEvent = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            scheduleTimeout(for: id)
            Task { [transport] in
                do {
                    try await transport.send(frame)
                } catch let error as DeviceClientError {
                    await self.failRequest(id: id, with: error)
                } catch {
                    await self.failRequest(
                        id: id,
                        with: .transport(error.localizedDescription),
                    )
                }
            }
        }

        if case let .error(remote) = event.event {
            throw DeviceClientError.remote(code: remote.code, message: remote.message)
        }
        return event
    }

    /// Fire-and-forget send: no response is awaited. Sets `request_id`
    /// to `0` per the proto contract so the device does not attempt to
    /// correlate its reply (and any spontaneous event echoing this
    /// request will flow down the `events` stream).
    public func send(_ request: Catlaser_App_V1_AppRequest) async throws {
        guard state == .connected else {
            throw DeviceClientError.notConnected
        }
        var outbound = request
        outbound.requestID = 0

        let payload: Data
        do {
            payload = try outbound.serializedData()
        } catch {
            throw DeviceClientError.encodingFailed(error.localizedDescription)
        }

        let frame: Data
        do {
            frame = try FrameCodec.encode(payload)
        } catch {
            throw DeviceClientError.fromCodec(error)
        }

        do {
            try await transport.send(frame)
        } catch let error as DeviceClientError {
            throw error
        } catch {
            throw DeviceClientError.transport(error.localizedDescription)
        }
    }

    // MARK: - Receive loop

    private func runReceiveLoop(_ stream: AsyncThrowingStream<Data, any Error>) async {
        do {
            for try await chunk in stream {
                reader.feed(chunk)
                while true {
                    let maybePayload: Data?
                    do {
                        maybePayload = try reader.nextFrame()
                    } catch {
                        await closeWithError(.fromCodec(error))
                        return
                    }
                    guard let payload = maybePayload else { break }
                    await handleFrame(payload)
                }
            }
            await closeWithError(.closedByPeer)
        } catch let error as DeviceClientError {
            await closeWithError(error)
        } catch {
            await closeWithError(.transport(error.localizedDescription))
        }
    }

    private func handleFrame(_ payload: Data) async {
        let event: Catlaser_App_V1_DeviceEvent
        do {
            event = try Catlaser_App_V1_DeviceEvent(serializedBytes: payload)
        } catch {
            await closeWithError(.malformedFrame(error.localizedDescription))
            return
        }
        let id = event.requestID
        if id == 0 {
            eventContinuation.yield(event)
            return
        }
        guard let continuation = pending.removeValue(forKey: id) else {
            // Orphan response — unknown ID. Surface on the event
            // stream so diagnostics don't swallow it, but do not
            // tear the connection down. This can happen if a request
            // timed out locally and the device's reply arrived
            // afterwards.
            eventContinuation.yield(event)
            return
        }
        cancelTimeout(for: id)
        continuation.resume(returning: event)
    }

    private func closeWithError(_ error: DeviceClientError) async {
        if state == .closed { return }
        state = .closed
        await failAllPending(error)
        eventContinuation.finish()
        await transport.close()
    }

    // MARK: - Pending management

    private func failRequest(id: UInt32, with error: DeviceClientError) async {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        cancelTimeout(for: id)
        continuation.resume(throwing: error)
    }

    private func failAllPending(_ error: DeviceClientError) async {
        let snapshot = pending
        pending.removeAll(keepingCapacity: false)
        for task in timeoutTasks.values {
            task.cancel()
        }
        timeoutTasks.removeAll(keepingCapacity: false)
        for (_, continuation) in snapshot {
            continuation.resume(throwing: error)
        }
    }

    private func scheduleTimeout(for id: UInt32) {
        guard requestTimeout > 0 else { return }
        let nanos = UInt64(requestTimeout * 1_000_000_000)
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await self?.failRequest(id: id, with: .requestTimedOut)
        }
        timeoutTasks[id] = task
    }

    private func cancelTimeout(for id: UInt32) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
    }
}

// MARK: - Error bridging

extension DeviceClientError {
    static func fromCodec(_ error: FrameCodecError) -> DeviceClientError {
        switch error {
        case let .payloadTooLarge(length, limit):
            .frameTooLarge(length: length, limit: limit)
        case let .frameTooLarge(length, limit):
            .frameTooLarge(length: length, limit: limit)
        }
    }
}
