import Foundation

/// Failure modes for `DeviceClient`.
///
/// All surfaced errors fall into one of these cases. Each exists
/// because a caller needs to tell it apart from the others — the
/// recovery actions differ:
///
/// * `.notConnected` — caller should open the connection first.
/// * `.connectFailed` / `.transport` — network-layer problem; retry
///   with backoff once the app regains network.
/// * `.closedByPeer` — server dropped the connection cleanly; reopen
///   and continue.
/// * `.malformedFrame` / `.frameTooLarge` / `.encodingFailed` — wire
///   invariant broken; the connection is already torn down, tear down
///   any higher-level state too.
/// * `.requestTimedOut` — the response never arrived; the device may
///   still have executed the side-effect; caller decides whether to
///   retry (idempotency at this level is per-route).
/// * `.remote` — the device responded with a `DeviceError` payload;
///   caller inspects `code`/`message` to decide what to show.
/// * `.wrongEventKind` — response arrived but its oneof branch didn't
///   match what the caller asked for; a protocol bug on either side.
public enum DeviceClientError: Error, Equatable, Sendable {
    case notConnected
    case alreadyConnected
    case connectFailed(String)
    case transport(String)
    case closedByPeer
    case malformedFrame(String)
    case frameTooLarge(length: Int, limit: Int)
    case encodingFailed(String)
    case requestTimedOut
    case cancelled
    case remote(code: UInt32, message: String)
    case wrongEventKind(expected: String, got: String)
}
