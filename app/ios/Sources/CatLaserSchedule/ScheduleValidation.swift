import Foundation

/// Pure validation rules for ``ScheduleEntryDraft`` and
/// ``ScheduleDraftSet``.
///
/// Every rule here matches the device-side contract: the protobuf
/// comments in ``proto/catlaser/app/v1/app.proto`` pin the
/// ``start_minute`` range at 0–1439 and require a positive
/// ``duration_min``; the Python evaluator in
/// ``python/catlaser_brain/behavior/schedule.py`` accepts a window
/// that crosses midnight (``start_minute + duration_min > 1440``) and
/// treats an empty ``days`` list as "every day".
///
/// Validation runs before any wire traffic. Refusing the malformed
/// draft at the VM layer keeps invalid rows from burning an
/// attestation-signed ``SetScheduleRequest`` round-trip that the
/// device would silently accept (the device handler does not
/// validate).
public enum ScheduleValidation {
    // MARK: - Boundaries

    /// Minutes per day. Exposed as a constant so tests and UI
    /// formatters share the same wall-clock definition.
    public static let minutesPerDay = 1440

    /// Inclusive lower bound on ``startMinute``.
    public static let minStartMinute = 0

    /// Inclusive upper bound on ``startMinute`` (23:59).
    public static let maxStartMinute = minutesPerDay - 1

    /// Inclusive lower bound on ``durationMinutes``. A zero-length
    /// window would be rejected by
    /// ``is_within_window`` on the device and makes no user-facing
    /// sense either — a window exists to cover at least one minute
    /// of play.
    public static let minDurationMinutes = 1

    /// Inclusive upper bound on ``durationMinutes``. A window longer
    /// than 24 hours covers every minute in a day, which
    /// ``enabled: false`` + "every day" already expresses without
    /// the midnight overflow ambiguity; cap the editor so the user
    /// cannot type a duration that wraps on itself.
    public static let maxDurationMinutes = minutesPerDay

    /// Inclusive upper bound on a draft's ``id`` length. The device
    /// side stores the id in an unbounded SQLite ``TEXT`` column, so
    /// the cap is a pure sanity guard: refuse an absurd paste that
    /// would balloon the ``SetScheduleRequest`` frame. A UUID takes
    /// 36 characters, so 128 leaves room for a scheme-prefix without
    /// risking a truncation surprise.
    public static let maxEntryIDLength = 128

    /// Soft cap on the total number of entries a user may persist.
    /// Protects against accidental pathological input (a paste of
    /// ten thousand rows) without imposing a hard device-side
    /// constraint: ``set_schedule`` atomically replaces the whole
    /// set, so a very large wire frame would time out the round
    /// trip long before storage itself complained.
    public static let maxEntryCount = 64

    // MARK: - Errors

    /// Typed failure modes surfaced by ``validate(_:)`` and
    /// ``validate(set:)``. Each carries enough context for the UI
    /// to render a field-level hint without re-walking the draft.
    public enum Failure: Error, Equatable, Sendable {
        /// ``id`` is empty, longer than ``maxEntryIDLength``, or
        /// contains only whitespace.
        case invalidEntryID(String)
        /// ``startMinute`` is outside ``minStartMinute ... maxStartMinute``.
        case startMinuteOutOfRange(Int)
        /// ``durationMinutes`` is outside
        /// ``minDurationMinutes ... maxDurationMinutes``.
        case durationOutOfRange(Int)
        /// ``days`` contains an ``.unspecified`` or ``UNRECOGNIZED``
        /// enum case. This should be impossible after
        /// ``ScheduleEntryDraft.init(wire:)`` filters, but the
        /// validator is the last gate before the wire and treats a
        /// bad enum as structural corruption.
        case invalidDay
        /// Two or more entries in the set share the same ``id``. The
        /// device-side ``set_schedule`` DELETE-then-INSERT would
        /// silently deduplicate, hiding the mistake; catching it at
        /// validation keeps the local draft honest.
        case duplicateEntryID(String)
        /// The draft set exceeds ``maxEntryCount``.
        case tooManyEntries(Int)
    }

    // MARK: - Single-entry validation

    /// Validate one draft entry. Returns ``nil`` on success; the
    /// first failing rule otherwise — the UI presents one error
    /// at a time, so returning multiple would force the caller to
    /// pick one anyway.
    public static func validate(_ entry: ScheduleEntryDraft) -> Failure? {
        let trimmedID = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedID.isEmpty || entry.id.count > maxEntryIDLength {
            return .invalidEntryID(entry.id)
        }
        if entry.startMinute < minStartMinute || entry.startMinute > maxStartMinute {
            return .startMinuteOutOfRange(entry.startMinute)
        }
        if entry.durationMinutes < minDurationMinutes || entry.durationMinutes > maxDurationMinutes {
            return .durationOutOfRange(entry.durationMinutes)
        }
        for day in entry.days {
            switch day {
            case .unspecified, .UNRECOGNIZED:
                return .invalidDay
            case .monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday:
                continue
            }
        }
        return nil
    }

    /// Validate the whole draft set: each entry individually, then
    /// the cross-entry rules (unique ids, total count). The first
    /// failing rule wins.
    public static func validate(set: ScheduleDraftSet) -> Failure? {
        if set.entries.count > maxEntryCount {
            return .tooManyEntries(set.entries.count)
        }
        var seen = Set<String>()
        for entry in set.entries {
            if let failure = validate(entry) {
                return failure
            }
            if !seen.insert(entry.id).inserted {
                return .duplicateEntryID(entry.id)
            }
        }
        return nil
    }
}
