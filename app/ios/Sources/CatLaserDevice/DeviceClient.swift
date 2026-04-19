#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
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

    /// Generator for the 16-byte nonce included in every
    /// ``AuthRequest``. Defaults to cryptographic-random bytes; the
    /// test-only override in ``DeviceClient.init(..., nonceFactory:)``
    /// lets tests feed deterministic values so transcripts are
    /// predictable.
    public typealias NonceFactory = @Sendable () -> Data

    /// Default per-request timeout. The wire protocol is request/response
    /// over a healthy Tailscale link; real responses are sub-second.
    /// 10 seconds gives room for transient RTT spikes without stalling
    /// the UI indefinitely when the server drops a request on the floor.
    public static let defaultRequestTimeout: TimeInterval = 10

    /// Byte length of the handshake nonce. Must match the device's
    /// :data:`catlaser_brain.auth.handshake_response.NONCE_LENGTH`.
    public static let handshakeNonceLength = 16

    private let transport: any DeviceTransport
    private let idFactory: AppRequestIDFactory
    private let requestTimeout: TimeInterval
    private let clock: ClientClock
    private let nonceFactory: NonceFactory
    private let responseVerifier: HandshakeResponseVerifier?

    private enum State {
        case idle
        /// Transport open in progress. No frames may be sent or received
        /// application-side yet.
        case connecting
        /// Transport is open and the receive loop is running. Only the
        /// internal handshake path (``performRequestInternal``) may emit
        /// a frame in this state — the public ``request`` / ``send``
        /// surface refuses to. Prevents actor-reentrancy from letting a
        /// second caller smuggle a non-``AuthRequest`` frame ahead of
        /// the mandatory first-frame handshake: the receive-loop
        /// continuation handshake is in flight awaits another actor-
        /// isolated step, during which the actor may accept other
        /// messages, so gating on a state distinct from ``connected``
        /// is the only way to keep a public ``request`` from reaching
        /// the wire before ``AuthResponse`` arrives.
        case handshaking
        case connected
        case closed
    }

    private var state: State = .idle
    private var reader = FrameReader()
    private var pending: [UInt32: CheckedContinuation<Catlaser_App_V1_DeviceEvent, any Error>] = [:]
    private var receiveTask: Task<Void, Never>?
    private var timeoutTasks: [UInt32: Task<Void, Never>] = [:]
    /// Continuations parked on ``waitForClose``. Resumed (all at once)
    /// by every close path — ``disconnect``, ``closeWithError``, and
    /// the handshake-failure teardown. Exists so the
    /// ``ConnectionManager`` can await connection-close without
    /// subscribing to ``events`` (which is a single-consumer surface
    /// reserved for the ``DeviceEventBroker`` fanout).
    private var closeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    // Unsolicited event plumbing. Single consumer.
    private let eventStream: AsyncStream<Catlaser_App_V1_DeviceEvent>
    private let eventContinuation: AsyncStream<Catlaser_App_V1_DeviceEvent>.Continuation

    public init(
        transport: any DeviceTransport,
        idFactory: AppRequestIDFactory = AppRequestIDFactory(),
        requestTimeout: TimeInterval = DeviceClient.defaultRequestTimeout,
        clock: @escaping ClientClock = { Date() },
        responseVerifier: HandshakeResponseVerifier? = nil,
        nonceFactory: @escaping NonceFactory = DeviceClient.defaultNonceFactory,
    ) {
        self.transport = transport
        self.idFactory = idFactory
        self.requestTimeout = requestTimeout
        self.clock = clock
        self.responseVerifier = responseVerifier
        self.nonceFactory = nonceFactory

        var captured: AsyncStream<Catlaser_App_V1_DeviceEvent>.Continuation!
        self.eventStream = AsyncStream(bufferingPolicy: .unbounded) { continuation in
            captured = continuation
        }
        self.eventContinuation = captured
    }

    /// Finish the event stream on deallocation. Same rationale as
    /// ``ConnectionManager/deinit`` and ``PushTokenRegistrar/deinit``:
    /// without an explicit ``finish()`` call the stream stays open
    /// after the client is released, the consumer's ``for await``
    /// loop keeps parking a Task in the cooperative thread pool, and
    /// across the full parallel test suite the pool saturates and
    /// deadlocks.
    deinit {
        eventContinuation.finish()
    }

    /// Production nonce source — 16 bytes from
    /// ``SystemRandomNumberGenerator``. Exposed as a static member
    /// so tests that want the production generator alongside an
    /// override (e.g. a test that stubs one nonce then lets the
    /// rest flow normally) can reference it directly.
    public static let defaultNonceFactory: NonceFactory = {
        var bytes = [UInt8](repeating: 0, count: DeviceClient.handshakeNonceLength)
        for i in 0 ..< bytes.count {
            bytes[i] = UInt8.random(in: 0 ... .max)
        }
        return Data(bytes)
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
        case .connecting, .handshaking, .connected:
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
        let stream = await transport.receiveStream
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop(stream)
        }
        // When no handshake is wired (legacy test-only path using the
        // in-memory transport), flip straight to ``.connected`` — the
        // tests that use this path don't exercise the handshake gate
        // and would otherwise stall forever waiting for an
        // ``AuthResponse`` nobody is going to send. Production callers
        // MUST always pass a handshake block; the composition-root
        // invariants assert this.
        guard let handshake else {
            state = .connected
            return
        }
        // Production-shape handshake: refuse to proceed without a
        // signature verifier. A nil verifier here would cause
        // `performHandshake` to skip Ed25519 verification and trust
        // the remote `ok` flag verbatim — exactly the failure mode an
        // impostor at the Tailscale endpoint exploits. Failing closed
        // before any wire traffic ensures a misconfigured composition
        // is detected on the first connect attempt rather than after
        // a successful "handshake" with an attacker.
        guard responseVerifier != nil else {
            state = .closed
            receiveTask?.cancel()
            receiveTask = nil
            await transport.close()
            await failAllPending(.cancelled)
            eventContinuation.finish()
            throw DeviceClientError.handshakeVerifierMissing
        }
        // Enter the handshake-only state. ``request`` / ``send`` from
        // the public API refuse to transmit in this state — the only
        // path to the wire is the internal handshake request below.
        state = .handshaking
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
        state = .connected
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
        // Generate a fresh 16-byte nonce for this handshake. Held
        // locally so ``verifyResponse`` (below) can pass the exact
        // bytes to ``HandshakeResponseVerifier.verify`` — the device
        // echoes them in its reply, and a mismatch aborts the
        // session before any application frame reaches the wire.
        let nonce = nonceFactory()
        precondition(
            nonce.count == DeviceClient.handshakeNonceLength,
            "nonceFactory must return exactly \(DeviceClient.handshakeNonceLength) bytes",
        )
        var authRequest = Catlaser_App_V1_AppRequest()
        authRequest.auth.attestationHeader = header
        authRequest.auth.nonce = nonce
        let event: Catlaser_App_V1_DeviceEvent
        do {
            // Use the internal send path rather than the public
            // ``request``: the public path gates on ``state ==
            // .connected``, and we are deliberately in ``.handshaking``
            // so that no concurrent actor-reentrant call can smuggle
            // a non-``AuthRequest`` frame out before the handshake
            // completes.
            event = try await performRequestInternal(authRequest, allowedInHandshake: true)
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

        // VERIFY the device-side signature BEFORE trusting `ok`. A
        // forged AuthResponse with `ok=true` from an impostor at the
        // Tailscale endpoint cannot produce a signature that
        // validates against the paired device's public key. The
        // verifier is guaranteed non-nil here by the
        // ``handshakeVerifierMissing`` gate at the top of `connect`;
        // we re-check defensively so a future refactor that bypasses
        // the gate (or introduces a third internal entry point into
        // the handshake) crashes loudly with a typed error rather
        // than silently skipping verification. Verifying on the
        // reject path too guards against an impostor that forged
        // `ok=false` to trick the client into tearing down a
        // legitimate session; only a signed `ok=false` from the real
        // device is honoured as terminal.
        guard let verifier = responseVerifier else {
            await shutdownForHandshakeFailure()
            throw DeviceClientError.handshakeVerifierMissing
        }
        do {
            try verifier.verify(
                response: response,
                expectedNonce: nonce,
                now: clock(),
            )
        } catch {
            // ``HandshakeResponseVerifier.verify`` is `throws(DeviceClientError)`,
            // so the bare catch already binds a typed
            // ``DeviceClientError``. Tear the transport down and
            // re-throw with no remapping — the verifier's typed
            // cases (`handshakeNonceMismatch`,
            // `handshakeSkewExceeded`, `handshakeSignatureInvalid`)
            // carry the right diagnostic for the caller.
            await shutdownForHandshakeFailure()
            throw error
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
        resumeCloseWaiters()
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
        resumeCloseWaiters()
    }

    /// Current connection state — inspected by tests and diagnostics.
    /// Returns ``true`` ONLY in the post-handshake ``.connected``
    /// state: consumers like ``LiveViewModel`` that gate behavior on
    /// "is the device talking" must see ``false`` while the mandatory
    /// auth handshake is still in flight, otherwise they could
    /// schedule a ``request`` that the public gate would then refuse.
    public var isConnected: Bool { state == .connected }

    /// True once the client has transitioned to ``.closed`` — either
    /// via ``disconnect``, a transport error, or a rejected handshake.
    /// Paired with ``waitForClose`` for consumers that want to observe
    /// the transition without subscribing to ``events``.
    public var isClosed: Bool { state == .closed }

    /// Await the transition into ``.closed``. Returns immediately if
    /// the client is already closed. Exposed so
    /// ``ConnectionManager`` can detect end-of-connection without
    /// subscribing to ``events``, which is reserved for a single
    /// consumer — ``DeviceEventBroker``. Multiple concurrent awaiters
    /// are supported; the close path resumes all of them.
    ///
    /// Cancellation-aware: if the caller's task is cancelled before
    /// the client closes, the parked waiter is resumed immediately
    /// (the call returns) and the map entry is cleared. Without this
    /// hook a cancelled caller would leak a continuation forever —
    /// ``withCheckedContinuation`` itself does not observe task
    /// cancellation.
    public func waitForClose() async {
        if state == .closed { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                registerCloseWaiter(id: id, continuation: continuation)
            }
        } onCancel: {
            // The closure runs outside the actor's isolation domain;
            // push the waiter-cleanup back to the actor via a Task
            // and let the actor resume the parked continuation. The
            // Task's ``[weak self]`` capture lives on the cooperative
            // pool, satisfying Swift 6's ``sending``-closure
            // isolation check.
            Task { [weak self] in
                await self?.cancelCloseWaiter(id: id)
            }
        }
    }

    /// Register a close waiter, or resume it immediately if the
    /// client has closed between the fast-path check in
    /// ``waitForClose`` and the continuation install. Prevents a race
    /// where ``resumeCloseWaiters`` runs before the map write, which
    /// would park the caller forever.
    private func registerCloseWaiter(
        id: UUID,
        continuation: CheckedContinuation<Void, Never>,
    ) {
        if state == .closed {
            continuation.resume()
            return
        }
        closeWaiters[id] = continuation
    }

    /// Cancellation hook — resume the parked waiter without waiting
    /// for the close transition. Idempotent: if ``resumeCloseWaiters``
    /// has already fired (the close landed first), the map entry is
    /// gone and this is a no-op.
    private func cancelCloseWaiter(id: UUID) {
        guard let continuation = closeWaiters.removeValue(forKey: id) else { return }
        continuation.resume()
    }

    /// Fire every parked ``waitForClose`` continuation. Called from
    /// the close paths (``disconnect``, ``closeWithError``,
    /// ``shutdownForHandshakeFailure``) after the state transition.
    private func resumeCloseWaiters() {
        let snapshot = closeWaiters
        closeWaiters.removeAll(keepingCapacity: false)
        for continuation in snapshot.values {
            continuation.resume()
        }
    }

    /// Send a request that expects exactly one response. The response
    /// is returned as a raw `DeviceEvent` so the caller can inspect the
    /// full oneof surface (`stream_offer`, `status_update`, `error`,
    /// etc.) itself; `DeviceError` payloads are surfaced as the typed
    /// `DeviceClientError.remote` rather than wrapped in an event.
    ///
    /// The public ``request`` surface refuses to transmit unless the
    /// client has reached the ``.connected`` state — an in-progress
    /// handshake (``.handshaking``) gates out non-auth frames so
    /// actor-reentrancy cannot smuggle an application frame onto the
    /// wire before the device daemon has accepted our first-frame
    /// ``AuthRequest``.
    ///
    /// - Parameter request: populated `AppRequest` oneof. `request_id`
    ///   is overwritten by this call — callers cannot pre-assign.
    public func request(
        _ request: Catlaser_App_V1_AppRequest,
    ) async throws -> Catlaser_App_V1_DeviceEvent {
        try await performRequestInternal(request, allowedInHandshake: false)
    }

    /// Fire-and-forget send: no response is awaited. Sets `request_id`
    /// to `0` per the proto contract so the device does not attempt to
    /// correlate its reply (and any spontaneous event echoing this
    /// request will flow down the `events` stream).
    ///
    /// Gates on ``state == .connected`` for the same reason as
    /// ``request(_:)``: a handshake in progress must not be able to
    /// interleave with a caller's ``send`` reaching the wire.
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

    /// Core request/response implementation shared by the public
    /// ``request`` surface and the handshake path.
    ///
    /// - Parameter allowedInHandshake: When ``true``, the method also
    ///   accepts ``state == .handshaking``. The ONLY caller that
    ///   passes ``true`` is ``performHandshake``. The flag is a
    ///   deliberate belt-and-braces on top of the file-private
    ///   visibility: a hypothetical future refactor that tried to
    ///   expose ``performRequestInternal`` publicly would still have
    ///   to explicitly opt into the handshake-stage gate, making the
    ///   contract visible at the call site.
    private func performRequestInternal(
        _ request: Catlaser_App_V1_AppRequest,
        allowedInHandshake: Bool,
    ) async throws -> Catlaser_App_V1_DeviceEvent {
        switch state {
        case .connected:
            break
        case .handshaking where allowedInHandshake:
            break
        default:
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
        // Intercept the device daemon's ACL-revocation sentinel
        // BEFORE the ordinary request-id routing — but ONLY after the
        // handshake has completed. Pre-handshake the connection is
        // not yet authenticated: any party that can write bytes to
        // the Tailscale endpoint (an impostor that wins the TCP-accept
        // race, a tunnel-internal attacker, a misconfigured second
        // utun) could otherwise send a forged `AUTH_REVOKED` frame
        // before the device has a chance to identify itself, and the
        // ``ConnectionManager`` -> ``PairingViewModel`` chain would
        // wipe the keychain pairing in response — a permanent
        // denial-of-pairing with no cryptographic gate. Honouring the
        // signal only after ``state == .connected`` means it has been
        // preceded by a successful Ed25519 verification of the
        // device's `AuthResponse` against the pairing-time public key,
        // so the source of the AUTH_REVOKED is at minimum someone who
        // also successfully completed the device-bound handshake (i.e.
        // the device, or an attacker who has compromised the WireGuard
        // tunnel — a substantially higher bar that is also defended by
        // the second-layer server-confirmation check in
        // ``PairingViewModel/unpairAfterRevocation``). Pre-handshake
        // AUTH_REVOKED frames flow through to the events stream as
        // unsolicited input; `ConnectionManager`'s events watcher does
        // not start until after handshake completes, so they are
        // discarded.
        if case let .error(remote) = event.event,
           remote.code == DeviceClientError.authRevokedCode,
           state == .connected
        {
            await closeWithError(.authRevoked(message: remote.message))
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
        resumeCloseWaiters()
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
