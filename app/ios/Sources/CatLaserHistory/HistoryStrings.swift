import Foundation

/// Localised strings for the history + cat profiles screen.
///
/// The pattern mirrors ``LiveViewStrings`` in ``CatLaserLive``: every
/// string has a stable ``NSLocalizedString`` key with an English
/// default and a short ``comment``. ``message(for:)`` resolves a
/// ``HistoryError`` to a single user-visible message; ``HistoryView``
/// renders the result verbatim. Tests assert that every error case
/// resolves to a non-empty string so a refactor that adds a new case
/// without a localisation row is caught.
public enum HistoryStrings {
    // MARK: - Top-level chrome

    public static let screenTitle = NSLocalizedString(
        "history.title",
        value: "Your cats",
        comment: "Navigation title for the history + cat profiles screen.",
    )

    public static let segmentCats = NSLocalizedString(
        "history.segment.cats",
        value: "Cats",
        comment: "Segmented control label for the cat-profile list tab.",
    )

    public static let segmentSessions = NSLocalizedString(
        "history.segment.sessions",
        value: "Sessions",
        comment: "Segmented control label for the play-history list tab.",
    )

    // MARK: - Cat list

    public static let catListEmptyTitle = NSLocalizedString(
        "history.cats.empty.title",
        value: "No cats yet",
        comment: "Empty-state title shown when no cat profiles exist on the device.",
    )

    public static let catListEmptySubtitle = NSLocalizedString(
        "history.cats.empty.subtitle",
        value: "Pair your device and start a play session — your cats will appear here once they've been seen.",
        comment: "Empty-state body shown when no cat profiles exist on the device.",
    )

    public static let catListLoadingLabel = NSLocalizedString(
        "history.cats.loading",
        value: "Loading cats…",
        comment: "Spinner label shown while the cat-profile list loads from the device.",
    )

    public static let skeletonAccessibility = NSLocalizedString(
        "history.skeleton.accessibility",
        value: "Loading content",
        comment: "VoiceOver label for the placeholder skeleton rows shown during list loading.",
    )

    public static let catRowEditButton = NSLocalizedString(
        "history.cats.row.edit",
        value: "Edit",
        comment: "Row action that opens the rename / edit sheet for a cat.",
    )

    public static let catRowDeleteButton = NSLocalizedString(
        "history.cats.row.delete",
        value: "Delete",
        comment: "Row action that removes a cat profile from the device.",
    )

    public static let catRowTapHint = NSLocalizedString(
        "history.cats.row.tap_hint",
        value: "Opens the edit sheet",
        comment: "VoiceOver hint announced after a cat row's label, describing what tapping the row does.",
    )

    public static let catRowDeleteConfirmTitle = NSLocalizedString(
        "history.cats.delete.title",
        value: "Remove this cat?",
        comment: "Confirmation dialog title before deleting a cat profile.",
    )

    public static let catRowDeleteConfirmBody = NSLocalizedString(
        "history.cats.delete.body",
        value: "Their play history will stay. New sightings will create a fresh profile.",
        comment: "Confirmation dialog body before deleting a cat profile.",
    )

    public static let catRowDeleteConfirmAction = NSLocalizedString(
        "history.cats.delete.confirm",
        value: "Remove",
        comment: "Destructive button that confirms cat-profile deletion.",
    )

    // MARK: - Edit sheet

    public static let editSheetTitle = NSLocalizedString(
        "history.edit.title",
        value: "Edit cat",
        comment: "Title of the cat-profile edit sheet.",
    )

    public static let editNameLabel = NSLocalizedString(
        "history.edit.name.label",
        value: "Name",
        comment: "Label for the cat-name text field on the edit sheet.",
    )

    public static let editNamePlaceholder = NSLocalizedString(
        "history.edit.name.placeholder",
        value: "e.g. Pancake",
        comment: "Placeholder for the cat-name text field.",
    )

    public static let editSaveButton = NSLocalizedString(
        "history.edit.save",
        value: "Save",
        comment: "Primary button on the cat-profile edit sheet.",
    )

    public static let editCancelButton = NSLocalizedString(
        "history.edit.cancel",
        value: "Cancel",
        comment: "Cancel button on the cat-profile edit sheet.",
    )

    // MARK: - Naming sheet (NewCatDetected)

    public static let namingSheetTitle = NSLocalizedString(
        "history.naming.title",
        value: "New cat seen",
        comment: "Title of the sheet that appears when an unknown cat was detected during a session.",
    )

    /// Title variant used when more than one ``NewCatDetected`` prompt
    /// is queued — the device reported multiple new cats in flight
    /// (either in a single session or because the user was away when
    /// several sessions ran back-to-back). The "X of Y" affordance
    /// prevents the user from thinking the sheet is buggy or looping
    /// when it re-presents on dismiss: they know they're on prompt N
    /// of M, so each dismiss is making forward progress.
    ///
    /// Positional args: queue index (1-based, matches what the user
    /// reads), queue total. The index-position format "%1$d of %2$d"
    /// is explicit so future localisations that need to reorder the
    /// numbers don't break the expansion.
    public static func namingSheetTitleWithQueue(index: Int, total: Int) -> String {
        let format = NSLocalizedString(
            "history.naming.title.with_queue",
            value: "New cat seen (%1$d of %2$d)",
            comment: "Title of the new-cat naming sheet when multiple cats are queued. Arg 1 is the current 1-based queue position; arg 2 is the total count.",
        )
        return String(format: format, index, total)
    }

    public static let namingSheetBody = NSLocalizedString(
        "history.naming.body",
        value: "Give this cat a name so we can recognise them next time.",
        comment: "Body copy on the new-cat naming sheet.",
    )

    public static let namingNameLabel = NSLocalizedString(
        "history.naming.name.label",
        value: "Name",
        comment: "Label for the name field on the new-cat naming sheet.",
    )

    public static let namingSaveButton = NSLocalizedString(
        "history.naming.save",
        value: "Add cat",
        comment: "Primary button on the new-cat naming sheet.",
    )

    public static let namingDismissButton = NSLocalizedString(
        "history.naming.dismiss",
        value: "Not now",
        comment: "Dismiss button on the new-cat naming sheet — defers naming until the user is ready.",
    )

    public static let namingThumbnailAccessibility = NSLocalizedString(
        "history.naming.thumbnail.accessibility",
        value: "Snapshot of the new cat",
        comment: "VoiceOver label for the thumbnail on the new-cat naming sheet.",
    )

    // MARK: - Session celebration sheet

    /// Headline rendered at the top of the post-session celebration
    /// sheet. Past tense rather than present (the session has just
    /// ended) and warm rather than clinical — this is the moment a
    /// cat owner waits for, not a status update.
    public static let celebrationTitle = NSLocalizedString(
        "history.celebration.title",
        value: "Great session!",
        comment: "Headline shown on the post-session celebration sheet that appears when a play session ends.",
    )

    /// Body copy when one named cat participated in the session.
    /// Positional arg 1 is the cat's display name; the verb is
    /// constant ("just played"). Past tense, matches the headline's
    /// just-ended framing.
    public static func celebrationBodySingleCat(name: String) -> String {
        let format = NSLocalizedString(
            "history.celebration.body.single",
            value: "%@ just played.",
            comment: "Body copy on the post-session celebration sheet when one named cat participated. Arg 1 is the cat's name.",
        )
        return String(format: format, name)
    }

    /// Body copy when multiple named cats participated in the session.
    /// Arg 1 is a pre-joined list of names ("Pancake and Waffle",
    /// "Pancake, Waffle, and Mochi") produced by the same join helper
    /// the session-row uses, so the wording matches what the user sees
    /// in History.
    public static func celebrationBodyMultipleCats(joinedNames: String) -> String {
        let format = NSLocalizedString(
            "history.celebration.body.multiple",
            value: "%@ just played.",
            comment: "Body copy on the post-session celebration sheet when multiple named cats participated. Arg 1 is the joined list of names.",
        )
        return String(format: format, joinedNames)
    }

    /// Fallback body copy when the session ended for an unknown cat
    /// (the device emitted a summary before any profile existed for
    /// the participating track). Keeps the celebration warm while
    /// acknowledging the lookup miss in plain language.
    public static let celebrationBodyUnknownCat = NSLocalizedString(
        "history.celebration.body.unknown",
        value: "A cat just played.",
        comment: "Body copy on the post-session celebration sheet when no cat name could be resolved.",
    )

    /// Stat-row label for the engagement bucket on the celebration
    /// sheet.
    public static let celebrationEngagementLabel = NSLocalizedString(
        "history.celebration.stat.engagement",
        value: "Engagement",
        comment: "Stat-row label for the engagement bucket on the post-session celebration sheet.",
    )

    /// Stat-row label for elapsed play time on the celebration sheet.
    public static let celebrationDurationLabel = NSLocalizedString(
        "history.celebration.stat.duration",
        value: "Play time",
        comment: "Stat-row label for elapsed play time on the post-session celebration sheet.",
    )

    /// Stat-row label for the pounce count on the celebration sheet.
    public static let celebrationPouncesLabel = NSLocalizedString(
        "history.celebration.stat.pounces",
        value: "Pounces",
        comment: "Stat-row label for the pounce count on the post-session celebration sheet.",
    )

    /// Stat-row label for the treats-dispensed count on the
    /// celebration sheet.
    public static let celebrationTreatsLabel = NSLocalizedString(
        "history.celebration.stat.treats",
        value: "Treats",
        comment: "Stat-row label for the treats-dispensed count on the post-session celebration sheet.",
    )

    /// Primary dismiss button on the celebration sheet.
    public static let celebrationDismissButton = NSLocalizedString(
        "history.celebration.dismiss",
        value: "Nice",
        comment: "Primary dismiss button on the post-session celebration sheet.",
    )

    // MARK: - History list

    public static let sessionsEmptyTitle = NSLocalizedString(
        "history.sessions.empty.title",
        value: "No play sessions yet",
        comment: "Empty-state title shown when the device has no recorded play sessions in the visible range.",
    )

    public static let sessionsEmptySubtitle = NSLocalizedString(
        "history.sessions.empty.subtitle",
        value: "Sessions will appear here once your cat has played.",
        comment: "Empty-state body shown when the device has no recorded play sessions.",
    )

    public static let sessionsLoadingLabel = NSLocalizedString(
        "history.sessions.loading",
        value: "Loading sessions…",
        comment: "Spinner label shown while play history loads from the device.",
    )

    public static let sessionRowMultipleCats = NSLocalizedString(
        "history.sessions.row.multiple_cats",
        value: "Multiple cats",
        comment: "Cat-list summary on a session row when more than one cat participated and no profile was named.",
    )

    public static let sessionRowUnknownCat = NSLocalizedString(
        "history.sessions.row.unknown_cat",
        value: "Unknown cat",
        comment: "Cat-list summary on a session row when the participating cat has no profile yet.",
    )

    // MARK: - Error / refresh chrome

    public static let refreshButton = NSLocalizedString(
        "history.refresh",
        value: "Refresh",
        comment: "Toolbar button that re-fetches cat profiles and play history from the device.",
    )

    public static let dismissButton = NSLocalizedString(
        "history.error.dismiss",
        value: "Dismiss",
        comment: "Dismiss button on the history-screen error banner.",
    )

    public static let retryButton = NSLocalizedString(
        "history.error.retry",
        value: "Try again",
        comment: "Retry button on the history-screen error banner.",
    )

    public static let errorBannerTitle = NSLocalizedString(
        "history.error.title",
        value: "Couldn't reach your device",
        comment: "Title for the error banner on the history screen.",
    )

    /// Render a ``HistoryError`` into a human-readable message. The
    /// underlying technical detail (server messages, OSStatus codes,
    /// Tailscale interface names) deliberately does NOT leak into the
    /// user-facing string — those values belong in logs, not banners.
    public static func message(for error: HistoryError) -> String {
        switch error {
        case .notConnected:
            return NSLocalizedString(
                "history.error.not_connected",
                value: "Your phone isn't connected to the device. Check that both are on the same network.",
                comment: "Error shown when the device TCP channel is closed.",
            )
        case .transportFailure:
            return NSLocalizedString(
                "history.error.transport",
                value: "The connection to your device dropped. Please try again.",
                comment: "Error shown when the device TCP channel errored mid-request.",
            )
        case .timeout:
            return NSLocalizedString(
                "history.error.timeout",
                value: "The device didn't respond in time. Please try again.",
                comment: "Error shown when a request timed out.",
            )
        case .deviceError:
            // The device-side message is a developer artefact — it
            // may carry internal Python tracebacks or protocol-level
            // diagnostic text the user has no use for. Surface the
            // stable generic copy and rely on observability for the
            // server-supplied detail.
            return deviceGenericMessage
        case .notFound:
            return NSLocalizedString(
                "history.error.not_found",
                value: "That cat is no longer on your device. Refreshing the list.",
                comment: "Error shown when the user acted on a cat that has already been removed device-side.",
            )
        case .wrongEventKind:
            return NSLocalizedString(
                "history.error.protocol",
                value: "The device returned an unexpected response. Please try again.",
                comment: "Error shown when the device's reply oneof did not match the request.",
            )
        case let .validation(reason):
            // The validation reason is generated in code (see
            // `HistoryViewModel.validateName(_:)`) and is itself a
            // localised, presentable string — surface verbatim.
            return reason
        case .internalFailure:
            return deviceGenericMessage
        }
    }

    private static let deviceGenericMessage = NSLocalizedString(
        "history.error.generic",
        value: "Something went wrong while contacting your device. Please try again.",
        comment: "Generic error message on the history screen.",
    )

    // MARK: - Validation messages

    public static let validationNameEmpty = NSLocalizedString(
        "history.validation.name.empty",
        value: "Please enter a name.",
        comment: "Validation message shown when the cat-name field is empty or whitespace-only.",
    )

    public static let validationNameTooLong = NSLocalizedString(
        "history.validation.name.too_long",
        value: "Name is too long.",
        comment: "Validation message shown when the cat-name field exceeds the maximum length.",
    )
}
