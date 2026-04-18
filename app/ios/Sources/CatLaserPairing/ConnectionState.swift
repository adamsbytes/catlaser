import CatLaserDevice
import Foundation

/// Observable state of the `ConnectionManager`.
///
/// Six cases, each mapping to a distinct UI treatment:
///
/// * `.idle` — supervisor has not been started, or `stop()` was
///   called. No device client exists.
/// * `.waitingForNetwork` — the `NetworkPathMonitor` reports no
///   satisfied path. The supervisor has paused reconnect attempts.
/// * `.connecting(attempt:)` — the supervisor is currently opening a
///   `DeviceClient`. `attempt` is 1 on the first try and increments on
///   each backoff-gated retry; used by the UI for "attempt 3/..." copy.
/// * `.connected(DeviceClient)` — an open, connected client is ready
///   for use. The value is the live client the consumer should dispatch
///   against. Callers must not cache this reference across state
///   transitions — a subsequent `.connecting` or `.failed` invalidates
///   the client.
/// * `.backingOff(until:attempt:)` — last connect failed; the next
///   attempt will fire at `until`. UI renders a countdown or a
///   "Retrying" spinner.
/// * `.failed(PairingError)` — terminal failure that backoff cannot
///   fix (bad endpoint, unrecoverable transport). The UI prompts the
///   user for manual action.
public enum ConnectionState: Sendable, Equatable {
    case idle
    case waitingForNetwork
    case connecting(attempt: Int)
    case connected(DeviceClient)
    case backingOff(until: Date, attempt: Int)
    case failed(PairingError)

    public static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.waitingForNetwork, .waitingForNetwork):
            true
        case let (.connecting(a), .connecting(b)):
            a == b
        case let (.connected(a), .connected(b)):
            a === b
        case let (.backingOff(aDate, aAttempt), .backingOff(bDate, bAttempt)):
            aDate == bDate && aAttempt == bAttempt
        case let (.failed(a), .failed(b)):
            a == b
        default:
            false
        }
    }

    /// True iff this state has a live `DeviceClient` that callers can
    /// dispatch against right now. Equivalent to `.connected`.
    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// Currently-active client, or nil. Extracted once here so callers
    /// do not re-pattern-match across multiple codepaths.
    public var client: DeviceClient? {
        if case let .connected(client) = self { return client }
        return nil
    }
}
