import Foundation

/// Loading state for the schedule setup screen.
///
/// A single state machine (unlike history's two-pane design) because
/// the schedule is one resource — one ``GetScheduleRequest`` load,
/// one ``SetScheduleRequest`` commit. ``isRefreshing`` piggybacks on
/// the ``loaded`` case to preserve the visible list during a
/// background reload; ``isSaving`` piggybacks the same way during a
/// commit.
public enum ScheduleViewState: Sendable, Equatable {
    /// Initial state before ``ScheduleViewModel/start()``. The host
    /// is responsible for any entry chrome until the VM resolves
    /// either ``loaded`` or ``failed``.
    case idle

    /// First load is in flight. UI shows the spinner with
    /// ``ScheduleStrings/loadingLabel``.
    case loading

    /// The server baseline + the user's in-progress draft have been
    /// resolved.
    ///
    /// ``isRefreshing`` is true while a background ``GET`` is in
    /// flight (the UI overlays a small spinner but keeps the list
    /// visible). ``isSaving`` is true while a ``SET`` is in flight
    /// (the UI disables the Save button, overlays a spinner, and
    /// keeps the draft values visible so the user can see what they
    /// committed).
    ///
    /// The two flags are independent so a user who hit Save can
    /// still see a background refresh indicator if one lands while
    /// the commit is still in flight — unusual, but the state space
    /// must cover it without dropping either signal.
    case loaded(
        draftSet: ScheduleDraftSet,
        isRefreshing: Bool,
        isSaving: Bool,
    )

    /// Last load attempt failed. The UI shows the error banner and
    /// a "Try again" button wired to
    /// ``ScheduleViewModel/refresh()``.
    case failed(ScheduleError)

    /// True while ANY wire operation is in flight — first load,
    /// background refresh, or save. Drives the screen-level
    /// "don't let the user tap Save twice" gate.
    public var isBusy: Bool {
        switch self {
        case .loading: true
        case let .loaded(_, isRefreshing, isSaving): isRefreshing || isSaving
        case .idle, .failed: false
        }
    }

    /// True when the refresh button / pull-to-refresh should be
    /// honoured. False while a load, refresh, or save is in
    /// flight so a double-tap cannot double-fire the round-trip.
    public var canRefresh: Bool {
        switch self {
        case .idle, .failed: true
        case .loading: false
        case let .loaded(_, isRefreshing, isSaving): !isRefreshing && !isSaving
        }
    }

    /// The latest draft set, if the state carries one. Returns
    /// ``nil`` in ``idle`` / ``loading`` / ``failed`` — the caller
    /// surfaces a loading chrome or empty state for those.
    public var draftSet: ScheduleDraftSet? {
        if case let .loaded(draftSet, _, _) = self {
            return draftSet
        }
        return nil
    }

    /// Convenience: ``true`` when the state is ``loaded`` AND the
    /// draft has diverged from the baseline. Drives the Save /
    /// Discard button enabled state.
    public var hasPendingChanges: Bool {
        draftSet?.isDirty ?? false
    }

    public static func == (lhs: ScheduleViewState, rhs: ScheduleViewState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading):
            true
        case let (.loaded(ld, lr, ls), .loaded(rd, rr, rs)):
            ld == rd && lr == rr && ls == rs
        case let (.failed(le), .failed(re)):
            le == re
        default:
            false
        }
    }
}
