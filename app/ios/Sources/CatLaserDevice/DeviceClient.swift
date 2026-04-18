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
/// 4. Perform a mandatory `AuthRequest` handshake as the first frame
///    after transport open, using a caller-supplied attestation block.
///    The device rejects every subsequent frame until the handshake
///    completes successfully, so `connect()` does not return until the
///    `AuthResponse` has been received and accepted. A `nil` block is
///    accepted only for legacy tests that exercise the transport
///    machinery in isolation.
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

    /// Builder for the attestation header to place on the first
    /// TCP frame. Returns the same base64-of-JSON payload the app
    /// sends to the coordination server on the `api:` binding, but
    /// with a `dev:<ts>` binding that targets the device daemon.
    ///
    /// Lifetime of the returned string matches the returned value —
    /// the handshake consumes it once. The closure is called inside
    /// the actor's isolation domain, so it must be `@Sendable` and
    /// must not capture non-Sendable state.
    public typealias AttestationBuilder = @Sendable () async throws -> String

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

    /// Open the underlying transport, start the receive loop, and
    /// complete the mandatory device-auth handshake.
    ///
    /// - Parameter handshake: closure that returns the `x-device-
    ///   attestation` header payload (base64 v4 JSON) signed with
    ///   the app's Secure-Enclave key under the `dev:<ts>` binding.
    ///   Passing `nil` skips the handshake and is intended only for
    ///   tests that exercise the transport/correlation code directly
    ///   (e.g. via `InMemoryDeviceTransport`). Production callers
    ///   MUST provide a handshake block; the server disconnects any
    ///   client that sends a non-auth frame first, so skipping the
    ///   handshake against a real device is a guaranteed failure.
    public func connect(handshake: AttestationBuilder? = nil) async throws {
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
        guard let handshake else { return }
        do {
            try await performHandshake(handshake)
        } catch {
            // The handshake owns the teardown path — a failed call
            // tears the transport down and throws — but callers
            // expect `connect()` to have either `.connected` or
            // `.closed` state on return, never a dangling
            // half-open. `performHandshake` already closes on
            // failure, so we just surface the error.
            throw error
        }
    }

    private func performHandshake(_ handshake: AttestationBuilder) async throws {
        let header: String
        do {
            header = try await handshake()
        } catch let error as DeviceClientError {
            await shutdownForHandshakeFailure()
            throw error
        } catch {
            await shutdownForHandshakeFailure()
            throw DeviceClientError.handshakeFailed(
                reason: "attestation build failed: \(error.localizedDescription)",
            )
        }
        var authRequest = Catlaser_App_V1_AppRequest()
        authRequest.auth.attestationHeader = header
        let event: Catlaser_App_V1_DeviceEvent
        do {
            event = try await request(authRequest)
        } catch let error as DeviceClientError {
            await shutdownForHandshakeFailure()
            // A remote error during handshake means the device
            // refused the AuthRequest itself (the server sends a
            // typed `error` event only for dispatcher issues; a
            // refused handshake writes an AuthResponse with
            // ok=false, which lands in the success branch below).
            // Surfacing whatever the client got here lets the
            // caller distinguish a transport drop from a crypto
            // rejection.
            throw error
        } catch {
            await shutdownForHandshakeFailure()
            throw DeviceClientError.handshakeFailed(
                reason: "handshake transport error: \(error.localizedDescription)",
            )
        }
        guard case let .authResponse(response) = event.event else {
            await shutdownForHandshakeFailure()
            throw DeviceClientError.handshakeFailed(
                reason: "handshake reply was not AuthResponse (got \(String(describing: event.event)))",
            )
        }
        if !response.ok {
            await shutdownForHandshakeFailure()
            throw DeviceClientError.handshakeFailed(reason: response.reason)
        }
    }

    /// Tear the transport down after a handshake failure. Identical
    /// to `disconnect()` except it does not produce a
    /// `.notConnected` error on a subsequent call — the caller is
    /// already in the middle of surfacing a specific handshake
    /// error and shouldn't get a second message about it.
    private func shutdownForHandshakeFailure() async {
        guard state != .closed else { return }
        state = .closed
        receiveTask?.cancel()
        receiveTask = nil
        await transport.close()
        await failAllPending(.cancelled)
        eventContinuation.finish()
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
