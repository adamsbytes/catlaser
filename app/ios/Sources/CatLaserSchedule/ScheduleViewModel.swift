import CatLaserDevice
import CatLaserProto
import Foundation
import Observation

/// Observable view model backing the schedule setup screen.
///
/// Responsibilities:
///
/// 1. Own the ``GetScheduleRequest`` load and the ``SetScheduleRequest``
///    commit round-trips on the shared ``DeviceClient``.
/// 2. Hold the local ``ScheduleDraftSet`` — the user edits the
///    draft locally; nothing reaches the wire until they hit save.
/// 3. Validate the draft at every mutation boundary and again
///    before save, refusing wire traffic for a malformed draft so a
///    bad input never burns an attestation-signed round-trip.
/// 4. Preserve the user's in-progress edits across a failed save:
///    the draft survives a transport failure so the user can retry
///    without re-typing.
///
/// ## Reentrancy
///
/// ``refresh`` and ``save`` each consult the state machine's gates
/// before issuing a wire call. A double-tap on "Save", a second tap
/// on "Refresh", or any overlap between the two is dropped on the
/// floor.
///
/// ## Threading
///
/// ``@MainActor`` — every state mutation is main-thread.
/// ``DeviceClient`` is an actor; the VM awaits into it and hops
/// back.
///
/// ## Events stream
///
/// The schedule screen does NOT consume the ``DeviceClient.events``
/// stream. The wire protocol gives ``ScheduleList`` only in reply
/// to a solicited ``GetScheduleRequest`` / ``SetScheduleRequest``;
/// there is no unsolicited push-flavoured update, and
/// ``DeviceClient.events`` is documented as a single-consumer
/// surface owned by ``HistoryViewModel``. A ``ScheduleList`` that
/// arrived unsolicited would be classified as an orphan response
/// by the client and echoed down the event stream for diagnostics;
/// the history VM ignores it because it is not a
/// ``NewCatDetected``. Not subscribing here is the load-bearing
/// constraint.
@MainActor
@Observable
public final class ScheduleViewModel {
    // MARK: - Public state

    public private(set) var state: ScheduleViewState = .idle

    /// Last error surfaced for an in-flight action (save, delete).
    /// Separate from ``state`` so a transient save failure does NOT
    /// blank the draft — the user keeps what they typed, and the
    /// banner surfaces the diagnostic. ``nil`` when no banner
    /// should show.
    public private(set) var lastActionError: ScheduleError?

    // MARK: - Dependencies

    private let deviceClient: DeviceClient
    /// Id factory for fresh drafts. Defaults to a random UUID;
    /// tests inject a counter so the sequence is deterministic.
    private let idFactory: @Sendable () -> String

    public init(
        deviceClient: DeviceClient,
        idFactory: @escaping @Sendable () -> String = { UUID().uuidString },
    ) {
        self.deviceClient = deviceClient
        self.idFactory = idFactory
    }

    // MARK: - Lifecycle

    /// Called when the screen first appears. Kicks an initial load.
    /// Idempotent: a second invocation while the load is still in
    /// flight is dropped (the reentrancy gate refuses it); a second
    /// invocation against a ``.failed`` state retries.
    public func start() async {
        await refresh()
    }

    /// Re-fetch the schedule from the device. A "soft refresh"
    /// preserves the visible draft if one is already loaded — the
    /// UI overlays a small spinner rather than blanking the list.
    public func refresh() async {
        guard state.canRefresh else { return }
        switch state {
        case let .loaded(draftSet, _, isSaving):
            // A refresh WHILE saving is refused by `canRefresh`
            // above; the exhaustive switch still threads the
            // `isSaving` flag through to be explicit about the
            // invariant.
            state = .loaded(draftSet: draftSet, isRefreshing: true, isSaving: isSaving)
        case .idle, .failed:
            state = .loading
        case .loading:
            return
        }
        await performGet(preservingDraft: false)
    }

    // MARK: - Draft editing

    /// Append a fresh draft entry with default values and the
    /// mints a new id via ``idFactory``.
    ///
    /// Returns the id the VM appended so the UI can open the edit
    /// sheet pointed at the new row without a second lookup.
    /// Returns ``nil`` if the state is not ``loaded`` (the host
    /// should only enable the Add button when the state is
    /// ``loaded``; guarding here is belt-and-braces).
    @discardableResult
    public func addEntry() -> String? {
        guard case let .loaded(draftSet, isRefreshing, isSaving) = state else {
            return nil
        }
        var mutated = draftSet
        let fresh = ScheduleEntryDraft.freshDraft(idFactory: idFactory)
        mutated.append(fresh)
        state = .loaded(draftSet: mutated, isRefreshing: isRefreshing, isSaving: isSaving)
        lastActionError = nil
        return fresh.id
    }

    /// Replace the draft at the supplied id with the supplied
    /// value. No-op if the state is not ``loaded`` or the id is
    /// absent.
    public func updateEntry(_ entry: ScheduleEntryDraft) {
        guard case let .loaded(draftSet, isRefreshing, isSaving) = state else {
            return
        }
        var mutated = draftSet
        mutated.update(entry)
        state = .loaded(draftSet: mutated, isRefreshing: isRefreshing, isSaving: isSaving)
        lastActionError = nil
    }

    /// Remove the draft at the supplied id. Local-only until save
    /// commits.
    public func deleteEntry(id: String) {
        guard case let .loaded(draftSet, isRefreshing, isSaving) = state else {
            return
        }
        var mutated = draftSet
        mutated.remove(id: id)
        state = .loaded(draftSet: mutated, isRefreshing: isRefreshing, isSaving: isSaving)
        lastActionError = nil
    }

    /// Flip the ``enabled`` flag on one draft. A convenience so the
    /// row-level toggle doesn't require the caller to look up, mutate,
    /// and write back the full draft.
    public func toggleEnabled(id: String) {
        guard case let .loaded(draftSet, isRefreshing, isSaving) = state else {
            return
        }
        var mutated = draftSet
        mutated.toggleEnabled(id: id)
        state = .loaded(draftSet: mutated, isRefreshing: isRefreshing, isSaving: isSaving)
        lastActionError = nil
    }

    /// Revert every pending edit to the server baseline. A no-op
    /// if nothing is pending.
    public func discardChanges() {
        guard case let .loaded(draftSet, isRefreshing, isSaving) = state else {
            return
        }
        guard draftSet.isDirty else { return }
        var mutated = draftSet
        mutated.discard()
        state = .loaded(draftSet: mutated, isRefreshing: isRefreshing, isSaving: isSaving)
        lastActionError = nil
    }

    /// Dismiss the action-level error banner. Does not clear the
    /// screen-level ``failed`` state; the "Try again" button on the
    /// failed screen drives ``refresh`` directly.
    public func dismissActionError() {
        lastActionError = nil
    }

    // MARK: - Save

    /// Commit the current draft to the device via a single
    /// ``SetScheduleRequest``. The device reply carries the updated
    /// ``ScheduleList``, which becomes the new baseline.
    ///
    /// Returns the outcome so the hosting view can dismiss a sheet
    /// on success without awaiting a state observation on the main
    /// actor's next run loop.
    ///
    /// On validation failure no wire traffic is emitted; on a
    /// transport / remote failure the draft is preserved verbatim
    /// so the user does not lose their edits.
    @discardableResult
    public func save() async -> Result<Void, ScheduleError> {
        guard case let .loaded(draftSet, isRefreshing, _) = state else {
            let error = ScheduleError.notConnected
            lastActionError = error
            return .failure(error)
        }

        // Guard against double-fire. A second invocation while a
        // save is in flight is dropped; the caller already hit the
        // button once, the previous call is still racing to
        // completion.
        if case let .loaded(_, _, isSaving) = state, isSaving {
            return .failure(.internalFailure("save already in flight"))
        }

        // No-op save (nothing to commit) is a silent success so a
        // user hitting "Save" with no pending edits gets a
        // no-surprise outcome. No wire traffic is issued.
        if !draftSet.isDirty {
            return .success(())
        }

        if let failure = ScheduleValidation.validate(set: draftSet) {
            let mapped = ScheduleError.validation(failure)
            lastActionError = mapped
            return .failure(mapped)
        }

        state = .loaded(draftSet: draftSet, isRefreshing: isRefreshing, isSaving: true)

        var request = Catlaser_App_V1_AppRequest()
        var setRequest = Catlaser_App_V1_SetScheduleRequest()
        setRequest.entries = draftSet.entries.map { $0.toWire() }
        request.setSchedule = setRequest

        do {
            let event = try await deviceClient.request(request)
            let list = try unwrapScheduleList(event)
            // Device reply is the new baseline; a successful save
            // always snaps the draft to whatever the device chose
            // to persist, so the user's view reflects ground
            // truth. This is also what clears ``isDirty`` — the
            // baseline was ``draftSet.entries`` before, and is
            // ``list.entries`` now, but the two match byte-for-byte
            // because the device round-tripped the set verbatim.
            var refreshed = draftSet
            refreshed.adoptBaseline(list.entries.map(ScheduleEntryDraft.init(wire:)))
            state = .loaded(draftSet: refreshed, isRefreshing: false, isSaving: false)
            lastActionError = nil
            return .success(())
        } catch let error as ScheduleError {
            return handleSaveFailure(error: error, draftSet: draftSet)
        } catch let error as DeviceClientError {
            return handleSaveFailure(error: ScheduleError.from(error), draftSet: draftSet)
        } catch {
            return handleSaveFailure(
                error: .internalFailure(error.localizedDescription),
                draftSet: draftSet,
            )
        }
    }

    // MARK: - Private: GET round-trip

    /// Issue a ``GetScheduleRequest`` and route the reply onto
    /// ``state``. The ``preservingDraft`` flag lets a future caller
    /// adopt the reply verbatim; currently every call site drops
    /// the pending draft because the user explicitly asked for a
    /// fresh load (pull-to-refresh or an explicit tap).
    private func performGet(preservingDraft: Bool) async {
        var request = Catlaser_App_V1_AppRequest()
        request.getSchedule = Catlaser_App_V1_GetScheduleRequest()

        // Snapshot the prior draft so a refresh failure can restore
        // it instead of blanking the screen.
        let priorDraft: ScheduleDraftSet?
        if case let .loaded(draftSet, _, _) = state {
            priorDraft = draftSet
        } else {
            priorDraft = nil
        }

        do {
            let event = try await deviceClient.request(request)
            let list = try unwrapScheduleList(event)
            let ingested = list.entries.map(ScheduleEntryDraft.init(wire:))
            let newSet: ScheduleDraftSet = if preservingDraft, let prior = priorDraft {
                ScheduleDraftSet(baseline: ingested, entries: prior.entries)
            } else {
                ScheduleDraftSet(baseline: ingested, entries: ingested)
            }
            state = .loaded(draftSet: newSet, isRefreshing: false, isSaving: false)
        } catch let error as ScheduleError {
            state = handleGetFailure(error: error, priorDraft: priorDraft)
        } catch let error as DeviceClientError {
            state = handleGetFailure(error: ScheduleError.from(error), priorDraft: priorDraft)
        } catch {
            state = handleGetFailure(
                error: .internalFailure(error.localizedDescription),
                priorDraft: priorDraft,
            )
        }
    }

    // MARK: - Private: failure handling

    private func handleGetFailure(
        error: ScheduleError,
        priorDraft: ScheduleDraftSet?,
    ) -> ScheduleViewState {
        if let priorDraft {
            // A refresh failure must NOT blank the user's already-
            // visible list or throw away their pending edits. The
            // action banner surfaces the diagnostic; the draft is
            // preserved verbatim.
            lastActionError = error
            return .loaded(draftSet: priorDraft, isRefreshing: false, isSaving: false)
        }
        return .failed(error)
    }

    private func handleSaveFailure(
        error: ScheduleError,
        draftSet: ScheduleDraftSet,
    ) -> Result<Void, ScheduleError> {
        lastActionError = error
        state = .loaded(draftSet: draftSet, isRefreshing: false, isSaving: false)
        return .failure(error)
    }

    // MARK: - Private: oneof extraction

    private func unwrapScheduleList(
        _ event: Catlaser_App_V1_DeviceEvent,
    ) throws -> Catlaser_App_V1_ScheduleList {
        if case let .schedule(list) = event.event {
            return list
        }
        throw ScheduleError.wrongEventKind(
            expected: "schedule",
            got: event.event?.shortName ?? "unspecified",
        )
    }
}

// MARK: - Oneof shorthand

private extension Catlaser_App_V1_DeviceEvent.OneOf_Event {
    /// Stable short names for ``wrongEventKind`` diagnostics. Kept
    /// on this file (not shared with ``HistoryViewModel``'s private
    /// extension) so a codegen change that renames cases is caught
    /// independently on each surface.
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
