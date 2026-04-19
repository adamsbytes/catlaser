import CatLaserDevice
import CatLaserDeviceTestSupport
import CatLaserProto
import Foundation
import Testing

@testable import CatLaserSchedule

/// Integration-style tests for ``ScheduleViewModel``.
///
/// Each test scripts a ``ScriptedDeviceServer`` against an
/// ``InMemoryDeviceTransport``, drives the VM through its public
/// surface, and asserts on the observable ``state`` and
/// ``lastActionError`` properties. The pattern mirrors
/// ``HistoryViewModelTests`` so behavioural regressions between the
/// two screens are caught in the same shape of test.
@MainActor
@Suite("ScheduleViewModel")
struct ScheduleViewModelTests {
    // MARK: - Harness

    private func makeHarness(
        serverHandler: @escaping @Sendable (Catlaser_App_V1_AppRequest) -> ScriptedDeviceServer.Response,
    ) async throws -> (ScheduleViewModel, InMemoryDeviceTransport, ScriptedDeviceServer, DeviceClient) {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport, requestTimeout: 2.0)
        let server = ScriptedDeviceServer(transport: transport, handler: serverHandler)
        try await client.connect()
        await server.run()
        let idCounter = IDCounter()
        let vm = ScheduleViewModel(
            deviceClient: client,
            idFactory: { idCounter.next() },
        )
        return (vm, transport, server, client)
    }

    private func teardown(server: ScriptedDeviceServer, client: DeviceClient) {
        Task {
            await server.stop()
            await client.disconnect()
        }
    }

    nonisolated private func reply(entries: [Catlaser_App_V1_ScheduleEntry]) -> ScriptedDeviceServer.Response {
        var event = Catlaser_App_V1_DeviceEvent()
        var list = Catlaser_App_V1_ScheduleList()
        list.entries = entries
        event.schedule = list
        return .reply(event)
    }

    nonisolated private func makeEntry(
        id: String = "entry-1",
        startMinute: UInt32 = 480,
        durationMin: UInt32 = 15,
        days: [Catlaser_App_V1_DayOfWeek] = [],
        enabled: Bool = true,
    ) -> Catlaser_App_V1_ScheduleEntry {
        var entry = Catlaser_App_V1_ScheduleEntry()
        entry.entryID = id
        entry.startMinute = startMinute
        entry.durationMin = durationMin
        entry.days = days
        entry.enabled = enabled
        return entry
    }

    // MARK: - Initial state

    @Test
    func initialStateIsIdleAndErrorEmpty() async throws {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport)
        let vm = ScheduleViewModel(deviceClient: client)
        #expect(vm.state == .idle)
        #expect(vm.lastActionError == nil)
    }

    // MARK: - Start loads schedule

    @Test
    func startLoadsBaselineAndDraft() async throws {
        let entry = makeEntry(id: "morning", startMinute: 480, durationMin: 30, days: [.monday, .tuesday])
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule:
                return self.reply(entries: [entry])
            default:
                return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()

        guard case let .loaded(draftSet, isRefreshing, isSaving) = vm.state else {
            Issue.record("expected .loaded, got \(vm.state)")
            return
        }
        #expect(!isRefreshing)
        #expect(!isSaving)
        #expect(draftSet.baseline.count == 1)
        #expect(draftSet.entries.count == 1)
        #expect(!draftSet.isDirty)
        let draft = draftSet.entries[0]
        #expect(draft.id == "morning")
        #expect(draft.startMinute == 480)
        #expect(draft.durationMinutes == 30)
        #expect(draft.days == Set([.monday, .tuesday]))
        #expect(draft.enabled)
    }

    @Test
    func startWithEmptyScheduleLoadsEmptyDraftSet() async throws {
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule: return self.reply(entries: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()

        guard case let .loaded(draftSet, _, _) = vm.state else {
            Issue.record("expected .loaded for empty schedule, got \(vm.state)")
            return
        }
        #expect(draftSet.entries.isEmpty)
        #expect(draftSet.baseline.isEmpty)
        #expect(!draftSet.isDirty)
    }

    @Test
    func startIngestsMultipleEntriesInChronologicalOrder() async throws {
        // Device returns entries in arbitrary order; the VM sorts
        // them chronologically so the UI reads top-to-bottom.
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule:
                return self.reply(entries: [
                    self.makeEntry(id: "evening", startMinute: 1_200),
                    self.makeEntry(id: "morning", startMinute: 480),
                    self.makeEntry(id: "lunch", startMinute: 720),
                ])
            default:
                return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        guard case let .loaded(draftSet, _, _) = vm.state else {
            Issue.record("expected .loaded, got \(vm.state)")
            return
        }
        #expect(draftSet.entries.map(\.id) == ["morning", "lunch", "evening"])
    }

    @Test
    func startFiltersUnspecifiedDayCasesOnIngest() async throws {
        // The device's enum surface may advance; an unknown day
        // in the wire payload must not round-trip unchanged. The
        // validation gate would refuse the malformed draft, so
        // filtering at ingest keeps the user out of a bind they
        // cannot escape.
        var seed = makeEntry(id: "x", startMinute: 600, durationMin: 30)
        seed.days = [.monday, .unspecified, .friday]
        let entry = seed
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule: return self.reply(entries: [entry])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        guard case let .loaded(draftSet, _, _) = vm.state else {
            Issue.record("expected .loaded, got \(vm.state)")
            return
        }
        #expect(draftSet.entries.first?.days == Set([.monday, .friday]))
    }

    // MARK: - Add / update / delete / toggle

    @Test
    func addEntryAppendsDraftAndFlipsDirty() async throws {
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule: return self.reply(entries: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        let newID = vm.addEntry()
        #expect(newID != nil)
        guard case let .loaded(draftSet, _, _) = vm.state else {
            Issue.record("expected .loaded, got \(vm.state)")
            return
        }
        #expect(draftSet.entries.count == 1)
        #expect(draftSet.entries.first?.id == newID)
        #expect(draftSet.isDirty,
                "adding a fresh entry to an empty baseline must flip isDirty")
    }

    @Test
    func addEntryReturnsNilWhenNotLoaded() async throws {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport)
        let vm = ScheduleViewModel(deviceClient: client)
        #expect(vm.addEntry() == nil)
    }

    @Test
    func updateEntryReplacesAtSameID() async throws {
        let entry = makeEntry(id: "morning", startMinute: 480, durationMin: 15)
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule: return self.reply(entries: [entry])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        guard case let .loaded(draftSet, _, _) = vm.state,
              var existing = draftSet.entries.first
        else {
            Issue.record("expected a loaded entry")
            return
        }
        existing.startMinute = 540
        existing.durationMinutes = 45
        vm.updateEntry(existing)

        guard case let .loaded(newSet, _, _) = vm.state else {
            Issue.record("expected .loaded after update")
            return
        }
        #expect(newSet.entries.first?.startMinute == 540)
        #expect(newSet.entries.first?.durationMinutes == 45)
        #expect(newSet.isDirty)
    }

    @Test
    func deleteEntryRemovesDraft() async throws {
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule:
                return self.reply(entries: [
                    self.makeEntry(id: "a", startMinute: 480),
                    self.makeEntry(id: "b", startMinute: 720),
                ])
            default:
                return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        vm.deleteEntry(id: "a")
        guard case let .loaded(draftSet, _, _) = vm.state else {
            Issue.record("expected .loaded after delete")
            return
        }
        #expect(draftSet.entries.map(\.id) == ["b"])
        #expect(draftSet.isDirty)
    }

    @Test
    func toggleEnabledFlipsFlag() async throws {
        let entry = makeEntry(id: "morning", enabled: true)
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule: return self.reply(entries: [entry])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        vm.toggleEnabled(id: "morning")
        guard case let .loaded(draftSet, _, _) = vm.state else {
            Issue.record("expected .loaded after toggle")
            return
        }
        #expect(draftSet.entries.first?.enabled == false)
        #expect(draftSet.isDirty)
        vm.toggleEnabled(id: "morning")
        // Flipping back exactly matches the baseline — isDirty
        // drops to false so the Save button disables itself.
        guard case let .loaded(restored, _, _) = vm.state else {
            Issue.record("expected .loaded after second toggle")
            return
        }
        #expect(restored.entries.first?.enabled == true)
        #expect(!restored.isDirty,
                "toggling twice must restore baseline equality")
    }

    @Test
    func discardChangesRestoresBaseline() async throws {
        let entry = makeEntry(id: "morning", startMinute: 480, durationMin: 15)
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule: return self.reply(entries: [entry])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        vm.addEntry()
        vm.deleteEntry(id: "morning")
        guard case let .loaded(mutated, _, _) = vm.state else {
            Issue.record("expected .loaded after edits")
            return
        }
        #expect(mutated.isDirty)
        vm.discardChanges()
        guard case let .loaded(restored, _, _) = vm.state else {
            Issue.record("expected .loaded after discard")
            return
        }
        #expect(restored.entries.map(\.id) == ["morning"])
        #expect(!restored.isDirty)
    }

    // MARK: - Save

    @Test
    func saveCommitsDraftAndUpdatesBaseline() async throws {
        let original = makeEntry(id: "morning", startMinute: 480, durationMin: 15)
        let savedRequest = LockedSetScheduleCapture()
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule: return self.reply(entries: [original])
            case let .setSchedule(req):
                savedRequest.set(req.entries)
                // Echo the drafted list back — the device round-trips
                // the user's set verbatim.
                return self.reply(entries: req.entries)
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        vm.toggleEnabled(id: "morning")
        let outcome = await vm.save()
        if case .success = outcome { /* good */ } else {
            Issue.record("expected .success, got \(outcome)")
        }

        guard case let .loaded(draftSet, isRefreshing, isSaving) = vm.state else {
            Issue.record("expected .loaded after save")
            return
        }
        #expect(!isRefreshing)
        #expect(!isSaving)
        #expect(!draftSet.isDirty,
                "successful save must snap baseline to draft so isDirty flips back")
        #expect(draftSet.entries.first?.enabled == false)

        // Wire carried the TOGGLED entry, not the original.
        let sent = savedRequest.get()
        #expect(sent.count == 1)
        #expect(sent.first?.enabled == false)
        #expect(sent.first?.entryID == "morning")
    }

    @Test
    func saveWithNoDirtyChangesIsSilentNoWireTraffic() async throws {
        // The Save button should be disabled in this state, but
        // the VM is the last gate — a programming error that
        // invoked save() anyway must NOT fire a wire round-trip.
        let setCount = LockedCounter()
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule: return self.reply(entries: [])
            case .setSchedule:
                setCount.increment()
                return self.reply(entries: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        let outcome = await vm.save()
        if case .success = outcome { /* good */ } else {
            Issue.record("expected .success for no-op save, got \(outcome)")
        }
        #expect(setCount.value == 0)
    }

    @Test
    func saveRefusesInvalidDraftWithoutWireTraffic() async throws {
        let setCount = LockedCounter()
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule:
                return self.reply(entries: [])
            case .setSchedule:
                setCount.increment()
                return self.reply(entries: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        // Build an invalid draft by hand (duration = 0) and push
        // it through the VM's update path.
        guard let newID = vm.addEntry() else {
            Issue.record("addEntry should have returned an id")
            return
        }
        guard case let .loaded(draftSet, _, _) = vm.state,
              var draft = draftSet.entries.first(where: { $0.id == newID })
        else {
            Issue.record("expected added draft")
            return
        }
        draft.durationMinutes = 0
        vm.updateEntry(draft)

        let outcome = await vm.save()
        guard case let .failure(error) = outcome,
              case let .validation(failure) = error,
              case .durationOutOfRange = failure
        else {
            Issue.record("expected .validation(.durationOutOfRange), got \(outcome)")
            return
        }
        #expect(setCount.value == 0,
                "an invalid draft must never burn a wire round-trip")
        #expect(vm.lastActionError != nil)
    }

    @Test
    func addEntryIDFactoryDoesNotCollideAcrossCalls() async throws {
        // The VM's id factory is the load-bearing guarantee that
        // ``DraftSet.update`` is able to target one row unambiguously.
        // Two consecutive ``addEntry`` calls must produce distinct
        // ids so the update-by-id semantics don't silently collapse
        // two rows into one. The validator catches a forged
        // collision (tested in ``ScheduleValidationTests``); this
        // test pins the VM-side property that no natural path
        // through the public surface can produce one.
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule: return self.reply(entries: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        let idA = vm.addEntry()
        let idB = vm.addEntry()
        let idC = vm.addEntry()
        #expect(idA != nil)
        #expect(idB != nil)
        #expect(idC != nil)
        #expect(idA != idB)
        #expect(idB != idC)
        #expect(idA != idC)
        guard case let .loaded(draftSet, _, _) = vm.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(Set(draftSet.entries.map(\.id)).count == 3,
                "the three fresh drafts must all carry distinct ids")
    }

    @Test
    func saveTransportFailurePreservesDraft() async throws {
        // The user's pending edits MUST survive a transport
        // failure — they already typed them, the VM has nothing
        // else to show, and re-typing is worse than a retry.
        let original = makeEntry(id: "morning", startMinute: 480, durationMin: 15)
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule: return self.reply(entries: [original])
            case .setSchedule: return .error(code: 99, message: "transient")
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        vm.toggleEnabled(id: "morning")
        let outcome = await vm.save()
        if case .failure = outcome { /* good */ } else {
            Issue.record("expected .failure, got \(outcome)")
        }
        guard case let .loaded(draftSet, _, isSaving) = vm.state else {
            Issue.record("expected .loaded after save failure")
            return
        }
        #expect(!isSaving)
        #expect(draftSet.entries.first?.enabled == false,
                "draft must survive transport failure")
        #expect(draftSet.isDirty,
                "isDirty must remain true so the Save button stays enabled")
        #expect(vm.lastActionError != nil)
    }

    @Test
    func saveDoubleInvocationFiresOnlyOnce() async throws {
        let setCount = LockedCounter()
        let entry = makeEntry(id: "morning", startMinute: 480, durationMin: 15)
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule: return self.reply(entries: [entry])
            case let .setSchedule(req):
                setCount.increment()
                return self.reply(entries: req.entries)
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        vm.toggleEnabled(id: "morning")
        let initial = setCount.value
        async let a: Result<Void, ScheduleError> = vm.save()
        async let b: Result<Void, ScheduleError> = vm.save()
        _ = await (a, b)
        #expect(setCount.value == initial + 1,
                "concurrent save() calls must fire exactly one wire round-trip")
    }

    @Test
    func saveAcceptsMidnightCrossingWindow() async throws {
        // A window that crosses midnight (start + duration > 1440)
        // is legal per the device evaluator. The validator must
        // NOT refuse it.
        let saved = LockedSetScheduleCapture()
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule: return self.reply(entries: [])
            case let .setSchedule(req):
                saved.set(req.entries)
                return self.reply(entries: req.entries)
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        let newID = vm.addEntry()!
        guard case let .loaded(draftSet, _, _) = vm.state,
              var draft = draftSet.entries.first(where: { $0.id == newID })
        else {
            Issue.record("expected added draft")
            return
        }
        draft.startMinute = 1_380 // 23:00
        draft.durationMinutes = 120 // ends at 01:00 next day
        vm.updateEntry(draft)
        let outcome = await vm.save()
        if case .success = outcome { /* good */ } else {
            Issue.record("midnight-crossing window must save, got \(outcome)")
        }
        let sent = saved.get()
        #expect(sent.first?.startMinute == 1_380)
        #expect(sent.first?.durationMin == 120)
    }

    @Test
    func saveAcceptsEmptyDaysAsEveryDay() async throws {
        // Empty days = every day, per the Python evaluator. The
        // validator must accept the empty set.
        let saved = LockedSetScheduleCapture()
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule: return self.reply(entries: [])
            case let .setSchedule(req):
                saved.set(req.entries)
                return self.reply(entries: req.entries)
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        let newID = vm.addEntry()!
        guard case let .loaded(draftSet, _, _) = vm.state,
              var draft = draftSet.entries.first(where: { $0.id == newID })
        else {
            Issue.record("expected added draft")
            return
        }
        draft.days = []
        draft.startMinute = 600
        draft.durationMinutes = 30
        vm.updateEntry(draft)
        let outcome = await vm.save()
        if case .success = outcome { /* good */ } else {
            Issue.record("expected .success for empty days, got \(outcome)")
        }
        let sent = saved.get()
        #expect(sent.first?.days == [])
    }

    @Test
    func saveEmitsDaysInMondayToSundayOrder() async throws {
        // Wire encoding must be deterministic regardless of user
        // toggle order.
        let saved = LockedSetScheduleCapture()
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule: return self.reply(entries: [])
            case let .setSchedule(req):
                saved.set(req.entries)
                return self.reply(entries: req.entries)
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        let newID = vm.addEntry()!
        guard case let .loaded(draftSet, _, _) = vm.state,
              var draft = draftSet.entries.first(where: { $0.id == newID })
        else {
            Issue.record("expected added draft")
            return
        }
        draft.days = [.sunday, .monday, .friday]
        draft.startMinute = 600
        draft.durationMinutes = 30
        vm.updateEntry(draft)
        _ = await vm.save()
        let sent = saved.get()
        #expect(sent.first?.days == [.monday, .friday, .sunday])
    }

    // MARK: - Refresh

    @Test
    func refreshFailureKeepsPriorDraft() async throws {
        // A refresh failure must NOT blank the visible list; the
        // banner surfaces the diagnostic.
        let getCount = LockedCounter()
        let original = makeEntry(id: "morning", startMinute: 480, durationMin: 15)
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule:
                getCount.increment()
                if getCount.value == 1 {
                    return self.reply(entries: [original])
                }
                return .error(code: 99, message: "transient")
            default:
                return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        await vm.refresh()
        guard case let .loaded(draftSet, isRefreshing, _) = vm.state else {
            Issue.record("expected .loaded, got \(vm.state)")
            return
        }
        #expect(!isRefreshing)
        #expect(draftSet.entries.first?.id == "morning")
        #expect(vm.lastActionError != nil)
    }

    @Test
    func refreshFailureOnFirstLoadSurfacesAsFailed() async throws {
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule: return .error(code: 99, message: "boom")
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        guard case let .failed(error) = vm.state else {
            Issue.record("expected .failed, got \(vm.state)")
            return
        }
        if case let .deviceError(_, message) = error {
            #expect(message == "boom")
        } else {
            Issue.record("expected .deviceError, got \(error)")
        }
    }

    @Test
    func refreshConcurrentDoesNotDoubleFire() async throws {
        let getCount = LockedCounter()
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule:
                getCount.increment()
                return self.reply(entries: [])
            default:
                return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        let initial = getCount.value
        async let a: Void = vm.refresh()
        async let b: Void = vm.refresh()
        _ = await (a, b)
        #expect(getCount.value == initial + 1)
    }

    // MARK: - Protocol failures

    @Test
    func wrongOneofMapsToWrongEventKind() async throws {
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule:
                var event = Catlaser_App_V1_DeviceEvent()
                event.statusUpdate = Catlaser_App_V1_StatusUpdate()
                return .reply(event)
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        guard case let .failed(error) = vm.state,
              case let .wrongEventKind(expected, got) = error
        else {
            Issue.record("expected .failed(.wrongEventKind), got \(vm.state)")
            return
        }
        #expect(expected == "schedule")
        #expect(got == "status_update")
    }

    @Test
    func notConnectedClientFailsWithNotConnected() async throws {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport)
        try await client.connect()
        await client.disconnect()
        let vm = ScheduleViewModel(deviceClient: client)
        await vm.refresh()
        guard case let .failed(error) = vm.state else {
            Issue.record("expected .failed, got \(vm.state)")
            return
        }
        #expect(error == .notConnected)
    }

    @Test
    func saveOnIdleVMFailsWithNotConnected() async throws {
        // A host that invoked save() before start() — a programming
        // error — must get a typed error back rather than a crash.
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport)
        let vm = ScheduleViewModel(deviceClient: client)
        let outcome = await vm.save()
        guard case let .failure(error) = outcome, error == .notConnected else {
            Issue.record("expected .failure(.notConnected), got \(outcome)")
            return
        }
    }

    // MARK: - Lifecycle

    @Test
    func dismissActionErrorClearsBanner() async throws {
        let original = makeEntry(id: "morning")
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule: return self.reply(entries: [original])
            case .setSchedule: return .error(code: 99, message: "transient")
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        vm.toggleEnabled(id: "morning")
        _ = await vm.save()
        #expect(vm.lastActionError != nil)
        vm.dismissActionError()
        #expect(vm.lastActionError == nil)
    }

    // MARK: - canRefresh gating

    @Test
    func canRefreshIsFalseWhileSaving() async throws {
        // The refresh button must be disabled while a save is in
        // flight. We drive this by starting the save in the
        // background and asserting `canRefresh` transitions to
        // false before the reply lands.
        let setGate = AsyncGate()
        let original = makeEntry(id: "morning")
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getSchedule: return self.reply(entries: [original])
            case let .setSchedule(req):
                // Block until the test explicitly opens the gate so
                // `isSaving` is observably true.
                setGate.waitBlocking()
                return self.reply(entries: req.entries)
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        vm.toggleEnabled(id: "morning")
        async let saveTask: Result<Void, ScheduleError> = vm.save()
        await pollUntil { !vm.state.canRefresh }
        #expect(!vm.state.canRefresh, "canRefresh must be false while saving")
        setGate.signal()
        _ = await saveTask
    }

    // MARK: - Poll helper

    private func pollUntil(
        timeout: TimeInterval = 2.0,
        _ predicate: () -> Bool,
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

// MARK: - Test primitives

/// Deterministic id counter for tests. The production ``idFactory``
/// is a random UUID, which makes "two fresh entries collide" hard
/// to script; this helper counts them so tests can reason about
/// ids by name.
private final class IDCounter: @unchecked Sendable {
    private var current: Int = 0
    private let lock = NSLock()
    func next() -> String {
        lock.lock(); defer { lock.unlock() }
        current += 1
        return "test-entry-\(current)"
    }
}

/// Locked counter shared with history tests' pattern.
private final class LockedCounter: @unchecked Sendable {
    private var current: Int = 0
    private let lock = NSLock()
    func increment() {
        lock.lock(); defer { lock.unlock() }
        current += 1
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return current
    }
}

/// Captures the most-recent ``SetScheduleRequest.entries`` snapshot
/// seen by the scripted server. Tests inspect the captured value
/// after the VM round-trip completes.
private final class LockedSetScheduleCapture: @unchecked Sendable {
    private var entries: [Catlaser_App_V1_ScheduleEntry] = []
    private let lock = NSLock()
    func set(_ entries: [Catlaser_App_V1_ScheduleEntry]) {
        lock.lock(); defer { lock.unlock() }
        self.entries = entries
    }

    func get() -> [Catlaser_App_V1_ScheduleEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}

/// Condition-variable gate for tests that need to observe an
/// in-flight state. The scripted server blocks on ``waitBlocking``
/// until the test calls ``signal``.
private final class AsyncGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var open = false

    func waitBlocking() {
        condition.lock()
        defer { condition.unlock() }
        while !open {
            condition.wait()
        }
    }

    func signal() {
        condition.lock()
        open = true
        condition.broadcast()
        condition.unlock()
    }
}
