import CatLaserProto
import Foundation

/// Localised strings + formatters for the live-view session overlay.
///
/// Kept alongside ``LiveSessionStatus`` so tests can exercise the
/// user-visible rendering without spinning a view. Each hook is a
/// pure function of the inputs and compiles on every platform the
/// package targets — Linux CI can exercise the localisation surface.
public enum LiveSessionStatusStrings {
    /// Overlay label for the "playing now" pill. No elapsed time —
    /// the live view composes this with ``elapsed(since:now:)`` to
    /// render "Playing now · 1m 20s" via a `TimelineView`.
    public static let playingLabel = NSLocalizedString(
        "live.status.playing",
        value: "Playing now",
        comment: "Label in the live-view overlay when the device is running a play session.",
    )

    /// Overlay label when the device is connected and idle. Rarely
    /// shown (the overlay collapses to invisible when idle) but
    /// surfaced for the tap-to-reveal path when the user explicitly
    /// brings up the chrome.
    public static let idleLabel = NSLocalizedString(
        "live.status.idle",
        value: "Idle",
        comment: "Label in the live-view overlay when the device is connected but not running a session.",
    )

    /// Accessibility-friendly long form of the "playing now" state.
    /// Used as the overlay's ``accessibilityLabel`` with an interpolated
    /// elapsed string; VoiceOver reads it rather than the visual
    /// "Playing now · 1m 20s" which screen readers parse awkwardly.
    public static func playingAccessibilityLabel(elapsed: String) -> String {
        String(
            format: NSLocalizedString(
                "live.status.playing.accessibility",
                value: "Playing now, %@ elapsed",
                comment: "VoiceOver announcement for the playing-now pill. Placeholder is elapsed time like '1 minute, 20 seconds'.",
            ),
            elapsed,
        )
    }

    /// Badge label when the hopper reading is ``low``.
    public static let hopperLowLabel = NSLocalizedString(
        "live.status.hopper.low",
        value: "Hopper low",
        comment: "Badge shown in the live-view overlay when the treat hopper is running low.",
    )

    /// Badge label when the hopper reading is ``empty``.
    public static let hopperEmptyLabel = NSLocalizedString(
        "live.status.hopper.empty",
        value: "Hopper empty",
        comment: "Badge shown in the live-view overlay when the treat hopper is empty.",
    )

    /// Maps a ``HopperLevel`` to the visible badge label, or nil when
    /// no badge should render (``ok`` / ``unspecified``).
    public static func hopperBadge(for level: Catlaser_App_V1_HopperLevel) -> String? {
        switch level {
        case .low: hopperLowLabel
        case .empty: hopperEmptyLabel
        case .ok, .unspecified:
            nil
        case .UNRECOGNIZED:
            nil
        }
    }

    /// Format a short "Xm Ys" elapsed string for the overlay pill.
    /// Reads well at a glance on top of live video; we intentionally
    /// avoid spelling out "minutes" / "seconds" for the visual path to
    /// keep the pill compact. The spoken version comes from
    /// ``spokenElapsed(since:now:)`` via VoiceOver.
    public static func elapsed(since started: Date, now: Date) -> String {
        let interval = max(0, now.timeIntervalSince(started))
        let total = Int(interval.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, seconds)
        }
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, seconds)
        }
        return String(format: "%ds", seconds)
    }

    /// Elapsed-time rendering for accessibility announcements. Hand-
    /// rolled rather than using ``DateComponentsFormatter`` because
    /// the latter is Darwin-only (swift-corelibs-foundation raises
    /// ``unavailable`` on Linux CI) and the package's tests compile
    /// on both sides. The output reads well aloud — "1 minute, 20
    /// seconds" rather than the compact "1m 20s" visual form — and
    /// pluralisation routes through ``NSLocalizedString`` so future
    /// localisations can customise the joining / unit labels.
    public static func spokenElapsed(since started: Date, now: Date) -> String {
        let interval = max(0, now.timeIntervalSince(started))
        let total = Int(interval.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60

        var parts: [String] = []
        if hours > 0 {
            parts.append(String(format: hourUnit(hours), hours))
        }
        if minutes > 0 {
            parts.append(String(format: minuteUnit(minutes), minutes))
        }
        if seconds > 0 || parts.isEmpty {
            parts.append(String(format: secondUnit(seconds), seconds))
        }
        let separator = NSLocalizedString(
            "live.status.spoken.separator",
            value: ", ",
            comment: "Separator between spoken duration parts. Default matches English list convention; localisations may replace with a locale-specific conjunction.",
        )
        return parts.joined(separator: separator)
    }

    private static func hourUnit(_ count: Int) -> String {
        count == 1
            ? NSLocalizedString(
                "live.status.spoken.hour.one",
                value: "%d hour",
                comment: "Spoken duration unit for exactly one hour. %d is the integer.",
            )
            : NSLocalizedString(
                "live.status.spoken.hour.many",
                value: "%d hours",
                comment: "Spoken duration unit for more than one hour. %d is the integer.",
            )
    }

    private static func minuteUnit(_ count: Int) -> String {
        count == 1
            ? NSLocalizedString(
                "live.status.spoken.minute.one",
                value: "%d minute",
                comment: "Spoken duration unit for exactly one minute.",
            )
            : NSLocalizedString(
                "live.status.spoken.minute.many",
                value: "%d minutes",
                comment: "Spoken duration unit for more than one minute.",
            )
    }

    private static func secondUnit(_ count: Int) -> String {
        count == 1
            ? NSLocalizedString(
                "live.status.spoken.second.one",
                value: "%d second",
                comment: "Spoken duration unit for exactly one second.",
            )
            : NSLocalizedString(
                "live.status.spoken.second.many",
                value: "%d seconds",
                comment: "Spoken duration unit for zero or more than one second.",
            )
    }
}
