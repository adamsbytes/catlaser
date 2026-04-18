import Foundation

/// Monotonically-increasing `request_id` generator for `AppRequest`.
///
/// The proto contract (`proto/catlaser/app/v1/app.proto`):
///
/// > Caller-assigned ID echoed in the corresponding `DeviceEvent`.
/// > Allows the app to correlate responses when multiple requests are
/// > in flight. Zero for fire-and-forget commands.
///
/// This actor serves IDs in `1 ... UInt32.max`, wrapping back to `1`
/// after `UInt32.max` so `0` is never handed out. `0` is reserved for
/// unsolicited device pushes (heartbeats, session summaries, etc.) and
/// fire-and-forget app commands whose responses the caller does not
/// want to await.
///
/// Wrap behaviour: 32 bits at one authenticated app session gives ~4 B
/// IDs before overflow — never reached in practice, but the wrap is
/// defined so a long-lived client does not suddenly start emitting `0`
/// and collide with the unsolicited-event channel.
public actor AppRequestIDFactory {
    private var counter: UInt32 = 0

    public init() {}

    public func next() -> UInt32 {
        if counter == UInt32.max {
            counter = 1
        } else {
            counter &+= 1
        }
        return counter
    }

    /// Test-only hook: rewind the counter so wrap-around behaviour
    /// can be exercised without issuing ~4 B `next()` calls. Marked
    /// internal (no `public`) so only tests in this package with
    /// `@testable import` can reach it.
    func _setCounterForTest(_ value: UInt32) {
        counter = value
    }
}
