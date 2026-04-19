import CatLaserProto
import Foundation

/// Loading state for the cat-profile list pane.
///
/// The cat list and the play history each load independently — refreshing
/// one does not block the other. Each pane therefore has its own state
/// machine. The states match what the UI must render: a spinner, a list,
/// or an error banner.
public enum CatProfilesState: Sendable, Equatable {
    /// Initial state before ``HistoryViewModel/start()`` runs. UI shows
    /// nothing (the host is responsible for the entry chrome until the
    /// VM resolves either ``loaded`` or ``failed``).
    case idle

    /// First load is in flight. UI shows a spinner with
    /// ``HistoryStrings/catListLoadingLabel``.
    case loading

    /// A list has been fetched. ``isRefreshing`` is true while a
    /// background re-fetch is in flight after a mutation or a manual
    /// pull-to-refresh — the UI keeps the previous list visible and
    /// overlays a small spinner rather than blanking the content.
    case loaded(profiles: [Catlaser_App_V1_CatProfile], isRefreshing: Bool)

    /// Last load attempt failed. UI shows the banner with the typed
    /// error and a "Try again" affordance that re-issues
    /// ``HistoryViewModel/refreshCats()``.
    case failed(HistoryError)

    public var isBusy: Bool {
        switch self {
        case .loading: true
        case let .loaded(_, isRefreshing): isRefreshing
        case .idle, .failed: false
        }
    }

    /// True when a tap on "Try again" / "Refresh" should be honoured.
    /// False while a load or refresh is already in flight so a
    /// double-tap cannot double-fire the device round-trip.
    public var canRefresh: Bool {
        switch self {
        case .idle, .loaded(_, false), .failed: true
        case .loading, .loaded(_, true): false
        }
    }

    public static func == (lhs: CatProfilesState, rhs: CatProfilesState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading):
            true
        case let (.loaded(lp, lr), .loaded(rp, rr)):
            lr == rr && lp == rp
        case let (.failed(le), .failed(re)):
            le == re
        default:
            false
        }
    }
}

/// Loading state for the play-history list pane. Mirrors the shape of
/// ``CatProfilesState`` so the UI can render both panes from a single
/// `switch`. The associated payload is a list of
/// ``Catlaser_App_V1_PlaySession`` rather than ``CatProfile`` and the
/// ``range`` of the load is captured so the pane knows what it's
/// displaying.
public enum PlayHistoryState: Sendable, Equatable {
    case idle
    case loading(range: ClosedRange<Date>)
    case loaded(
        sessions: [Catlaser_App_V1_PlaySession],
        range: ClosedRange<Date>,
        isRefreshing: Bool,
    )
    case failed(HistoryError, range: ClosedRange<Date>?)

    public var isBusy: Bool {
        switch self {
        case .loading: true
        case let .loaded(_, _, isRefreshing): isRefreshing
        case .idle, .failed: false
        }
    }

    public var canRefresh: Bool {
        switch self {
        case .idle, .loaded(_, _, false), .failed: true
        case .loading, .loaded(_, _, true): false
        }
    }

    public static func == (lhs: PlayHistoryState, rhs: PlayHistoryState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            true
        case let (.loading(lr), .loading(rr)):
            lr == rr
        case let (.loaded(ls, lr, lref), .loaded(rs, rr, rref)):
            lref == rref && lr == rr && ls == rs
        case let (.failed(le, lr), .failed(re, rr)):
            le == re && lr == rr
        default:
            false
        }
    }
}
