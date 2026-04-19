import CatLaserProto
import Foundation
import Testing

@testable import CatLaserSchedule

/// Boundary tests for ``ScheduleValidation``.
///
/// The validator is pure: given a draft, it returns ``nil`` or the
/// first failing rule. The tests cover every boundary on every rule
/// so a refactor that slid a bound by one is caught immediately.
/// The two-entry cross-entry rules (unique id, count cap) are
/// exercised through ``validate(set:)``.
@Suite("ScheduleValidation")
struct ScheduleValidationTests {
    // MARK: - Factory

    private func draft(
        id: String = "morning",
        startMinute: Int = 480,
        durationMinutes: Int = 30,
        days: Set<Catlaser_App_V1_DayOfWeek> = [],
        enabled: Bool = true,
    ) -> ScheduleEntryDraft {
        ScheduleEntryDraft(
            id: id,
            startMinute: startMinute,
            durationMinutes: durationMinutes,
            days: days,
            enabled: enabled,
        )
    }

    // MARK: - id

    @Test
    func validDraftPasses() {
        #expect(ScheduleValidation.validate(draft()) == nil)
    }

    @Test
    func emptyIDFails() {
        let result = ScheduleValidation.validate(draft(id: ""))
        if case .invalidEntryID = result { /* good */ } else {
            Issue.record("expected .invalidEntryID, got \(String(describing: result))")
        }
    }

    @Test
    func whitespaceOnlyIDFails() {
        let result = ScheduleValidation.validate(draft(id: "   \n\t"))
        if case .invalidEntryID = result { /* good */ } else {
            Issue.record("expected .invalidEntryID, got \(String(describing: result))")
        }
    }

    @Test
    func overlongIDFails() {
        let tooLong = String(repeating: "x", count: ScheduleValidation.maxEntryIDLength + 1)
        let result = ScheduleValidation.validate(draft(id: tooLong))
        if case .invalidEntryID = result { /* good */ } else {
            Issue.record("expected .invalidEntryID, got \(String(describing: result))")
        }
    }

    @Test
    func maxLengthIDPasses() {
        let exactly = String(repeating: "x", count: ScheduleValidation.maxEntryIDLength)
        #expect(ScheduleValidation.validate(draft(id: exactly)) == nil)
    }

    // MARK: - startMinute

    @Test
    func startMinuteAtZeroPasses() {
        #expect(ScheduleValidation.validate(draft(startMinute: 0)) == nil)
    }

    @Test
    func startMinuteAtMaxPasses() {
        #expect(ScheduleValidation.validate(draft(startMinute: 1_439)) == nil)
    }

    @Test
    func startMinuteNegativeFails() {
        let result = ScheduleValidation.validate(draft(startMinute: -1))
        if case .startMinuteOutOfRange = result { /* good */ } else {
            Issue.record("expected .startMinuteOutOfRange, got \(String(describing: result))")
        }
    }

    @Test
    func startMinuteAt1440Fails() {
        let result = ScheduleValidation.validate(draft(startMinute: 1_440))
        if case .startMinuteOutOfRange = result { /* good */ } else {
            Issue.record("expected .startMinuteOutOfRange, got \(String(describing: result))")
        }
    }

    // MARK: - duration

    @Test
    func durationOfOneMinutePasses() {
        #expect(ScheduleValidation.validate(draft(durationMinutes: 1)) == nil)
    }

    @Test
    func durationOfExactlyOneDayPasses() {
        #expect(ScheduleValidation.validate(draft(durationMinutes: 1_440)) == nil)
    }

    @Test
    func durationOfZeroFails() {
        let result = ScheduleValidation.validate(draft(durationMinutes: 0))
        if case .durationOutOfRange = result { /* good */ } else {
            Issue.record("expected .durationOutOfRange, got \(String(describing: result))")
        }
    }

    @Test
    func durationAbove24HFails() {
        let result = ScheduleValidation.validate(draft(durationMinutes: 1_441))
        if case .durationOutOfRange = result { /* good */ } else {
            Issue.record("expected .durationOutOfRange, got \(String(describing: result))")
        }
    }

    @Test
    func midnightCrossingWindowIsValid() {
        // 23:00 start + 120 minutes = window ending at 01:00 next
        // day. Legal per the device's is_within_window — the
        // validator must accept it.
        #expect(ScheduleValidation.validate(
            draft(startMinute: 1_380, durationMinutes: 120),
        ) == nil)
    }

    // MARK: - days

    @Test
    func emptyDaysIsValid() {
        // Empty means "every day" on the device. Refusing this would
        // deny the user the simplest way to express "always-on".
        #expect(ScheduleValidation.validate(draft(days: [])) == nil)
    }

    @Test
    func allSevenDaysIsValid() {
        let allDays: Set<Catlaser_App_V1_DayOfWeek> = [
            .monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday,
        ]
        #expect(ScheduleValidation.validate(draft(days: allDays)) == nil)
    }

    @Test
    func unspecifiedDayFails() {
        let result = ScheduleValidation.validate(draft(days: [.monday, .unspecified]))
        #expect(result == .invalidDay)
    }

    @Test
    func unknownDayFails() {
        let result = ScheduleValidation.validate(draft(days: [.UNRECOGNIZED(42)]))
        #expect(result == .invalidDay)
    }

    // MARK: - cross-entry

    @Test
    func setOfDistinctEntriesPasses() {
        let set = ScheduleDraftSet(baseline: [
            draft(id: "a", startMinute: 480),
            draft(id: "b", startMinute: 720),
        ])
        #expect(ScheduleValidation.validate(set: set) == nil)
    }

    @Test
    func setWithDuplicateIDsFails() {
        var raw = ScheduleDraftSet(baseline: [
            draft(id: "a", startMinute: 480),
        ])
        raw.append(draft(id: "a", startMinute: 720))
        let result = ScheduleValidation.validate(set: raw)
        if case let .duplicateEntryID(id) = result {
            #expect(id == "a")
        } else {
            Issue.record("expected .duplicateEntryID, got \(String(describing: result))")
        }
    }

    @Test
    func setOverCapFails() {
        let entries = (0 ... ScheduleValidation.maxEntryCount).map { i in
            draft(id: "entry-\(i)", startMinute: i % ScheduleValidation.minutesPerDay)
        }
        var set = ScheduleDraftSet()
        for entry in entries {
            set.append(entry)
        }
        let result = ScheduleValidation.validate(set: set)
        if case let .tooManyEntries(count) = result {
            #expect(count == ScheduleValidation.maxEntryCount + 1)
        } else {
            Issue.record("expected .tooManyEntries, got \(String(describing: result))")
        }
    }

    @Test
    func setPropagatesPerEntryFailure() {
        var set = ScheduleDraftSet(baseline: [
            draft(id: "a", durationMinutes: 0),
        ])
        set.append(draft(id: "b"))
        let result = ScheduleValidation.validate(set: set)
        if case .durationOutOfRange = result { /* good */ } else {
            Issue.record("expected per-entry failure to propagate, got \(String(describing: result))")
        }
    }
}

/// Contract tests for ``ScheduleEntryDraft`` round-trips.
///
/// The draft ↔ wire conversion is the single seam between the local
/// editor and the wire — a drift there would manifest as a schedule
/// entry the device stored differently from what the user saw. The
/// tests pin both directions on the fields that matter.
@Suite("ScheduleEntryDraft")
struct ScheduleEntryDraftTests {
    @Test
    func wireRoundTripPreservesAllFields() {
        var wire = Catlaser_App_V1_ScheduleEntry()
        wire.entryID = "morning"
        wire.startMinute = 480
        wire.durationMin = 30
        wire.days = [.monday, .friday]
        wire.enabled = true
        let draft = ScheduleEntryDraft(wire: wire)
        let roundTripped = draft.toWire()
        #expect(roundTripped.entryID == wire.entryID)
        #expect(roundTripped.startMinute == wire.startMinute)
        #expect(roundTripped.durationMin == wire.durationMin)
        #expect(roundTripped.days == wire.days)
        #expect(roundTripped.enabled == wire.enabled)
    }

    @Test
    func sortedDaysIsMondayFirst() {
        let draft = ScheduleEntryDraft(
            id: "x",
            startMinute: 0,
            durationMinutes: 10,
            days: [.sunday, .wednesday, .monday],
            enabled: true,
        )
        #expect(draft.sortedDays == [.monday, .wednesday, .sunday])
    }

    @Test
    func toWireOmitsUnspecifiedDays() {
        // The UI layer cannot produce ``.unspecified`` (the
        // toggles only bind ``.monday … .sunday``), but the invariant
        // that the wire payload is monotonically ordered and free
        // of unknowns is worth pinning explicitly.
        let draft = ScheduleEntryDraft(
            id: "x",
            startMinute: 0,
            durationMinutes: 10,
            days: [.unspecified, .monday],
            enabled: true,
        )
        #expect(draft.sortedDays == [.monday])
    }

    @Test
    func freshDraftPicksStableDefaults() {
        let draft = ScheduleEntryDraft.freshDraft(idFactory: { "fixed" })
        #expect(draft.id == "fixed")
        #expect(draft.startMinute == 8 * 60)
        #expect(draft.durationMinutes == 15)
        #expect(draft.days == [])
        #expect(draft.enabled)
    }
}

/// Contract tests for ``ScheduleDraftSet``.
///
/// The draft set is the load-bearing unit of state in the VM: its
/// ``isDirty`` flag gates the Save button, its sort order drives
/// the UI list, its discard/adopt paths handle the round-trip
/// boundaries. Tests pin the semantics of each.
@Suite("ScheduleDraftSet")
struct ScheduleDraftSetTests {
    private func entry(id: String, at minute: Int) -> ScheduleEntryDraft {
        ScheduleEntryDraft(
            id: id,
            startMinute: minute,
            durationMinutes: 30,
            days: [],
            enabled: true,
        )
    }

    @Test
    func emptySetIsNotDirty() {
        let set = ScheduleDraftSet()
        #expect(!set.isDirty)
    }

    @Test
    func baselineEqualsDraftIsNotDirty() {
        let seed = [entry(id: "a", at: 100)]
        let set = ScheduleDraftSet(baseline: seed)
        #expect(!set.isDirty)
    }

    @Test
    func appendFlipsDirty() {
        var set = ScheduleDraftSet()
        set.append(entry(id: "a", at: 100))
        #expect(set.isDirty)
    }

    @Test
    func appendIsSortedChronologically() {
        var set = ScheduleDraftSet()
        set.append(entry(id: "later", at: 720))
        set.append(entry(id: "earlier", at: 480))
        #expect(set.entries.map(\.id) == ["earlier", "later"])
    }

    @Test
    func updateReSortsOnStartMinuteChange() {
        var set = ScheduleDraftSet(baseline: [
            entry(id: "a", at: 480),
            entry(id: "b", at: 720),
        ])
        var mutated = entry(id: "a", at: 1_000)
        mutated.durationMinutes = 30
        set.update(mutated)
        #expect(set.entries.map(\.id) == ["b", "a"])
    }

    @Test
    func updateOnMissingIDIsNoOp() {
        var set = ScheduleDraftSet(baseline: [entry(id: "a", at: 480)])
        set.update(entry(id: "ghost", at: 1_000))
        #expect(set.entries.map(\.id) == ["a"])
        #expect(!set.isDirty)
    }

    @Test
    func removeMissingIDIsNoOp() {
        var set = ScheduleDraftSet(baseline: [entry(id: "a", at: 480)])
        set.remove(id: "ghost")
        #expect(set.entries.map(\.id) == ["a"])
        #expect(!set.isDirty)
    }

    @Test
    func discardSnapsBackToBaseline() {
        var set = ScheduleDraftSet(baseline: [entry(id: "a", at: 480)])
        set.append(entry(id: "b", at: 720))
        #expect(set.isDirty)
        set.discard()
        #expect(!set.isDirty)
        #expect(set.entries.map(\.id) == ["a"])
    }

    @Test
    func adoptBaselineReplacesBothBaselineAndDraft() {
        var set = ScheduleDraftSet(baseline: [entry(id: "a", at: 480)])
        set.append(entry(id: "b", at: 720))
        set.adoptBaseline([entry(id: "c", at: 1_000)])
        #expect(!set.isDirty)
        #expect(set.entries.map(\.id) == ["c"])
        #expect(set.baseline.map(\.id) == ["c"])
    }

    @Test
    func tiesBreakByIDForStableOrdering() {
        var set = ScheduleDraftSet()
        set.append(entry(id: "b", at: 480))
        set.append(entry(id: "a", at: 480))
        // Both at the same minute: id breaks the tie so the order
        // is deterministic.
        #expect(set.entries.map(\.id) == ["a", "b"])
    }

    @Test
    func wireInitAcceptsMultipleEntries() {
        var list = Catlaser_App_V1_ScheduleList()
        list.entries = [
            {
                var e = Catlaser_App_V1_ScheduleEntry()
                e.entryID = "evening"
                e.startMinute = 1_200
                e.durationMin = 30
                e.enabled = true
                return e
            }(),
            {
                var e = Catlaser_App_V1_ScheduleEntry()
                e.entryID = "morning"
                e.startMinute = 480
                e.durationMin = 30
                e.enabled = true
                return e
            }(),
        ]
        let set = ScheduleDraftSet(wire: list)
        #expect(set.entries.map(\.id) == ["morning", "evening"])
        #expect(!set.isDirty)
    }
}
