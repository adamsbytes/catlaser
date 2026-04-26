import CatLaserDevice
import CatLaserProto
import Foundation
import Observation

/// Observable view model backing the history + cat profiles screen.
///
/// Responsibilities:
///
/// 1. Drive two independent state machines (``CatProfilesState`` and
///    ``PlayHistoryState``) so the cat list and play history can load
///    and refresh independently.
/// 2. Own the request/response round-trips for the cat-profile and
///    play-history app-protocol surface (``GetCatProfilesRequest``,
///    ``UpdateCatProfileRequest``, ``DeleteCatProfileRequest``,
///    ``GetPlayHistoryRequest``, ``IdentifyNewCatRequest``).
/// 3. Watch the ``DeviceClient/events`` stream for unsolicited
///    ``NewCatDetected`` pushes and queue them as ``NewCatPrompt``
///    values so the screen can surface a naming sheet.
/// 4. Validate user input (cat names) before any wire traffic to
///    surface field-level hints without burning an attestation /
///    request id on a known-bad call.
///
/// ## Reentrancy
///
/// Every public action consults the relevant pane's ``canRefresh`` /
/// ``isBusy`` flag before issuing a wire call. A double-tap on
/// "Refresh", a second submit on the edit sheet, or a duplicate
/// delete are dropped on the floor — we never kick off two concurrent
/// requests that would race each other and double-update the list.
///
/// ## Threading
///
/// Marked ``@MainActor`` so every state mutation runs on the main
/// thread. ``DeviceClient`` is an actor; the VM awaits into it and
/// hops back. The events-watch task is captured as ``eventsTask`` and
/// cancelled in ``stop()``.
///
/// ## Event stream consumption
///
/// Unsolicited events reach the VM through a ``DeviceEventBroker``
/// subscription, not via direct ``DeviceClient/events`` iteration.
/// The broker is the composition's single consumer of the device's
/// event stream and fans out to every view model that needs
/// ``NewCatDetected`` (this VM), ``StatusUpdate`` (the live-view
/// overlay), and the other unsolicited event types. The VM registers
/// one subscription per ``start()`` and cancels it in ``stop()``.
@MainActor
@Observable
public final class HistoryViewModel {
    // MARK: - Public state

    public private(set) var catsState: CatProfilesState = .idle
    public private(set) var historyState: PlayHistoryState = .idle

    /// FIFO queue of unresolved naming prompts. The head is what the
    /// UI surfaces as a sheet; ``identifyNewCat(prompt:name:)`` and
    /// ``dismissNewCatPrompt(_:)`` pop the matched entry.
    public private(set) var pendingNewCats: [NewCatPrompt] = []

    /// Most recent unsolicited ``SessionSummary`` the device has
    /// emitted while this VM was alive, awaiting the user's
    /// acknowledgement. The UI surfaces this as a one-shot
    /// celebration sheet that congratulates the owner on their cat's
    /// just-finished session and surfaces the headline stats —
    /// engagement bucket, pounces, treats, duration.
    ///
    /// Most-recent-wins rather than a queue: sessions are several
    /// minutes long, so a back-to-back overlap is rare; when it does
    /// happen, the user most likely cares about the latest one. The
    /// queue tradeoff that matters for ``NewCatDetected`` (each cat
    /// is a distinct identity that has to be named individually)
    /// does not apply here. Cleared by
    /// ``dismissSessionCelebration()`` when the user taps "Nice".
    public private(set) var pendingSessionCelebration: Catlaser_App_V1_SessionSummary?

    /// Last error surfaced for an in-flight mutation (update name,
    /// delete, identify-new). Distinct from the per-pane ``failed``
    /// state because a transient failure on a delete should not blank
    /// the cat list. `nil` when no banner should show. The UI
    /// presents this as a transient toast / banner; the user can
    /// dismiss via ``dismissActionError()``.
    public private(set) var lastActionError: HistoryError?

    // MARK: - Configuration

    /// Maximum number of UTF-8 *characters* a cat name may contain.
    /// Caps the field length so a runaway paste does not produce a
    /// device-side rejection that the user has no good way to
    /// recover from. The device side does not impose its own length
    /// cap, so this is the only enforcement.
    public static let maxNameLength = 60

    /// Default play-history range when ``start()`` does its initial
    /// load. 30 days back from "now" — wide enough to populate the
    /// list on a first launch, narrow enough that the device
    /// round-trip stays sub-second.
    public static let defaultHistoryWindow: TimeInterval = 30 * 24 * 60 * 60

    // MARK: - Dependencies

    /// The device control channel. ``var`` rather than ``let`` so a
    /// supervisor reconnect on the SAME paired device can swap in a
    /// fresh client without throwing away the user-visible cat list and
    /// the queued ``NewCatPrompt``s. See
    /// ``swapDeviceClient(_:eventBroker:)``.
    private var deviceClient: DeviceClient
    /// Currently-attached event broker. ``var`` for the same reason as
    /// ``deviceClient`` — a fresh broker is built per supervisor cycle
    /// and the VM has to re-bind on swap.
    private var eventBroker: DeviceEventBroker?
    private let clock: @Sendable () -> Date

    // MARK: - Internal state

    /// Long-running task that consumes the broker's fanout
    /// subscription for unsolicited ``NewCatDetected`` pushes.
    /// Cancelled in ``stop()``.
    private var eventsTask: Task<Void, Never>?

    public init(
        deviceClient: DeviceClient,
        eventBroker: DeviceEventBroker? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.deviceClient = deviceClient
        self.eventBroker = eventBroker
        self.clock = clock
    }

    // No deinit: ``HistoryViewModel`` is ``@MainActor`` so
    // ``eventsTask`` is MainActor-isolated and cannot be touched from
    // deinit. The task is cancelled explicitly in ``stop()``; the
    // ``[weak self]`` capture means an orphaned task exits as soon as
    // the VM is collected.

    // MARK: - Lifecycle

    /// Called when the screen first appears. Kicks the initial cat
    /// list load and the initial 30-day history window in parallel,
    /// and starts watching unsolicited events for ``NewCatDetected``
    /// pushes.
    ///
    /// Idempotent: re-calling from a host that re-mounts the screen is
    /// a no-op for the events watcher (only ever spawned once) and
    /// re-issues the load only when the panes are in ``idle`` /
    /// ``failed``.
    public func start() async {
        startEventsWatcherIfNeeded()
        async let cats: Void = refreshCats()
        async let history: Void = loadHistory(range: defaultHistoryRange())
        _ = await (cats, history)
    }

    /// Cancel the events watcher. Hosting code calls this when the
    /// screen is permanently dismissed (sign-out, re-pair). It is
    /// safe to call multiple times.
    public func stop() {
        eventsTask?.cancel()
        eventsTask = nil
    }

    /// Replace the device control channel and the unsolicited-event
    /// broker without throwing away the loaded cat list, the loaded
    /// play history, or the queued ``NewCatPrompt`` sheets.
    ///
    /// Called by the host's connection-supervisor reconcile loop when
    /// a fresh transport lands against the SAME paired device (e.g.
    /// after a brief network blip). The previous broker is the
    /// caller's responsibility to ``stop()``; this method does not own
    /// its lifecycle.
    public func swapDeviceClient(
        _ newClient: DeviceClient,
        eventBroker newBroker: DeviceEventBroker,
    ) {
        deviceClient = newClient
        eventBroker = newBroker
        // Re-bind the unsolicited-event subscription against the new
        // broker. The previous task is cancelled so its for-await loop
        // exits cleanly when the old broker stops; a fresh task picks
        // up against the new broker on the next event.
        eventsTask?.cancel()
        eventsTask = nil
        startEventsWatcherIfNeeded()
    }

    // MARK: - Cat profiles

    /// Re-fetch the cat-profile list from the device. Honours the
    /// pane's reentrancy gate: a refresh while another is already in
    /// flight is dropped on the floor.
    public func refreshCats() async {
        guard catsState.canRefresh else { return }
        // Preserve the prior list as a "soft refresh" if we have one,
        // so the UI doesn't blank on a pull-to-refresh.
        let priorProfiles: [Catlaser_App_V1_CatProfile]?
        if case let .loaded(profiles, _) = catsState {
            priorProfiles = profiles
            catsState = .loaded(profiles: profiles, isRefreshing: true)
        } else {
            priorProfiles = nil
            catsState = .loading
        }

        var request = Catlaser_App_V1_AppRequest()
        request.getCatProfiles = Catlaser_App_V1_GetCatProfilesRequest()
        do {
            let event = try await deviceClient.request(request)
            let list = try unwrapCatProfileList(event)
            catsState = .loaded(profiles: list.profiles, isRefreshing: false)
        } catch let error as HistoryError {
            catsState = restored(priorProfiles: priorProfiles, on: error)
        } catch let error as DeviceClientError {
            catsState = restored(priorProfiles: priorProfiles, on: HistoryError.from(error))
        } catch {
            catsState = restored(
                priorProfiles: priorProfiles,
                on: .internalFailure(error.localizedDescription),
            )
        }
    }

    /// Update the display name on a cat profile. Trims and validates
    /// the candidate name; on success the device returns a refreshed
    /// list which is plumbed straight into ``catsState``.
    ///
    /// The wire request carries the FULL existing profile (so per-cat
    /// behaviour parameters do not get clobbered by an update that
    /// only meant to rename). Callers therefore pass the existing
    /// profile object verbatim.
    ///
    /// The list is updated **optimistically** the moment validation
    /// passes: the renamed profile is patched into ``catsState``
    /// before the device round-trip begins so the user sees the new
    /// name immediately. The eventual device echo replaces the local
    /// snapshot once it lands; on error the local snapshot is rolled
    /// back to the pre-mutation list so the UI converges on the
    /// device's truth instead of stranding a stale rename.
    @discardableResult
    public func updateCatName(
        _ profile: Catlaser_App_V1_CatProfile,
        newName: String,
    ) async -> Result<Void, HistoryError> {
        let trimmed: String
        switch validateName(newName) {
        case let .success(value):
            trimmed = value
        case let .failure(error):
            lastActionError = error
            return .failure(error)
        }

        var mutated = profile
        mutated.name = trimmed
        var request = Catlaser_App_V1_AppRequest()
        var update = Catlaser_App_V1_UpdateCatProfileRequest()
        update.profile = mutated
        request.updateCatProfile = update

        let rollback = applyOptimisticCatUpdate(catID: profile.catID, mutated: mutated)
        return await sendCatMutation(
            request: request,
            blamedCatID: profile.catID,
            rollback: rollback,
        )
    }

    /// Remove a cat profile from the device. The device handler is
    /// idempotent; re-issuing on a missing row is a no-op so a retry
    /// after a transient failure is safe. On success the device
    /// echoes the freshly-truncated cat list, which is plumbed into
    /// ``catsState``.
    ///
    /// The list is updated **optimistically** before the round-trip:
    /// the row is removed from ``catsState`` immediately so the user
    /// sees the deletion land. On error the local snapshot is rolled
    /// back to the pre-mutation list, converging on the device's
    /// truth without leaving a stale "deleted" row hanging in the UI.
    @discardableResult
    public func deleteCat(catID: String) async -> Result<Void, HistoryError> {
        var request = Catlaser_App_V1_AppRequest()
        var delete = Catlaser_App_V1_DeleteCatProfileRequest()
        delete.catID = catID
        request.deleteCatProfile = delete
        let rollback = applyOptimisticCatRemoval(catID: catID)
        return await sendCatMutation(
            request: request,
            blamedCatID: catID,
            rollback: rollback,
        )
    }

    // MARK: - Naming UX

    /// Resolve a pending ``NewCatPrompt`` by submitting a name to the
    /// device. On success the prompt is removed from the queue and
    /// the cat list is refreshed (the device emits the freshly-named
    /// cat as a new ``CatProfile``). On a typed `NOT_FOUND` from the
    /// device the prompt is also removed (the pending track has
    /// already been resolved or expired) but the action error
    /// records the diagnostic so the UI can surface a hint.
    @discardableResult
    public func identifyNewCat(
        _ prompt: NewCatPrompt,
        name: String,
    ) async -> Result<Void, HistoryError> {
        let trimmed: String
        switch validateName(name) {
        case let .success(value):
            trimmed = value
        case let .failure(error):
            lastActionError = error
            return .failure(error)
        }

        var request = Catlaser_App_V1_AppRequest()
        var identify = Catlaser_App_V1_IdentifyNewCatRequest()
        identify.trackIDHint = prompt.trackIDHint
        identify.name = trimmed
        request.identifyNewCat = identify

        do {
            let event = try await deviceClient.request(request)
            let list = try unwrapCatProfileList(event)
            removePendingPrompt(trackIDHint: prompt.trackIDHint)
            catsState = .loaded(profiles: list.profiles, isRefreshing: false)
            lastActionError = nil
            return .success(())
        } catch let error as HistoryError {
            return surfaceMutationError(error, droppingPrompt: prompt.trackIDHint)
        } catch let error as DeviceClientError {
            return surfaceMutationError(.from(error), droppingPrompt: prompt.trackIDHint)
        } catch {
            let mapped = HistoryError.internalFailure(error.localizedDescription)
            lastActionError = mapped
            return .failure(mapped)
        }
    }

    /// Dismiss a pending naming prompt without naming the cat. The
    /// prompt is removed from the queue; if the device redetects the
    /// same track later (it tracks a hash of the embedding) a fresh
    /// prompt may arrive on the events stream.
    public func dismissNewCatPrompt(_ trackIDHint: UInt32) {
        removePendingPrompt(trackIDHint: trackIDHint)
    }

    /// Dismiss the post-session celebration sheet. The view's sheet
    /// binding observes ``pendingSessionCelebration`` and dismisses
    /// when this clears. A subsequent ``SessionSummary`` event mints
    /// a fresh celebration; this method is a one-shot acknowledgement
    /// of the current one only.
    public func dismissSessionCelebration() {
        pendingSessionCelebration = nil
    }

    // MARK: - Play history

    /// Load the play-history list for the supplied range. Re-issues
    /// the load with the supplied range even when the pane is already
    /// `.loaded` (so the UI's date-picker can drive a re-query); the
    /// reentrancy gate refuses concurrent loads so a quickly-changed
    /// range does not produce overlapping requests.
    public func loadHistory(range: ClosedRange<Date>) async {
        guard historyState.canRefresh else { return }

        let priorSessions: [Catlaser_App_V1_PlaySession]?
        if case let .loaded(sessions, currentRange, _) = historyState, currentRange == range {
            priorSessions = sessions
            historyState = .loaded(sessions: sessions, range: range, isRefreshing: true)
        } else {
            priorSessions = nil
            historyState = .loading(range: range)
        }

        var request = Catlaser_App_V1_AppRequest()
        var query = Catlaser_App_V1_GetPlayHistoryRequest()
        query.startTime = epochSeconds(from: range.lowerBound)
        query.endTime = epochSeconds(from: range.upperBound)
        request.getPlayHistory = query

        do {
            let event = try await deviceClient.request(request)
            let response = try unwrapPlayHistory(event)
            historyState = .loaded(sessions: response.sessions, range: range, isRefreshing: false)
        } catch let error as HistoryError {
            historyState = restored(priorSessions: priorSessions, range: range, on: error)
        } catch let error as DeviceClientError {
            historyState = restored(priorSessions: priorSessions, range: range, on: HistoryError.from(error))
        } catch {
            historyState = restored(
                priorSessions: priorSessions,
                range: range,
                on: .internalFailure(error.localizedDescription),
            )
        }
    }

    /// Re-issue the most recent history range. No-op if no range has
    /// been loaded yet (the host calls ``loadHistory(range:)`` for
    /// first load).
    public func refreshHistory() async {
        let range: ClosedRange<Date>
        switch historyState {
        case let .loaded(_, currentRange, _):
            range = currentRange
        case let .failed(_, currentRange?):
            range = currentRange
        case let .loading(currentRange):
            range = currentRange
        case .idle, .failed(_, nil):
            range = defaultHistoryRange()
        }
        await loadHistory(range: range)
    }

    // MARK: - Error chrome

    /// Dismiss the action-level error banner.
    public func dismissActionError() {
        lastActionError = nil
    }

    // MARK: - Validation

    /// Trim and validate a candidate cat name. Public so the edit /
    /// naming sheets can light up a "Save" button only when the input
    /// is acceptable, without round-tripping through the
    /// ``updateCatName`` / ``identifyNewCat`` mutators.
    public static func validateName(_ raw: String) -> Result<String, HistoryError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .failure(.validation(HistoryStrings.validationNameEmpty))
        }
        if trimmed.count > maxNameLength {
            return .failure(.validation(HistoryStrings.validationNameTooLong))
        }
        return .success(trimmed)
    }

    /// Instance-level shim so callers that already hold a ``self``
    /// don't need to reach for the static.
    public func validateName(_ raw: String) -> Result<String, HistoryError> {
        Self.validateName(raw)
    }

    // MARK: - Private: cat-mutation common path

    /// Apply the optimistic rename in-place and return a rollback
    /// closure that restores the pre-mutation snapshot.
    ///
    /// Returns ``nil`` when the pane is not in a ``loaded`` state or
    /// the cat is not present — in that case the optimistic patch is
    /// a no-op (the device echo will reconcile on success and the
    /// error banner is the only feedback on failure).
    private func applyOptimisticCatUpdate(
        catID: String,
        mutated: Catlaser_App_V1_CatProfile,
    ) -> (@MainActor () -> Void)? {
        guard case let .loaded(profiles, isRefreshing) = catsState else { return nil }
        guard let index = profiles.firstIndex(where: { $0.catID == catID }) else { return nil }
        let snapshot = profiles
        var updated = profiles
        updated[index] = mutated
        catsState = .loaded(profiles: updated, isRefreshing: isRefreshing)
        return { [weak self] in
            guard let self else { return }
            // Roll back only if the user hasn't been served a fresh
            // device echo in the meantime — otherwise we'd undo the
            // device's truth and immediately diverge.
            if case let .loaded(currentProfiles, currentRefreshing) = self.catsState,
               currentProfiles == updated
            {
                self.catsState = .loaded(profiles: snapshot, isRefreshing: currentRefreshing)
            }
        }
    }

    /// Apply the optimistic delete and return a rollback closure that
    /// restores the removed row at its prior position.
    ///
    /// Returns ``nil`` when the pane is not in a ``loaded`` state or
    /// the row is already absent — in that case the wire request is
    /// still issued (delete is idempotent) but no local mutation
    /// needs reverting.
    private func applyOptimisticCatRemoval(catID: String) -> (@MainActor () -> Void)? {
        guard case let .loaded(profiles, isRefreshing) = catsState else { return nil }
        guard let index = profiles.firstIndex(where: { $0.catID == catID }) else { return nil }
        let snapshot = profiles
        var updated = profiles
        updated.remove(at: index)
        catsState = .loaded(profiles: updated, isRefreshing: isRefreshing)
        return { [weak self] in
            guard let self else { return }
            if case let .loaded(currentProfiles, currentRefreshing) = self.catsState,
               currentProfiles == updated
            {
                self.catsState = .loaded(profiles: snapshot, isRefreshing: currentRefreshing)
            }
        }
    }

    private func sendCatMutation(
        request: Catlaser_App_V1_AppRequest,
        blamedCatID: String,
        rollback: (@MainActor () -> Void)? = nil,
    ) async -> Result<Void, HistoryError> {
        do {
            let event = try await deviceClient.request(request)
            let list = try unwrapCatProfileList(event)
            catsState = .loaded(profiles: list.profiles, isRefreshing: false)
            lastActionError = nil
            return .success(())
        } catch let error as HistoryError {
            rollback?()
            return surfaceCatMutationError(error, blamedCatID: blamedCatID)
        } catch let error as DeviceClientError {
            rollback?()
            return surfaceCatMutationError(HistoryError.from(error), blamedCatID: blamedCatID)
        } catch {
            rollback?()
            let mapped = HistoryError.internalFailure(error.localizedDescription)
            lastActionError = mapped
            return .failure(mapped)
        }
    }

    /// Common error-surface for delete / update mutations. A typed
    /// `NOT_FOUND` triggers an opportunistic background refresh so
    /// the UI converges on the device's truth without the user
    /// having to retry.
    private func surfaceCatMutationError(
        _ error: HistoryError,
        blamedCatID _: String,
    ) -> Result<Void, HistoryError> {
        lastActionError = error
        if case .notFound = error {
            Task { [weak self] in
                await self?.refreshCats()
            }
        }
        return .failure(error)
    }

    /// Mirror of ``surfaceCatMutationError`` for the identify-new
    /// path. The pending prompt is dropped on `NOT_FOUND` (the
    /// device no longer has the embedding so re-trying with the
    /// same hint is guaranteed to fail again).
    private func surfaceMutationError(
        _ error: HistoryError,
        droppingPrompt trackIDHint: UInt32,
    ) -> Result<Void, HistoryError> {
        lastActionError = error
        if case .notFound = error {
            removePendingPrompt(trackIDHint: trackIDHint)
        }
        return .failure(error)
    }

    // MARK: - Private: events watcher

    private func startEventsWatcherIfNeeded() {
        guard eventsTask == nil else { return }
        // Prefer the broker's fanout subscription so multiple VMs can
        // observe the device's unsolicited event surface without
        // racing the single-consumer contract on ``DeviceClient/events``.
        // When no broker is wired (legacy test rigs that pre-date the
        // broker), fall back to the direct events stream — the SPM
        // tests that use this fallback are single-VM by construction.
        if let eventBroker {
            let subscription = eventBroker.events()
            eventsTask = Task { [weak self] in
                for await event in subscription {
                    guard !Task.isCancelled else { return }
                    await self?.handleUnsolicited(event)
                }
            }
        } else {
            eventsTask = Task { [weak self, deviceClient] in
                let stream = deviceClient.events
                for await event in stream {
                    guard !Task.isCancelled else { return }
                    await self?.handleUnsolicited(event)
                }
            }
        }
    }

    private func handleUnsolicited(_ event: Catlaser_App_V1_DeviceEvent) async {
        guard event.requestID == 0 else { return }
        switch event.event {
        case let .newCatDetected(payload):
            enqueueNewCatPrompt(
                NewCatPrompt(
                    trackIDHint: payload.trackIDHint,
                    thumbnail: payload.thumbnail,
                    confidence: payload.confidence,
                ),
            )
        case let .sessionSummary(summary):
            // Most-recent-wins celebration. A second summary landing
            // before the user has acknowledged the first replaces the
            // pending one — back-to-back sessions are rare in
            // practice, and the user's expectation is "show me the
            // latest play" rather than "queue them up." The view's
            // sheet binding observes this property and presents
            // automatically on assignment; ``dismissSessionCelebration``
            // clears it after the user taps acknowledge.
            //
            // Side-effect refresh of the session list so the row that
            // matches the celebration appears in History when the
            // user dismisses the sheet. Fire-and-forget — the
            // ``canRefresh`` gate coalesces with any concurrent
            // refresh; failing transparently here is correct because
            // the celebration itself does not depend on the list.
            pendingSessionCelebration = summary
            Task { [weak self] in
                await self?.refreshHistory()
            }
        default:
            // Other unsolicited events (status updates, hopper
            // alerts, diagnostics) are owned by other VMs and ignored
            // here. Letting them flow past keeps the events stream a
            // single-consumer surface.
            return
        }
    }

    private func enqueueNewCatPrompt(_ prompt: NewCatPrompt) {
        // Collapse duplicates for the same track id (the device may
        // re-push when a track resumes after coasting). The newer
        // payload — newer thumbnail, possibly updated confidence —
        // wins, but the queue position is preserved so the user
        // is not surprised by a sheet jumping to the front.
        if let index = pendingNewCats.firstIndex(where: { $0.trackIDHint == prompt.trackIDHint }) {
            pendingNewCats[index] = prompt
        } else {
            pendingNewCats.append(prompt)
        }
    }

    private func removePendingPrompt(trackIDHint: UInt32) {
        pendingNewCats.removeAll { $0.trackIDHint == trackIDHint }
    }

    // MARK: - Private: response parsing

    private func unwrapCatProfileList(
        _ event: Catlaser_App_V1_DeviceEvent,
    ) throws -> Catlaser_App_V1_CatProfileList {
        if case let .catProfileList(list) = event.event {
            return list
        }
        throw HistoryError.wrongEventKind(
            expected: "cat_profile_list",
            got: event.event?.shortName ?? "unspecified",
        )
    }

    private func unwrapPlayHistory(
        _ event: Catlaser_App_V1_DeviceEvent,
    ) throws -> Catlaser_App_V1_PlayHistoryResponse {
        if case let .playHistory(response) = event.event {
            return response
        }
        throw HistoryError.wrongEventKind(
            expected: "play_history",
            got: event.event?.shortName ?? "unspecified",
        )
    }

    // MARK: - Private: state restoration helpers

    private func restored(
        priorProfiles: [Catlaser_App_V1_CatProfile]?,
        on error: HistoryError,
    ) -> CatProfilesState {
        if let priorProfiles {
            // A refresh failure must NOT blank the previously-loaded
            // list — the user keeps their data and the action error
            // banner surfaces the diagnostic.
            lastActionError = error
            return .loaded(profiles: priorProfiles, isRefreshing: false)
        }
        return .failed(error)
    }

    private func restored(
        priorSessions: [Catlaser_App_V1_PlaySession]?,
        range: ClosedRange<Date>,
        on error: HistoryError,
    ) -> PlayHistoryState {
        if let priorSessions {
            lastActionError = error
            return .loaded(sessions: priorSessions, range: range, isRefreshing: false)
        }
        return .failed(error, range: range)
    }

    // MARK: - Private: defaults

    private func defaultHistoryRange() -> ClosedRange<Date> {
        let now = clock()
        let start = now.addingTimeInterval(-Self.defaultHistoryWindow)
        return start ... now
    }

    private func epochSeconds(from date: Date) -> UInt64 {
        let interval = date.timeIntervalSince1970
        return interval <= 0 ? 0 : UInt64(interval)
    }
}

// MARK: - Oneof shorthand

private extension Catlaser_App_V1_DeviceEvent.OneOf_Event {
    /// Stable short names for the typed-error surface. Keeping the
    /// strings here (and not in the proto-generated file) means a
    /// codegen change does not silently rename them.
    var shortName: String {
        switch self {
        case .statusUpdate: "status_update"
        case .catProfileList: "cat_profile_list"
        case .playHistory: "play_history"
        case .streamOffer: "stream_offer"
        case .sessionSummary: "session_summary"
        case .newCatDetected: "new_cat_detected"
        case .hopperEmpty: "hopper_empty"
        case .diagnosticResult: "diagnostic_result"
        case .error: "error"
        case .schedule: "schedule"
        case .pushTokenAck: "push_token_ack"
        case .authResponse: "auth_response"
        }
    }
}
