#if canImport(SwiftUI)
import SwiftUI

/// Stable identifiers the UI-test target (and the accessibility audit
/// task `just ios-check` surfaces in future) reaches for by name.
///
/// Each case spells out the logical screen and control in a single
/// token. Keeping them in an enum means a rename in code forces a
/// rename in the tests — there is no free-string drift where the test
/// suite and the view silently disagree on a key.
public enum AccessibilityID: String, Sendable, Hashable, CaseIterable {
    // Sign in
    case signInRoot = "signIn.root"
    case signInAppleButton = "signIn.button.apple"
    case signInGoogleButton = "signIn.button.google"
    case signInEmailButton = "signIn.button.email"
    case signInEmailField = "signIn.field.email"
    case signInEmailSubmit = "signIn.button.emailSubmit"
    case signInEmailCancel = "signIn.button.emailCancel"
    case signInErrorBanner = "signIn.banner.error"
    case signInErrorDismiss = "signIn.button.errorDismiss"
    case signInEmailSentResend = "signIn.button.resend"
    case signInEmailSentUseDifferent = "signIn.button.useDifferentEmail"

    // Pairing
    case pairingRoot = "pairing.root"
    case pairingManualField = "pairing.field.manualEntry"
    case pairingManualSubmit = "pairing.button.manualSubmit"
    case pairingScanInstead = "pairing.button.scanInstead"
    case pairingManualEntryToggle = "pairing.button.manualEntryToggle"
    case pairingTorchToggle = "pairing.button.torchToggle"
    case pairingPermissionRequest = "pairing.button.permissionRequest"
    case pairingOpenSettings = "pairing.button.openSettings"
    case pairingConfirmAccept = "pairing.button.confirmAccept"
    case pairingConfirmCancel = "pairing.button.confirmCancel"
    case pairingUnpair = "pairing.button.unpair"
    case pairingDismissError = "pairing.button.dismissError"
    case pairingRetry = "pairing.button.retry"

    // Live
    case liveRoot = "live.root"
    case liveWatchButton = "live.button.watch"
    case liveStopButton = "live.button.stop"
    case liveCancelConnectingButton = "live.button.cancelConnecting"
    case liveRetryButton = "live.button.retry"
    case liveDismissButton = "live.button.dismiss"
    case liveVideo = "live.video"

    // History
    case historyRoot = "history.root"
    case historyPaneSegment = "history.segment.pane"
    case historyCatRow = "history.row.cat"
    case historySessionRow = "history.row.session"
    case historyCatEdit = "history.button.catEdit"
    case historyCatDelete = "history.button.catDelete"
    case historyEditNameField = "history.field.editName"
    case historyEditSave = "history.button.editSave"
    case historyEditCancel = "history.button.editCancel"
    case historyNewCatNameField = "history.field.newCatName"
    case historyNewCatSave = "history.button.newCatSave"
    case historyNewCatDismiss = "history.button.newCatDismiss"
    case historyRetry = "history.button.retry"
    case historyDismissError = "history.button.dismissError"

    // Schedule
    case scheduleRoot = "schedule.root"
    case scheduleSaveButton = "schedule.button.save"
    case scheduleDiscardButton = "schedule.button.discard"
    case scheduleRefreshButton = "schedule.button.refresh"
    case scheduleAddButton = "schedule.button.add"
    case scheduleRetry = "schedule.button.retry"
    case scheduleDismissError = "schedule.button.dismissError"
    case scheduleEntryRow = "schedule.row.entry"
    case scheduleEntryEdit = "schedule.button.entryEdit"
    case scheduleEntryToggle = "schedule.toggle.entryEnabled"
    case scheduleEntrySheetSave = "schedule.button.entrySheetSave"
    case scheduleEntrySheetCancel = "schedule.button.entrySheetCancel"
    case scheduleEntrySheetDelete = "schedule.button.entrySheetDelete"

    // Push
    case pushRoot = "push.root"
    case pushPrimerAllow = "push.button.primerAllow"
    case pushOpenSettings = "push.button.openSettings"
    case pushRetry = "push.button.retry"

    // Consent
    case consentRoot = "consent.root"
    case consentCrashToggle = "consent.toggle.crash"
    case consentTelemetryToggle = "consent.toggle.telemetry"
    case consentContinue = "consent.button.continue"
}

public extension View {
    /// Attach a stable identifier for UI-test automation and the
    /// accessibility audit surface.
    func accessibilityID(_ id: AccessibilityID) -> some View {
        accessibilityIdentifier(id.rawValue)
    }

    /// Mark the receiver as an accessibility header — VoiceOver
    /// navigates heading-to-heading on a single swipe gesture, so
    /// every screen's title needs this trait for rotor navigation to
    /// work.
    func accessibilityHeader() -> some View {
        accessibilityAddTraits(.isHeader)
    }

    /// Apply a lower bound and an upper bound to Dynamic Type so the
    /// screen stays legible without breaking the layout at the
    /// extreme accessibility sizes. Apple's HIG recommends supporting
    /// every Dynamic Type size including the five accessibility
    /// sizes; in practice screen-level layouts that stack buttons and
    /// action banners break above `accessibility3`. Clamping to that
    /// ceiling keeps the text at the largest readable size the layout
    /// can absorb without clipping.
    ///
    /// This is the single knob every screen-level ``body`` applies at
    /// the root level. Cells and secondary controls inherit the
    /// environment so they automatically respect the same bounds.
    func catlaserDynamicTypeBounds() -> some View {
        dynamicTypeSize(.xSmall ... .accessibility3)
    }

    /// Attach a decorative-image marker. Combines ``accessibilityHidden``
    /// with ``accessibilityIgnoresInvertColors`` so the icon does not
    /// invert colours when the user enables Smart Invert (which is a
    /// Photo / Graphic protection setting). Decorative icons should
    /// always stay oriented; "invert everything but photos" is what
    /// Smart Invert means semantically.
    func accessibilityDecorativeIcon() -> some View {
        accessibilityHidden(true)
            .accessibilityIgnoresInvertColors(true)
    }
}

/// Convenience for conditionally honouring ``accessibilityReduceMotion``.
///
/// Callers pass their preferred animation; if the user has asked for
/// reduced motion (via Settings ▸ Accessibility ▸ Motion) the helper
/// returns `nil`, which suppresses the animation. SwiftUI's
/// `.animation(_:value:)` modifier treats `nil` as "no animation", so
/// the call site doesn't need to branch.
public enum CatLaserMotion {
    /// Return `animation` if the user permits motion; `nil` otherwise.
    /// The ``reduceMotion`` flag is supplied by the caller (read from
    /// `@Environment(\.accessibilityReduceMotion)`) rather than
    /// captured here so the helper stays a pure function and every
    /// view composes cleanly with SwiftUI's environment.
    public static func animation(
        _ animation: Animation,
        reduceMotion: Bool,
    ) -> Animation? {
        reduceMotion ? nil : animation
    }
}
#endif
