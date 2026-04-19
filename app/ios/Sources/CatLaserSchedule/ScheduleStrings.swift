import CatLaserProto
import Foundation

/// Localised strings + deterministic formatters for the schedule
/// screen.
///
/// Pattern mirrors ``CatLaserHistory.HistoryStrings``: every
/// user-facing string has a stable ``NSLocalizedString`` key with an
/// English default and a short ``comment``; ``message(for:)``
/// resolves a ``ScheduleError`` to a single user-visible sentence;
/// the formatter conveniences live here (rather than on
/// ``ScheduleEntryDraft``) so tests can pin the rendered output
/// without pulling the proto draft type into a formatting role it
/// shouldn't own.
///
/// Formatters accept an explicit ``Locale`` / ``Calendar`` so tests
/// can pin results; production call sites use the system defaults
/// which match the user's preferences.
public enum ScheduleStrings {
    // MARK: - Screen chrome

    public static let screenTitle = NSLocalizedString(
        "schedule.title",
        value: "Schedule",
        comment: "Navigation title for the auto-play schedule screen.",
    )

    public static let addButton = NSLocalizedString(
        "schedule.add",
        value: "Add time",
        comment: "Button that appends a fresh schedule entry.",
    )

    public static let saveButton = NSLocalizedString(
        "schedule.save",
        value: "Save",
        comment: "Toolbar button that commits the draft schedule to the device.",
    )

    public static let discardButton = NSLocalizedString(
        "schedule.discard",
        value: "Discard changes",
        comment: "Toolbar button that reverts the draft schedule to the server baseline.",
    )

    public static let refreshButton = NSLocalizedString(
        "schedule.refresh",
        value: "Refresh",
        comment: "Button that re-fetches the schedule from the device.",
    )

    public static let dismissButton = NSLocalizedString(
        "schedule.error.dismiss",
        value: "Dismiss",
        comment: "Dismiss button on the schedule-screen error banner.",
    )

    public static let retryButton = NSLocalizedString(
        "schedule.error.retry",
        value: "Try again",
        comment: "Retry button on the schedule-screen error banner.",
    )

    public static let errorBannerTitle = NSLocalizedString(
        "schedule.error.title",
        value: "Couldn't reach your device",
        comment: "Title for the error banner on the schedule screen.",
    )

    public static let loadingLabel = NSLocalizedString(
        "schedule.loading",
        value: "Loading schedule…",
        comment: "Spinner label shown while the schedule loads from the device.",
    )

    public static let skeletonAccessibility = NSLocalizedString(
        "schedule.loading.skeleton",
        value: "Loading your schedule",
        comment: "VoiceOver announcement while the schedule skeleton placeholder is visible.",
    )

    public static let savingLabel = NSLocalizedString(
        "schedule.saving",
        value: "Saving schedule…",
        comment: "Spinner label shown while a SetScheduleRequest is in flight.",
    )

    // MARK: - Empty state

    public static let emptyTitle = NSLocalizedString(
        "schedule.empty.title",
        value: "No scheduled times yet",
        comment: "Empty-state title when the device has no schedule entries.",
    )

    public static let emptySubtitle = NSLocalizedString(
        "schedule.empty.subtitle",
        value: "Add a time window and your cat laser will run automatically inside it.",
        comment: "Empty-state body explaining what schedule entries do.",
    )

    public static let quietHoursFootnote = NSLocalizedString(
        "schedule.footnote.quiet_hours",
        value: "Outside these windows the device stays quiet.",
        comment: "Explanatory footnote shown below a populated schedule list.",
    )

    public static let alwaysOnHint = NSLocalizedString(
        "schedule.footnote.always_on",
        value: "No windows set — the device may play whenever it detects your cat.",
        comment: "Explanatory footnote shown when no schedule entries exist.",
    )

    // MARK: - Entry sheet

    public static let entrySheetAddTitle = NSLocalizedString(
        "schedule.sheet.add.title",
        value: "New window",
        comment: "Sheet title when creating a fresh schedule entry.",
    )

    public static let entrySheetEditTitle = NSLocalizedString(
        "schedule.sheet.edit.title",
        value: "Edit window",
        comment: "Sheet title when editing an existing schedule entry.",
    )

    public static let entrySheetSave = NSLocalizedString(
        "schedule.sheet.save",
        value: "Done",
        comment: "Primary button on the entry sheet — commits to the draft, not the device.",
    )

    public static let entrySheetCancel = NSLocalizedString(
        "schedule.sheet.cancel",
        value: "Cancel",
        comment: "Cancel button on the entry sheet.",
    )

    public static let entrySheetDeleteButton = NSLocalizedString(
        "schedule.sheet.delete",
        value: "Delete window",
        comment: "Destructive button on the entry sheet.",
    )

    public static let entrySheetStartLabel = NSLocalizedString(
        "schedule.sheet.start.label",
        value: "Start",
        comment: "Label for the start-time picker on the entry sheet.",
    )

    public static let entrySheetDurationLabel = NSLocalizedString(
        "schedule.sheet.duration.label",
        value: "Duration",
        comment: "Label for the duration stepper on the entry sheet.",
    )

    public static let entrySheetDaysLabel = NSLocalizedString(
        "schedule.sheet.days.label",
        value: "Days",
        comment: "Label for the day toggles on the entry sheet.",
    )

    public static let entrySheetEveryDay = NSLocalizedString(
        "schedule.sheet.days.every",
        value: "Every day",
        comment: "Summary shown when all day toggles are off (empty set = every day).",
    )

    public static let entrySheetEnabledLabel = NSLocalizedString(
        "schedule.sheet.enabled.label",
        value: "Enabled",
        comment: "Label for the enabled switch on the entry sheet.",
    )

    // MARK: - Formatters

    /// Render a minutes-from-midnight value as a locale-appropriate
    /// wall-clock string ("8:00 AM", "20:45").
    ///
    /// Negative or out-of-range values are clamped to the visible
    /// 0–1439 domain so a malformed draft does not crash the row; the
    /// validation layer already refuses to commit such drafts.
    public static func timeOfDay(
        minute: Int,
        locale: Locale = .current,
        calendar: Calendar = .current,
    ) -> String {
        let clamped = max(0, min(minute, ScheduleValidation.maxStartMinute))
        var components = DateComponents()
        components.hour = clamped / 60
        components.minute = clamped % 60
        var calendar = calendar
        calendar.locale = locale
        let reference = calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter.string(from: reference)
    }

    /// Render a duration in minutes as "2h 15m", "45m", "1m".
    /// Clamps to the validated range (1–1440) for display; values
    /// outside that range are already refused by validation before
    /// any wire traffic, so rendering them sanely is a defensive
    /// courtesy.
    public static func durationLabel(minutes: Int) -> String {
        let clamped = max(
            ScheduleValidation.minDurationMinutes,
            min(minutes, ScheduleValidation.maxDurationMinutes),
        )
        let hours = clamped / 60
        let rem = clamped % 60
        if hours > 0, rem > 0 {
            return "\(hours)h \(rem)m"
        }
        if hours > 0 {
            return "\(hours)h"
        }
        return "\(rem)m"
    }

    /// Render the "days" summary on a schedule row. Empty set is
    /// surfaced as ``entrySheetEveryDay``; a seven-day selection
    /// collapses to the same string (they are semantically
    /// equivalent — "every day" vs "Mon, Tue, Wed, Thu, Fri, Sat,
    /// Sun" — and collapsing keeps the row short).
    public static func daysSummary(_ days: Set<Catlaser_App_V1_DayOfWeek>) -> String {
        if days.isEmpty || days.count == 7 {
            return entrySheetEveryDay
        }
        let order: [Catlaser_App_V1_DayOfWeek] = [
            .monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday,
        ]
        let weekdays: Set<Catlaser_App_V1_DayOfWeek> = [.monday, .tuesday, .wednesday, .thursday, .friday]
        let weekend: Set<Catlaser_App_V1_DayOfWeek> = [.saturday, .sunday]
        if days == weekdays {
            return NSLocalizedString(
                "schedule.format.days.weekdays",
                value: "Weekdays",
                comment: "Days-summary when Monday through Friday are selected.",
            )
        }
        if days == weekend {
            return NSLocalizedString(
                "schedule.format.days.weekends",
                value: "Weekends",
                comment: "Days-summary when Saturday and Sunday are selected.",
            )
        }
        return order
            .filter { days.contains($0) }
            .map(shortDayLabel(_:))
            .joined(separator: " ")
    }

    /// Short day label ("Mon", "Tue"). Used by ``daysSummary`` and
    /// by the entry sheet's toggle buttons. The ``.unspecified`` /
    /// unknown cases render as an empty string so a UI that
    /// accidentally rendered them would visibly malfunction rather
    /// than silently accept.
    public static func shortDayLabel(_ day: Catlaser_App_V1_DayOfWeek) -> String {
        switch day {
        case .monday:
            return NSLocalizedString("schedule.day.short.mon", value: "Mon", comment: "Short Monday label.")
        case .tuesday:
            return NSLocalizedString("schedule.day.short.tue", value: "Tue", comment: "Short Tuesday label.")
        case .wednesday:
            return NSLocalizedString("schedule.day.short.wed", value: "Wed", comment: "Short Wednesday label.")
        case .thursday:
            return NSLocalizedString("schedule.day.short.thu", value: "Thu", comment: "Short Thursday label.")
        case .friday:
            return NSLocalizedString("schedule.day.short.fri", value: "Fri", comment: "Short Friday label.")
        case .saturday:
            return NSLocalizedString("schedule.day.short.sat", value: "Sat", comment: "Short Saturday label.")
        case .sunday:
            return NSLocalizedString("schedule.day.short.sun", value: "Sun", comment: "Short Sunday label.")
        case .unspecified, .UNRECOGNIZED:
            return ""
        }
    }

    /// Full day label for the entry-sheet toggle rows.
    public static func fullDayLabel(_ day: Catlaser_App_V1_DayOfWeek) -> String {
        switch day {
        case .monday:
            return NSLocalizedString("schedule.day.full.mon", value: "Monday", comment: "Full Monday label.")
        case .tuesday:
            return NSLocalizedString("schedule.day.full.tue", value: "Tuesday", comment: "Full Tuesday label.")
        case .wednesday:
            return NSLocalizedString("schedule.day.full.wed", value: "Wednesday", comment: "Full Wednesday label.")
        case .thursday:
            return NSLocalizedString("schedule.day.full.thu", value: "Thursday", comment: "Full Thursday label.")
        case .friday:
            return NSLocalizedString("schedule.day.full.fri", value: "Friday", comment: "Full Friday label.")
        case .saturday:
            return NSLocalizedString("schedule.day.full.sat", value: "Saturday", comment: "Full Saturday label.")
        case .sunday:
            return NSLocalizedString("schedule.day.full.sun", value: "Sunday", comment: "Full Sunday label.")
        case .unspecified, .UNRECOGNIZED:
            return ""
        }
    }

    // MARK: - Error messages

    /// Render a ``ScheduleError`` into a user-visible sentence.
    /// Developer-facing details (server messages, low-level reason
    /// strings) deliberately do not leak into the UI — they belong
    /// in logs, not banners.
    public static func message(for error: ScheduleError) -> String {
        switch error {
        case .notConnected:
            return NSLocalizedString(
                "schedule.error.not_connected",
                value: "Your phone isn't connected to the device. Check that both are on the same network.",
                comment: "Error shown when the device TCP channel is closed.",
            )
        case .transportFailure:
            return NSLocalizedString(
                "schedule.error.transport",
                value: "The connection to your device dropped. Please try again.",
                comment: "Error shown when the device TCP channel errored mid-request.",
            )
        case .timeout:
            return NSLocalizedString(
                "schedule.error.timeout",
                value: "The device didn't respond in time. Refresh to make sure your changes saved.",
                comment: "Error shown when a request timed out — the write may still have landed.",
            )
        case let .deviceError(_, message):
            return message.isEmpty ? genericDeviceMessage : message
        case .wrongEventKind:
            return NSLocalizedString(
                "schedule.error.protocol",
                value: "The device returned an unexpected response. Please try again.",
                comment: "Error shown when the device's reply oneof did not match the request.",
            )
        case let .validation(failure):
            return validationMessage(for: failure)
        case .internalFailure:
            return genericDeviceMessage
        }
    }

    /// Rendered messages for ``ScheduleValidation/Failure``. Kept
    /// here (not on the ``Failure`` type) so the strings go through
    /// ``NSLocalizedString`` and the test suite can assert coverage
    /// in the same place it asserts the wire-error surface.
    public static func validationMessage(for failure: ScheduleValidation.Failure) -> String {
        switch failure {
        case .invalidEntryID:
            return NSLocalizedString(
                "schedule.validation.entry_id",
                value: "That schedule entry is missing an identifier. Delete it and add a new one.",
                comment: "Validation message for a draft entry with an empty or too-long id.",
            )
        case .startMinuteOutOfRange:
            return NSLocalizedString(
                "schedule.validation.start_out_of_range",
                value: "Start time must be between 12:00 AM and 11:59 PM.",
                comment: "Validation message when the start-minute is outside 0…1439.",
            )
        case .durationOutOfRange:
            return NSLocalizedString(
                "schedule.validation.duration_out_of_range",
                value: "Duration must be between 1 minute and 24 hours.",
                comment: "Validation message when the duration is outside 1…1440 minutes.",
            )
        case .invalidDay:
            return NSLocalizedString(
                "schedule.validation.invalid_day",
                value: "One of the selected days is not recognised. Please re-select the days.",
                comment: "Validation message when the days set contains an unknown enum value.",
            )
        case .duplicateEntryID:
            return NSLocalizedString(
                "schedule.validation.duplicate_id",
                value: "Two schedule entries share the same identifier. Delete the duplicate.",
                comment: "Validation message when two drafts collide on entry_id.",
            )
        case .tooManyEntries:
            return NSLocalizedString(
                "schedule.validation.too_many",
                value: "You have too many scheduled windows. Please remove a few before saving.",
                comment: "Validation message when the draft set exceeds the entry cap.",
            )
        }
    }

    private static let genericDeviceMessage = NSLocalizedString(
        "schedule.error.generic",
        value: "Something went wrong while contacting your device. Please try again.",
        comment: "Generic error message on the schedule screen.",
    )
}
