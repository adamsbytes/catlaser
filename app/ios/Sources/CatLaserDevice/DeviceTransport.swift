import Foundation

/// Abstracts the bidirectional byte stream between the app and the
/// device's TCP server.
///
/// `DeviceClient` drives a transport through three phases:
///
/// 1. `open()` — establish the underlying connection. On failure,
///    throws; the client surfaces the failure as `connectFailed`.
/// 2. `send(_:)` — enqueue a complete outbound frame. The transport
///    is responsible for writing the full `Data` atomically enough
///    that frames do not interleave on the wire; short writes are
///    the transport's problem.
/// 3. `receiveStream` — an `AsyncThrowingStream` that yields inbound
///    byte slices as they arrive from the peer. The stream ends
///    (finishes without error) when the peer closes cleanly, and
///    ends with a thrown `DeviceClientError` on transport failure.
///
/// `close()` is idempotent and always safe — the client calls it
/// exactly once from its teardown path, and tests call it from
/// fixture cleanup regardless of whether `open()` succeeded.
///
/// The transport is an actor-facing abstraction, so implementations
/// must be `Sendable`. The production `NetworkDeviceTransport` on
/// Apple platforms wraps `NWConnection` and forwards its event
/// callbacks into the receive stream.
public protocol DeviceTransport: Sendable {
    /// Open the connection. Idempotency is implementation-defined;
    /// `DeviceClient` only ever calls this once per instance.
    func open() async throws

    /// Write `data` to the peer. The implementation must flush
    /// before returning — the client relies on one `send` call
    /// delivering one complete frame.
    func send(_ data: Data) async throws

    /// Inbound bytes. Exactly one consumer. The stream terminates
    /// without error on clean close and with `DeviceClientError` on
    /// transport failure.
    var receiveStream: AsyncThrowingStream<Data, any Error> { get async }

    /// Tear the connection down. Idempotent. Must cause
    /// `receiveStream` to finish (with or without error) so the
    /// client's receive loop unblocks.
    func close() async
}
