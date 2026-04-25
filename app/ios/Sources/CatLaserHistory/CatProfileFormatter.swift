import CatLaserProto
import Foundation

/// Pure formatting helpers shared by the cat-profile and play-session
/// rows. Lifting these out of the SwiftUI layer means tests can pin the
/// rendered output without spinning up a view hierarchy.
///
/// Every formatter accepts an explicit ``Calendar`` and ``Locale`` so
/// tests can pin the result; the public conveniences default to
/// ``Calendar.current`` / ``Locale.current`` and use the system
/// timezone, which is what the SwiftUI layer wants in production.
public enum CatProfileFormatter {
    /// Render an unsigned-second duration as a compact "1h 23m", "12m
    /// 04s", "47s" string. Zero seconds renders as "0s" so the row
    /// never reads as a missing value.
    public static func playTimeString(secondsTotal: UInt32) -> String {
        let total = Int(secondsTotal)
        if total <= 0 {
            return "0s"
        }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    /// Render a session count with simple deterministic
    /// pluralisation. The SPM test runner does not load Localizable
    /// strings tables, so the value resolves to the English fallback;
    /// production iOS resolves through the bundle's table when
    /// localised resources land.
    public static func sessionsString(count: UInt32, locale: Locale = .current) -> String {
        let count = Int(count)
        let template = NSLocalizedString(
            "history.format.sessions",
            value: count == 1 ? "1 session" : "%lld sessions",
            comment: "Lifetime session count for a cat profile.",
        )
        return String(format: template, locale: locale, count)
    }

    // MARK: - Engagement

    /// Bucket boundary above which a session reads as "very playful".
    /// 0.80 maps to a session in which the cat was tracking the laser
    /// for the bulk of the active time. The exact thresholds are
    /// product-tuned: a too-tight cap pushes most sessions into the
    /// middle bucket and the label loses meaning; too-loose and a
    /// distracted cat reads as a star athlete.
    public static let engagementVeryPlayfulThreshold: Float = 0.80

    /// Bucket boundary above which a session reads as "playful". Below
    /// this and the session collapses to "mild interest" — the cat
    /// looked at the laser but did not engage with it for long.
    public static let engagementPlayfulThreshold: Float = 0.50

    /// Render the raw engagement score (0.0–1.0) as a human-readable
    /// label. Three buckets — "Very playful" / "Playful" / "Mild
    /// interest" — chosen so a cat owner can read the row without a
    /// scale: every label is interpretable on its own. The score is
    /// clamped to the visible 0.0–1.0 domain so a malformed device
    /// reading does not produce a degenerate label.
    ///
    /// Why three buckets, not five: the underlying signal is a noisy
    /// time-weighted average of bbox-track engagement; an owner cannot
    /// reliably distinguish 0.60 from 0.70 across two sessions, so
    /// finer-grained labels would carry false precision. Three is the
    /// minimum that captures the meaningful distinction "great session
    /// / decent session / cat wasn't into it today" without
    /// over-promising.
    public static func engagementLabel(score: Float) -> String {
        let clamped = max(0, min(score, 1))
        if clamped >= engagementVeryPlayfulThreshold {
            return NSLocalizedString(
                "history.format.engagement.very_playful",
                value: "Very playful",
                comment: "Engagement-score label for sessions where the cat tracked the laser the whole time.",
            )
        }
        if clamped >= engagementPlayfulThreshold {
            return NSLocalizedString(
                "history.format.engagement.playful",
                value: "Playful",
                comment: "Engagement-score label for sessions where the cat engaged with the laser for most of the session.",
            )
        }
        return NSLocalizedString(
            "history.format.engagement.mild",
            value: "Mild interest",
            comment: "Engagement-score label for sessions where the cat noticed the laser but did not engage strongly.",
        )
    }

    /// Spoken accessibility variant of ``engagementLabel(score:)``. Pairs
    /// the label with a percentage so a VoiceOver user hears both —
    /// "Very playful, 87 percent". A sighted user reads the label
    /// alone (the row real estate doesn't fit both); the percentage
    /// is added only on the spoken path.
    public static func engagementAccessibilityLabel(score: Float) -> String {
        let clamped = max(0, min(score, 1))
        let label = engagementLabel(score: clamped)
        let percent = Int((clamped * 100).rounded())
        let format = NSLocalizedString(
            "history.format.engagement.accessibility",
            value: "%1$@, %2$d percent",
            comment: "Positional VoiceOver label for the engagement-score statblock. Arg 1 is the bucket label, arg 2 is the integer percent.",
        )
        return String(format: format, label, percent)
    }

    /// Render a treats-dispensed count. Same fallback rules as
    /// ``sessionsString``.
    public static func treatsString(count: UInt32, locale: Locale = .current) -> String {
        let count = Int(count)
        let template = NSLocalizedString(
            "history.format.treats",
            value: count == 1 ? "1 treat" : "%lld treats",
            comment: "Lifetime treats-dispensed count for a cat profile.",
        )
        return String(format: template, locale: locale, count)
    }

    /// Render an epoch-second timestamp into a short relative-style
    /// date for play-session rows ("Today", "Yesterday", "Apr 17").
    /// The relative-formatter calendar is exposed so tests can pin it
    /// to a fixed reference date without monkey-patching the system
    /// clock.
    public static func sessionDateString(
        epochSeconds: UInt64,
        relativeTo reference: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current,
    ) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        var calendar = calendar
        calendar.locale = locale
        // ``Calendar.isDateInToday`` reads the system clock rather
        // than honouring an explicit reference; comparing days
        // against the supplied ``reference`` keeps the formatter
        // deterministic for tests AND lets the production caller
        // pin to a frozen "now" if it wants to.
        let referenceDay = calendar.startOfDay(for: reference)
        let candidateDay = calendar.startOfDay(for: date)
        let dayDelta = calendar.dateComponents([.day], from: candidateDay, to: referenceDay).day ?? 0
        if dayDelta == 0 {
            return NSLocalizedString(
                "history.format.today",
                value: "Today",
                comment: "Relative date label for sessions that started today.",
            )
        }
        if dayDelta == 1 {
            return NSLocalizedString(
                "history.format.yesterday",
                value: "Yesterday",
                comment: "Relative date label for sessions that started yesterday.",
            )
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        // If the reference and the session fall in the same year,
        // collapse to "MMM d" — the year is implied. Otherwise show
        // "MMM d, yyyy" so the row is unambiguous in retrospective
        // reads.
        if calendar.component(.year, from: date) == calendar.component(.year, from: reference) {
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        }
        return formatter.string(from: date)
    }

    /// Render the cat-id summary for a play session row. Resolves
    /// ids against the supplied profile catalogue and falls back
    /// to localized "Unknown cat" / "Multiple cats" strings rather
    /// than leaking the raw uuid identifier.
    public static func sessionCatsSummary(
        catIDs: [String],
        profiles: [Catlaser_App_V1_CatProfile],
    ) -> String {
        guard !catIDs.isEmpty else {
            return HistoryStrings.sessionRowUnknownCat
        }
        let lookup = Dictionary(uniqueKeysWithValues: profiles.map { ($0.catID, $0.name) })
        let names = catIDs
            .map { lookup[$0] ?? "" }
            .filter { !$0.isEmpty }
        if names.count == catIDs.count, names.count == 1 {
            return names[0]
        }
        if !names.isEmpty {
            return joinNames(names)
        }
        return catIDs.count == 1
            ? HistoryStrings.sessionRowUnknownCat
            : HistoryStrings.sessionRowMultipleCats
    }

    /// Join cat names into a single comma + "and" list. Uses
    /// ``ListFormatter`` on Darwin (locale-aware) and a deterministic
    /// English fallback elsewhere — Swift Foundation on Linux does
    /// not currently ship ``ListFormatter`` so the SPM CI runner
    /// would otherwise fail to link.
    private static func joinNames(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        #if canImport(Darwin)
        return ListFormatter.localizedString(byJoining: names)
        #else
        if names.count == 2 {
            return "\(names[0]) and \(names[1])"
        }
        let head = names.dropLast().joined(separator: ", ")
        return "\(head), and \(names.last!)"
        #endif
    }
}
