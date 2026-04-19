import CatLaserProto
import Foundation
import Testing

@testable import CatLaserHistory

/// Pure-function tests for the formatter. Every function is
/// deterministic given an explicit calendar / locale / reference
/// date so the assertions are stable across CI runners.
@Suite("CatProfileFormatter")
struct CatProfileFormatterTests {
    // MARK: - Play time

    @Test
    func zeroSecondsRendersAsZeroLabel() {
        #expect(CatProfileFormatter.playTimeString(secondsTotal: 0) == "0s")
    }

    @Test
    func subMinuteRendersAsSecondsOnly() {
        #expect(CatProfileFormatter.playTimeString(secondsTotal: 1) == "1s")
        #expect(CatProfileFormatter.playTimeString(secondsTotal: 59) == "59s")
    }

    @Test
    func subHourRendersAsMinutesAndSeconds() {
        #expect(CatProfileFormatter.playTimeString(secondsTotal: 60) == "1m 0s")
        #expect(CatProfileFormatter.playTimeString(secondsTotal: 125) == "2m 5s")
        #expect(CatProfileFormatter.playTimeString(secondsTotal: 3599) == "59m 59s")
    }

    @Test
    func multiHourRendersAsHoursAndMinutes() {
        #expect(CatProfileFormatter.playTimeString(secondsTotal: 3600) == "1h 0m")
        #expect(CatProfileFormatter.playTimeString(secondsTotal: 3661) == "1h 1m")
        #expect(CatProfileFormatter.playTimeString(secondsTotal: 7321) == "2h 2m")
    }

    @Test
    func playTimeFormatHandlesUInt32Max() {
        // 4_294_967_295 sec ≈ 1_193_046 hours. The formatter should
        // not overflow (`Int(UInt32.max)` is safe on 64-bit Swift)
        // and should not crash.
        let rendered = CatProfileFormatter.playTimeString(secondsTotal: UInt32.max)
        #expect(rendered.hasSuffix("m"))
        #expect(!rendered.isEmpty)
    }

    // MARK: - Pluralisation

    @Test
    func sessionsAndTreatsPluralise() {
        let posix = Locale(identifier: "en_US_POSIX")
        #expect(CatProfileFormatter.sessionsString(count: 0, locale: posix) == "0 sessions")
        #expect(CatProfileFormatter.sessionsString(count: 1, locale: posix) == "1 session")
        #expect(CatProfileFormatter.sessionsString(count: 12, locale: posix) == "12 sessions")
        #expect(CatProfileFormatter.treatsString(count: 0, locale: posix) == "0 treats")
        #expect(CatProfileFormatter.treatsString(count: 1, locale: posix) == "1 treat")
        #expect(CatProfileFormatter.treatsString(count: 7, locale: posix) == "7 treats")
    }

    // MARK: - Session date

    @Test
    func sessionDateRendersTodayLiteral() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = Date(timeIntervalSince1970: 1_712_345_678) // 2024-04-05
        let sameDay = Date(timeIntervalSince1970: 1_712_345_000)
        #expect(
            CatProfileFormatter.sessionDateString(
                epochSeconds: UInt64(sameDay.timeIntervalSince1970),
                relativeTo: reference,
                calendar: calendar,
                locale: Locale(identifier: "en_US_POSIX"),
            )
                == "Today",
        )
    }

    @Test
    func sessionDateRendersYesterdayLiteral() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = Date(timeIntervalSince1970: 1_712_345_678) // 2024-04-05 19:34Z
        // 24h+ earlier should land on the previous calendar day in UTC.
        let prior = reference.addingTimeInterval(-86_400)
        #expect(
            CatProfileFormatter.sessionDateString(
                epochSeconds: UInt64(prior.timeIntervalSince1970),
                relativeTo: reference,
                calendar: calendar,
                locale: Locale(identifier: "en_US_POSIX"),
            )
                == "Yesterday",
        )
    }

    @Test
    func sessionDateOmitsYearWhenSameYear() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = Date(timeIntervalSince1970: 1_712_345_678) // 2024-04-05
        let sameYear = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01
        let rendered = CatProfileFormatter.sessionDateString(
            epochSeconds: UInt64(sameYear.timeIntervalSince1970),
            relativeTo: reference,
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX"),
        )
        // Format is locale-templated; the assertion stays loose so a
        // future locale switch (e.g. en_GB "1 Jan") still passes,
        // but year and time-of-day must be absent.
        #expect(!rendered.contains("2024"))
        #expect(!rendered.contains(":"))
    }

    @Test
    func sessionDateIncludesYearWhenDifferentYear() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = Date(timeIntervalSince1970: 1_712_345_678) // 2024-04-05
        let priorYear = Date(timeIntervalSince1970: 1_672_531_200) // 2023-01-01
        let rendered = CatProfileFormatter.sessionDateString(
            epochSeconds: UInt64(priorYear.timeIntervalSince1970),
            relativeTo: reference,
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX"),
        )
        #expect(rendered.contains("2023"))
    }

    // MARK: - Cats summary

    @Test
    func catsSummaryEmptyListRendersUnknown() {
        #expect(
            CatProfileFormatter.sessionCatsSummary(catIDs: [], profiles: [])
                == HistoryStrings.sessionRowUnknownCat,
        )
    }

    @Test
    func catsSummarySingleResolvedNameRenders() {
        let profile = makeProfile(id: "cat-a", name: "Pancake")
        #expect(
            CatProfileFormatter.sessionCatsSummary(
                catIDs: ["cat-a"],
                profiles: [profile],
            )
                == "Pancake",
        )
    }

    @Test
    func catsSummarySingleUnresolvedRendersUnknownNotID() {
        // The raw cat id is a uuid; surfacing it would leak an
        // implementation detail to the user. The summary must fall
        // back to the localised "Unknown cat" label.
        let summary = CatProfileFormatter.sessionCatsSummary(
            catIDs: ["c4373f3c-1f0f-4c5e-b7ab-8b6eea2ab8d8"],
            profiles: [],
        )
        #expect(summary == HistoryStrings.sessionRowUnknownCat)
        #expect(!summary.contains("c4373f3c"))
    }

    @Test
    func catsSummaryMultipleAllResolvedJoins() {
        let profiles = [
            makeProfile(id: "cat-a", name: "Pancake"),
            makeProfile(id: "cat-b", name: "Waffle"),
        ]
        let summary = CatProfileFormatter.sessionCatsSummary(
            catIDs: ["cat-a", "cat-b"],
            profiles: profiles,
        )
        // Locale-dependent join; verify both names appear and the
        // raw uuids do not.
        #expect(summary.contains("Pancake"))
        #expect(summary.contains("Waffle"))
        #expect(!summary.contains("cat-a"))
        #expect(!summary.contains("cat-b"))
    }

    @Test
    func catsSummaryMultipleAllUnresolvedRendersAggregate() {
        // Two unresolved ids can't be made into a useful name list,
        // so the formatter falls back to the "Multiple cats" label.
        let summary = CatProfileFormatter.sessionCatsSummary(
            catIDs: ["uuid-1", "uuid-2"],
            profiles: [],
        )
        #expect(summary == HistoryStrings.sessionRowMultipleCats)
        #expect(!summary.contains("uuid"))
    }

    @Test
    func catsSummaryMixedResolvedAndUnresolvedShowsResolvedNames() {
        // If at least one name is resolvable, the summary surfaces
        // the names rather than collapsing to "Multiple cats" — the
        // unresolved entries are silently dropped because there's no
        // useful label for them.
        let profiles = [makeProfile(id: "cat-a", name: "Pancake")]
        let summary = CatProfileFormatter.sessionCatsSummary(
            catIDs: ["cat-a", "uuid-2"],
            profiles: profiles,
        )
        #expect(summary.contains("Pancake"))
        #expect(!summary.contains("uuid-2"))
    }

    // MARK: - Helpers

    private func makeProfile(id: String, name: String) -> Catlaser_App_V1_CatProfile {
        var profile = Catlaser_App_V1_CatProfile()
        profile.catID = id
        profile.name = name
        return profile
    }
}
