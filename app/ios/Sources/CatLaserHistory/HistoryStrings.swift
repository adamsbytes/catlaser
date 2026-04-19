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
        case let .deviceError(_, message):
            return message.isEmpty ? deviceGenericMessage : message
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
