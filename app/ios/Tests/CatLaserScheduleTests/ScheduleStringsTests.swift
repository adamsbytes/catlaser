import CatLaserProto
import Foundation
import Testing

@testable import CatLaserSchedule

/// Exhaustive localisation-surface checks for the schedule screen.
///
/// A refactor that adds a new ``ScheduleError`` case or a new
/// ``ScheduleValidation.Failure`` case without wiring a localised
/// string would otherwise ship to users as an empty banner. The
/// assertions here catch that before release.
@Suite("ScheduleStrings")
struct ScheduleStringsTests {
    /// Every error case the screen can surface.
    private let errorCases: [ScheduleError] = [
        .notConnected,
        .transportFailure("ECONNRESET"),
        .timeout,
        .deviceError(code: 42, message: "device boom"),
        .deviceError(code: 42, message: ""),
        .wrongEventKind(expected: "schedule", got: "status_update"),
        .validation(.invalidEntryID("")),
        .validation(.startMinuteOutOfRange(1_440)),
        .validation(.durationOutOfRange(0)),
        .validation(.invalidDay),
        .validation(.duplicateEntryID("a")),
        .validation(.tooManyEntries(100)),
        .internalFailure("client bug"),
    ]

    @Test
    func everyErrorCaseResolvesToNonEmptyMessage() {
        for error in errorCases {
            let message = ScheduleStrings.message(for: error)
            #expect(!message.isEmpty, "empty message for \(error)")
            switch error {
            case let .transportFailure(reason),
                 let .internalFailure(reason):
                #expect(
                    !message.contains(reason),
                    "user-facing message must not echo developer reason: \(message)",
                )
            default:
                break
            }
        }
    }

    @Test
    func deviceErrorMessagePrefersServerStringWhenPresent() {
        let withMessage = ScheduleStrings.message(for: .deviceError(code: 9, message: "something"))
        let withoutMessage = ScheduleStrings.message(for: .deviceError(code: 9, message: ""))
        #expect(withMessage == "something")
        #expect(!withoutMessage.isEmpty)
        #expect(withMessage != withoutMessage)
    }

    @Test
    func everyValidationFailureResolvesToNonEmptyMessage() {
        let failures: [ScheduleValidation.Failure] = [
            .invalidEntryID(""),
            .startMinuteOutOfRange(-1),
            .durationOutOfRange(0),
            .invalidDay,
            .duplicateEntryID("a"),
            .tooManyEntries(100),
        ]
        for failure in failures {
            let message = ScheduleStrings.validationMessage(for: failure)
            #expect(!message.isEmpty, "empty validation message for \(failure)")
        }
    }

    // MARK: - Time of day

    @Test
    func timeOfDayRendersMidnight() {
        // The first minute of the day in a locale-stable form.
        // Using the fixed UK locale avoids locale-drift across CI
        // runners.
        let locale = Locale(identifier: "en_GB")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let text = ScheduleStrings.timeOfDay(minute: 0, locale: locale, calendar: calendar)
        #expect(!text.isEmpty)
        // 24-hour locale renders 00:00.
        #expect(text.contains("00:00"))
    }

    @Test
    func timeOfDayRendersLateAfternoon() {
        let locale = Locale(identifier: "en_GB")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let text = ScheduleStrings.timeOfDay(minute: 17 * 60 + 30, locale: locale, calendar: calendar)
        #expect(text.contains("17:30"))
    }

    @Test
    func timeOfDayClampsOutOfRangeInputs() {
        // Above 1439 is illegal; the formatter must render SOMETHING
        // rather than crash.
        let locale = Locale(identifier: "en_GB")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let clampedHigh = ScheduleStrings.timeOfDay(minute: 10_000, locale: locale, calendar: calendar)
        let clampedLow = ScheduleStrings.timeOfDay(minute: -5, locale: locale, calendar: calendar)
        #expect(!clampedHigh.isEmpty)
        #expect(!clampedLow.isEmpty)
    }

    // MARK: - Duration label

    @Test
    func durationLabelFormatsMinutesOnly() {
        #expect(ScheduleStrings.durationLabel(minutes: 15) == "15m")
    }

    @Test
    func durationLabelFormatsExactHours() {
        #expect(ScheduleStrings.durationLabel(minutes: 120) == "2h")
    }

    @Test
    func durationLabelFormatsHoursAndMinutes() {
        #expect(ScheduleStrings.durationLabel(minutes: 135) == "2h 15m")
    }

    @Test
    func durationLabelClampsOutOfRange() {
        // Negative / over-cap inputs still render — the validator
        // is the enforcement gate; the formatter's job is to be
        // crash-free.
        let low = ScheduleStrings.durationLabel(minutes: 0)
        let high = ScheduleStrings.durationLabel(minutes: 10_000)
        #expect(low == "1m")
        #expect(high == "24h")
    }

    // MARK: - Days summary

    @Test
    func daysSummaryEmptyRendersAsEveryDay() {
        let summary = ScheduleStrings.daysSummary([])
        #expect(summary == ScheduleStrings.entrySheetEveryDay)
    }

    @Test
    func daysSummaryAllSevenCollapsesToEveryDay() {
        let all: Set<Catlaser_App_V1_DayOfWeek> = [
            .monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday,
        ]
        #expect(ScheduleStrings.daysSummary(all) == ScheduleStrings.entrySheetEveryDay)
    }

    @Test
    func daysSummaryWeekdaysCollapsesToWeekdays() {
        let weekdays: Set<Catlaser_App_V1_DayOfWeek> = [
            .monday, .tuesday, .wednesday, .thursday, .friday,
        ]
        let summary = ScheduleStrings.daysSummary(weekdays)
        #expect(summary == "Weekdays")
    }

    @Test
    func daysSummaryWeekendsCollapsesToWeekends() {
        let weekend: Set<Catlaser_App_V1_DayOfWeek> = [.saturday, .sunday]
        #expect(ScheduleStrings.daysSummary(weekend) == "Weekends")
    }

    @Test
    func daysSummaryEnumeratesOddSubset() {
        let mwf: Set<Catlaser_App_V1_DayOfWeek> = [.monday, .wednesday, .friday]
        let summary = ScheduleStrings.daysSummary(mwf)
        #expect(summary.contains("Mon"))
        #expect(summary.contains("Wed"))
        #expect(summary.contains("Fri"))
        // Order is Mon → Sun.
        let monPos = summary.range(of: "Mon")!.lowerBound
        let wedPos = summary.range(of: "Wed")!.lowerBound
        let friPos = summary.range(of: "Fri")!.lowerBound
        #expect(monPos < wedPos)
        #expect(wedPos < friPos)
    }

    @Test
    func dayLabelShortAndFullNonEmptyForKnownDays() {
        let known: [Catlaser_App_V1_DayOfWeek] = [
            .monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday,
        ]
        for day in known {
            #expect(!ScheduleStrings.shortDayLabel(day).isEmpty)
            #expect(!ScheduleStrings.fullDayLabel(day).isEmpty)
        }
    }

    @Test
    func dayLabelEmptyForUnknownOrUnspecified() {
        #expect(ScheduleStrings.shortDayLabel(.unspecified).isEmpty)
        #expect(ScheduleStrings.fullDayLabel(.UNRECOGNIZED(99)).isEmpty)
    }
}
