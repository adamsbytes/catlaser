import CatLaserProto
import Foundation

/// View-facing snapshot of "what is the device doing right now?"
///
/// Derived by ``LiveViewModel`` from the device's periodic
/// ``StatusUpdate`` heartbeats (and session-end ``SessionSummary``
/// events) so the live-view overlay can render a session pill and
/// hopper badge without the view having to understand proto types or
/// the two-event interaction.
///
/// A separate value type — rather than a flag on
/// ``LiveViewState`` — because this is ambient device state that
/// persists across stream start / stop cycles: a user watching live
/// video sees the same "Playing now • 1m 20s" regardless of whether
/// they started the stream five seconds ago or five minutes ago, and
/// the session continues after they tap Stop.
public struct LiveSessionStatus: Sendable, Equatable {
    /// Coarse state of the device's play-session state machine.
    public enum Phase: Sendable, Equatable {
        /// No status has been received since the broker started. The
        /// overlay hides itself in this phase rather than flashing a
        /// "not playing" badge that is really just "we haven't heard
        /// yet."
        case unknown
        /// Device is connected and not currently running a play
        /// session. Heartbeat is ticking.
        case idle
        /// Device is currently engaging a cat — lure / chase / tease /
        /// cooldown / dispense are all "playing" from the overlay's
        /// perspective; the user just wants to know "is something
        /// happening right now."
        case playing
    }

    /// Coarse state, computed from ``StatusUpdate/sessionActive`` +
    /// ``SessionSummary`` edge events.
    public var phase: Phase

    /// Number of distinct cats the device is currently tracking in
    /// this session. Always zero when ``phase`` is not ``playing``.
    public var activeCatCount: Int

    /// Steady-state hopper reading from the last heartbeat. The
    /// overlay surfaces a badge when this is ``low`` or ``empty``.
    public var hopperLevel: Catlaser_App_V1_HopperLevel

    /// Wall-clock time at which the current session was first observed
    /// active by this app instance. Nil when ``phase`` is not
    /// ``playing``. The device does not publish its own session-start
    /// timestamp on ``StatusUpdate``, so this is a client-side
    /// best-effort: the overlay renders "≈ Xm Ys" elapsed against this
    /// value, acknowledging that the displayed duration may
    /// underestimate slightly if the app joined the connection after
    /// the session was already underway.
    public var sessionStartedAt: Date?

    /// Firmware version reported by the device. Threaded through so
    /// diagnostic / settings screens that want a live version badge
    /// can read it without spinning up their own status subscription.
    public var firmwareVersion: String

    public init(
        phase: Phase = .unknown,
        activeCatCount: Int = 0,
        hopperLevel: Catlaser_App_V1_HopperLevel = .unspecified,
        sessionStartedAt: Date? = nil,
        firmwareVersion: String = "",
    ) {
        self.phase = phase
        self.activeCatCount = activeCatCount
        self.hopperLevel = hopperLevel
        self.sessionStartedAt = sessionStartedAt
        self.firmwareVersion = firmwareVersion
    }
}
