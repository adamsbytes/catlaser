import CatLaserProto
import Foundation

/// Local edit model for one ``Catlaser_App_V1_ScheduleEntry``.
///
/// The draft is a plain value type (unlike the proto, which is a
/// `struct` with mutable properties but also carries
/// ``SwiftProtobuf.UnknownStorage`` baggage). Keeping drafts separate
/// lets the UI layer mutate fields in place while keeping the proto
/// wire type used only at the serialise-and-send boundary.
///
/// ``id`` doubles as ``Identifiable.id`` so SwiftUI's ``ForEach`` can
/// key rows without ceremony. It is a locally-minted UUID string until
/// the first ``SetScheduleRequest`` round-trip lands; the device
/// accepts whatever stable string the app supplies (its own SQLite
/// primary key is this same ``entry_id``).
///
/// Days are modelled as a ``Set<Catlaser_App_V1_DayOfWeek>`` so UI
/// toggles are idempotent and order-independent. The wire emission
/// orders them monotonically (Monday → Sunday) via ``sortedDays`` so
/// the round-trip is deterministic regardless of the user's toggle
/// order.
public struct ScheduleEntryDraft: Identifiable, Sendable, Equatable {
    /// Stable identifier for the entry. Matches the device's SQLite
    /// ``entry_id`` column and round-trips verbatim through
    /// ``SetScheduleRequest`` / ``ScheduleList``. Generated locally
    /// for brand-new entries in ``ScheduleViewModel/addEntry`` and
    /// preserved byte-for-byte once the server has ack'd.
    public var id: String

    /// Time of day the window opens, as minutes since midnight
    /// (``ScheduleValidation/minStartMinute`` … ``maxStartMinute``).
    /// The setter performs no validation — ``ScheduleValidation``
    /// owns the boundaries. Stored as ``Int`` for ergonomics; the
    /// wire type is ``UInt32``.
    public var startMinute: Int

    /// Window length in minutes
    /// (``ScheduleValidation/minDurationMinutes`` …
    /// ``maxDurationMinutes``). Values above ``minutesPerDay`` are
    /// legal — the window crosses midnight, matching
    /// ``is_within_window`` on the device side.
    public var durationMinutes: Int

    /// The days on which this entry is active. Empty means "every
    /// day" — the device's scheduler interprets the empty set the
    /// same way (see ``python/catlaser_brain/behavior/schedule.py``),
    /// and a UI that forbade the empty set would deny users the most
    /// convenient way to express "always on". ``.unspecified`` and
    /// any ``UNRECOGNIZED`` case are filtered out on ingest.
    public var days: Set<Catlaser_App_V1_DayOfWeek>

    /// Whether the window is in effect. A disabled entry is still
    /// sent on the wire (the device stores it) but the scheduler's
    /// ``load_schedule`` query filters it out at runtime.
    public var enabled: Bool

    public init(
        id: String,
        startMinute: Int,
        durationMinutes: Int,
        days: Set<Catlaser_App_V1_DayOfWeek>,
        enabled: Bool,
    ) {
        self.id = id
        self.startMinute = startMinute
        self.durationMinutes = durationMinutes
        self.days = days
        self.enabled = enabled
    }

    /// Build a blank draft with a freshly-minted UUID id and the
    /// current time window suggested as the default (08:00, 15
    /// minutes, every day, enabled). The host can override the
    /// factory in ``ScheduleViewModel/addEntry(_:)`` via the returned
    /// draft; this is just a starting point the UI can present.
    public static func freshDraft(idFactory: () -> String = { UUID().uuidString }) -> ScheduleEntryDraft {
        ScheduleEntryDraft(
            id: idFactory(),
            startMinute: 8 * 60,
            durationMinutes: 15,
            days: [],
            enabled: true,
        )
    }

    /// Ingest a wire entry as a draft. Unknown / unspecified day
    /// enum cases are discarded — the device's enum surface may
    /// advance ahead of the app, and an ``UNRECOGNIZED`` payload in
    /// the draft would round-trip unchanged and keep the unknown
    /// tag alive indefinitely. Filtering on ingest means the app
    /// always emits only the enum values it knows about.
    public init(wire: Catlaser_App_V1_ScheduleEntry) {
        self.id = wire.entryID
        self.startMinute = Int(wire.startMinute)
        self.durationMinutes = Int(wire.durationMin)
        self.days = Set(wire.days.filter { day in
            switch day {
            case .unspecified, .UNRECOGNIZED:
                return false
            case .monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday:
                return true
            }
        })
        self.enabled = wire.enabled
    }

    /// Canonical, monotonically-ordered day list for wire emission
    /// (Monday → Sunday). Keeps ``SetScheduleRequest`` deterministic
    /// regardless of the user's toggle order so round-trip snapshots
    /// in tests stay stable.
    public var sortedDays: [Catlaser_App_V1_DayOfWeek] {
        let order: [Catlaser_App_V1_DayOfWeek] = [
            .monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday,
        ]
        return order.filter { days.contains($0) }
    }

    /// Serialise the draft onto the wire. The caller is responsible
    /// for having validated the draft first via
    /// ``ScheduleValidation/validate(_:)`` — this method performs no
    /// clamping.
    public func toWire() -> Catlaser_App_V1_ScheduleEntry {
        var entry = Catlaser_App_V1_ScheduleEntry()
        entry.entryID = id
        entry.startMinute = UInt32(max(0, startMinute))
        entry.durationMin = UInt32(max(0, durationMinutes))
        entry.days = sortedDays
        entry.enabled = enabled
        return entry
    }

    /// Inclusive start minute within the 0–1439 day. Mirrors the
    /// wire field name for call-site clarity.
    public var startMinuteOfDay: Int { startMinute }

    /// The minute at which the window ends. May exceed
    /// ``ScheduleValidation/minutesPerDay`` when the window crosses
    /// midnight — callers that need the local-clock end minute
    /// should modulo by 1440.
    public var endMinuteRaw: Int { startMinute + durationMinutes }
}

/// An ordered collection of ``ScheduleEntryDraft`` values bundled
/// with the server baseline it was ingested from. The type is the
/// load-bearing unit of state in ``ScheduleViewModel`` — mutating
/// the draft set is what makes ``isDirty`` flip; the baseline is
/// frozen until the next ``GetScheduleRequest`` /
/// ``SetScheduleRequest`` round-trip lands.
///
/// Ordering follows the sort key ``ScheduleEntryDraft/startMinute``
/// so the UI list reads chronologically without imposing that
/// sort on mutation call sites.
public struct ScheduleDraftSet: Sendable, Equatable {
    /// The latest server-authoritative snapshot. Rebuilt on every
    /// successful GET/SET round-trip.
    public private(set) var baseline: [ScheduleEntryDraft]

    /// The user's in-progress draft. Diverges from ``baseline`` as
    /// edits accumulate; snapped back to ``baseline`` by
    /// ``ScheduleViewModel/discardChanges`` and when a ``save``
    /// round-trip lands.
    public private(set) var entries: [ScheduleEntryDraft]

    public init(
        baseline: [ScheduleEntryDraft] = [],
        entries: [ScheduleEntryDraft]? = nil,
    ) {
        let sortedBaseline = Self.sorted(baseline)
        self.baseline = sortedBaseline
        self.entries = Self.sorted(entries ?? sortedBaseline)
    }

    /// Build the draft set from a wire ``ScheduleList`` reply. The
    /// entries are sorted chronologically so the UI order is stable
    /// regardless of the device's iteration order.
    public init(wire list: Catlaser_App_V1_ScheduleList) {
        let ingested = list.entries.map(ScheduleEntryDraft.init(wire:))
        self.init(baseline: ingested, entries: ingested)
    }

    /// True when the user's draft has diverged from the server
    /// baseline. Drives the "Save" button state and is the gate
    /// ``ScheduleViewModel/save`` uses to drop no-op saves before
    /// any wire traffic.
    public var isDirty: Bool {
        entries != baseline
    }

    // MARK: - Mutations

    /// Append a new draft entry. Inserted in sort order so the UI
    /// list observes chronological ordering even for a brand-new
    /// row.
    public mutating func append(_ entry: ScheduleEntryDraft) {
        entries.append(entry)
        entries = Self.sorted(entries)
    }

    /// Replace the draft at the supplied id with the supplied
    /// draft. No-op if the id is absent. Re-sorts the collection so
    /// the UI list reflects any start-minute change that might have
    /// re-ordered the entry.
    public mutating func update(_ entry: ScheduleEntryDraft) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        entries = Self.sorted(entries)
    }

    /// Remove the draft at the supplied id. No-op if the id is
    /// absent.
    public mutating func remove(id: String) {
        entries.removeAll { $0.id == id }
    }

    /// Toggle ``enabled`` on the draft at the supplied id. No-op if
    /// the id is absent.
    public mutating func toggleEnabled(id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].enabled.toggle()
    }

    /// Snap the draft collection back to the server baseline,
    /// discarding every pending edit.
    public mutating func discard() {
        entries = baseline
    }

    /// Adopt a fresh server baseline (and a matching draft) after a
    /// successful GET / SET round-trip. The caller passes the same
    /// snapshot for both because the device's reply to either
    /// request type is the authoritative full list.
    public mutating func adoptBaseline(_ entries: [ScheduleEntryDraft]) {
        let sorted = Self.sorted(entries)
        self.baseline = sorted
        self.entries = sorted
    }

    // MARK: - Sorting

    /// Stable chronological sort. Ties on ``startMinute`` fall back
    /// to ``id`` so the order is deterministic regardless of hash
    /// seed or insertion history.
    private static func sorted(_ entries: [ScheduleEntryDraft]) -> [ScheduleEntryDraft] {
        entries.sorted { lhs, rhs in
            if lhs.startMinute != rhs.startMinute {
                return lhs.startMinute < rhs.startMinute
            }
            return lhs.id < rhs.id
        }
    }
}
