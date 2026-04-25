import CatLaserDevice
import CatLaserDeviceTestSupport
import CatLaserProto
import Foundation
import Testing

@testable import CatLaserHistory

/// Integration-style tests for ``HistoryViewModel``. The pattern
/// mirrors ``LiveViewModelTests`` from ``CatLaserLive``: each test
/// scripts a ``ScriptedDeviceServer`` against an
/// ``InMemoryDeviceTransport``, drives the VM through public
/// methods, and asserts on the observable ``catsState`` /
/// ``historyState`` / ``pendingNewCats`` / ``lastActionError``
/// surface.
@MainActor
@Suite("HistoryViewModel")
struct HistoryViewModelTests {
    // MARK: - Harness

    private func makeHarness(
        serverHandler: @escaping @Sendable (Catlaser_App_V1_AppRequest) -> ScriptedDeviceServer.Response,
    ) async throws -> (HistoryViewModel, InMemoryDeviceTransport, ScriptedDeviceServer, DeviceClient) {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport, requestTimeout: 2.0)
        let server = ScriptedDeviceServer(transport: transport, handler: serverHandler)
        try await client.connect()
        await server.run()
        let vm = HistoryViewModel(
            deviceClient: client,
            clock: { Date(timeIntervalSince1970: 1_712_345_678) },
        )
        return (vm, transport, server, client)
    }

    private func eventually(
        _ predicate: () -> Bool,
        timeout: TimeInterval = 2.0,
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    nonisolated private func makeProfile(
        id: String = "cat-a",
        name: String = "Pancake",
        sessions: UInt32 = 3,
    ) -> Catlaser_App_V1_CatProfile {
        var profile = Catlaser_App_V1_CatProfile()
        profile.catID = id
        profile.name = name
        profile.totalSessions = sessions
        profile.totalPlayTimeSec = 600
        profile.totalTreats = 9
        profile.preferredSpeed = 0.5
        profile.preferredSmoothing = 0.6
        profile.patternRandomness = 0.3
        profile.createdAt = 1_700_000_000
        return profile
    }

    nonisolated private func makeSession(
        id: String = "sess-1",
        startTime: UInt64 = 1_712_300_000,
        durationSec: UInt32 = 300,
    ) -> Catlaser_App_V1_PlaySession {
        var session = Catlaser_App_V1_PlaySession()
        session.sessionID = id
        session.startTime = startTime
        session.endTime = startTime + UInt64(durationSec)
        session.catIds = ["cat-a"]
        session.durationSec = durationSec
        session.engagementScore = 0.65
        session.treatsDispensed = 2
        session.pounceCount = 18
        return session
    }

    nonisolated private func reply(profiles: [Catlaser_App_V1_CatProfile]) -> ScriptedDeviceServer.Response {
        var event = Catlaser_App_V1_DeviceEvent()
        var list = Catlaser_App_V1_CatProfileList()
        list.profiles = profiles
        event.catProfileList = list
        return .reply(event)
    }

    nonisolated private func reply(sessions: [Catlaser_App_V1_PlaySession]) -> ScriptedDeviceServer.Response {
        var event = Catlaser_App_V1_DeviceEvent()
        var resp = Catlaser_App_V1_PlayHistoryResponse()
        resp.sessions = sessions
        event.playHistory = resp
        return .reply(event)
    }

    private func teardown(server: ScriptedDeviceServer, client: DeviceClient) {
        Task {
            await server.stop()
            await client.disconnect()
        }
    }

    // MARK: - Initial state

    @Test
    func initialStateIsIdleAndQueueEmpty() async throws {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport)
        let vm = HistoryViewModel(deviceClient: client)
        #expect(vm.catsState == .idle)
        #expect(vm.historyState == .idle)
        #expect(vm.pendingNewCats.isEmpty)
        #expect(vm.lastActionError == nil)
    }

    // MARK: - Start: cats + history loaded in parallel

    @Test
    func startLoadsCatsAndHistory() async throws {
        let pancake = makeProfile()
        let session = makeSession()
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles:
                return self.reply(profiles: [pancake])
            case .getPlayHistory:
                return self.reply(sessions: [session])
            default:
                return .error(code: 2, message: "unexpected request")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()

        guard case let .loaded(profiles, isRefreshing) = vm.catsState else {
            Issue.record("expected .loaded, got \(vm.catsState)")
            return
        }
        #expect(profiles == [pancake])
        #expect(!isRefreshing)

        guard case let .loaded(sessions, _, sessionsRefreshing) = vm.historyState else {
            Issue.record("expected .loaded for history, got \(vm.historyState)")
            return
        }
        #expect(sessions == [session])
        #expect(!sessionsRefreshing)
    }

    @Test
    func emptyCatsLoadsToEmptyList() async throws {
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [])
            case .getPlayHistory: return self.reply(sessions: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        if case let .loaded(profiles, _) = vm.catsState {
            #expect(profiles.isEmpty)
        } else {
            Issue.record("expected empty .loaded, got \(vm.catsState)")
        }
    }

    // MARK: - Update name happy path

    @Test
    func updateCatNameRefreshesList() async throws {
        let original = makeProfile(name: "Pancake")
        var renamedDraft = original
        renamedDraft.name = "Pancake Jr."
        let renamed = renamedDraft

        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [original])
            case .getPlayHistory: return self.reply(sessions: [])
            case let .updateCatProfile(req):
                #expect(req.profile.name == "Pancake Jr.")
                #expect(req.profile.catID == "cat-a")
                // The full profile must round-trip — behaviour
                // params, lifetime stats, created_at all preserved.
                #expect(req.profile.preferredSpeed == 0.5)
                #expect(req.profile.totalSessions == 3)
                return self.reply(profiles: [renamed])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        let outcome = await vm.updateCatName(original, newName: "Pancake Jr.")
        if case .success = outcome { /* good */ } else {
            Issue.record("expected .success, got \(outcome)")
        }
        if case let .loaded(profiles, _) = vm.catsState {
            #expect(profiles.first?.name == "Pancake Jr.")
        } else {
            Issue.record("expected .loaded after update, got \(vm.catsState)")
        }
        #expect(vm.lastActionError == nil)
    }

    @Test
    func updateCatNameTrimsWhitespaceBeforeSending() async throws {
        let original = makeProfile()
        let sentName = LockedString()
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles, .updateCatProfile:
                if case let .updateCatProfile(req) = request.request {
                    sentName.set(req.profile.name)
                    return self.reply(profiles: [req.profile])
                }
                return self.reply(profiles: [original])
            case .getPlayHistory: return self.reply(sessions: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        _ = await vm.updateCatName(original, newName: "  Pancake  ")
        #expect(sentName.get() == "Pancake")
    }

    @Test
    func updateCatNameRejectsEmptyNameWithoutWireTraffic() async throws {
        let original = makeProfile()
        let updateCount = LockedCounter()
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [original])
            case .getPlayHistory: return self.reply(sessions: [])
            case .updateCatProfile:
                updateCount.increment()
                return self.reply(profiles: [original])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        let outcome = await vm.updateCatName(original, newName: "   ")
        guard case let .failure(error) = outcome, case .validation = error else {
            Issue.record("expected .failure(.validation), got \(outcome)")
            return
        }
        // No wire traffic must have been issued — the check is
        // load-bearing because each request burns an
        // attestation-signed round-trip.
        #expect(updateCount.value == 0)
        #expect(vm.lastActionError != nil)
    }

    @Test
    func updateCatNameRejectsOverlongNameWithoutWireTraffic() async throws {
        let original = makeProfile()
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [original])
            case .getPlayHistory: return self.reply(sessions: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        let tooLong = String(repeating: "x", count: HistoryViewModel.maxNameLength + 1)
        let outcome = await vm.updateCatName(original, newName: tooLong)
        guard case let .failure(error) = outcome, case .validation = error else {
            Issue.record("expected .failure(.validation), got \(outcome)")
            return
        }
    }

    // MARK: - Delete

    @Test
    func deleteCatRefreshesList() async throws {
        let pancake = makeProfile(id: "cat-a", name: "Pancake")
        let waffle = makeProfile(id: "cat-b", name: "Waffle")
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [pancake, waffle])
            case .getPlayHistory: return self.reply(sessions: [])
            case let .deleteCatProfile(req):
                #expect(req.catID == "cat-a")
                return self.reply(profiles: [waffle])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        let outcome = await vm.deleteCat(catID: "cat-a")
        if case .success = outcome { /* good */ } else {
            Issue.record("expected .success, got \(outcome)")
        }
        if case let .loaded(profiles, _) = vm.catsState {
            #expect(profiles == [waffle])
        } else {
            Issue.record("expected .loaded after delete, got \(vm.catsState)")
        }
    }

    @Test
    func deleteCatNotFoundDropsErrorAndTriggersBackgroundRefresh() async throws {
        // The device returns NOT_FOUND if the row is already gone.
        // The VM must surface the typed error AND opportunistically
        // refresh the list so the UI converges on the device's
        // truth without a manual tap.
        let waffle = makeProfile(id: "cat-b", name: "Waffle")
        let initialList = LockedCounter()
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles:
                initialList.increment()
                // First call: list with both. After the failure, the
                // VM's background refresh fires a second call which
                // returns the truncated list.
                if initialList.value == 1 {
                    return self.reply(profiles: [
                        self.makeProfile(id: "cat-a", name: "Pancake"),
                        waffle,
                    ])
                }
                return self.reply(profiles: [waffle])
            case .getPlayHistory: return self.reply(sessions: [])
            case .deleteCatProfile:
                return .error(
                    code: HistoryError.notFoundCode,
                    message: "cat cat-a not found",
                )
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        let outcome = await vm.deleteCat(catID: "cat-a")
        guard case let .failure(error) = outcome, case .notFound = error else {
            Issue.record("expected .failure(.notFound), got \(outcome)")
            return
        }
        #expect(vm.lastActionError != nil)
        // Background refresh should converge on the truncated list.
        await eventually {
            if case let .loaded(profiles, _) = vm.catsState {
                return profiles == [waffle]
            }
            return false
        }
        if case let .loaded(profiles, _) = vm.catsState {
            #expect(profiles == [waffle])
        } else {
            Issue.record("background refresh did not converge: \(vm.catsState)")
        }
    }

    // MARK: - Wrong event kind

    @Test
    func wrongOneofMapsToWrongEventKind() async throws {
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles:
                // Reply with the wrong oneof — a status_update where
                // the VM expected cat_profile_list.
                var event = Catlaser_App_V1_DeviceEvent()
                event.statusUpdate = Catlaser_App_V1_StatusUpdate()
                return .reply(event)
            case .getPlayHistory:
                return self.reply(sessions: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        guard case let .failed(error) = vm.catsState,
              case let .wrongEventKind(expected, got) = error
        else {
            Issue.record("expected .failed(.wrongEventKind), got \(vm.catsState)")
            return
        }
        #expect(expected == "cat_profile_list")
        #expect(got == "status_update")
    }

    @Test
    func historyWrongOneofMapsToWrongEventKind() async throws {
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles:
                return self.reply(profiles: [])
            case .getPlayHistory:
                var event = Catlaser_App_V1_DeviceEvent()
                event.statusUpdate = Catlaser_App_V1_StatusUpdate()
                return .reply(event)
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        guard case let .failed(error, _) = vm.historyState,
              case let .wrongEventKind(expected, _) = error
        else {
            Issue.record("expected .failed(.wrongEventKind), got \(vm.historyState)")
            return
        }
        #expect(expected == "play_history")
    }

    // MARK: - Not connected

    @Test
    func notConnectedClientFailsWithNotConnected() async throws {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport)
        try await client.connect()
        await client.disconnect()
        let vm = HistoryViewModel(deviceClient: client)
        await vm.refreshCats()
        guard case let .failed(error) = vm.catsState else {
            Issue.record("expected .failed, got \(vm.catsState)")
            return
        }
        #expect(error == .notConnected)
    }

    // MARK: - Refresh: prior list preserved on failure

    @Test
    func refreshFailureKeepsPriorList() async throws {
        let pancake = makeProfile()
        let callCount = LockedCounter()
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles:
                callCount.increment()
                if callCount.value == 1 {
                    return self.reply(profiles: [pancake])
                }
                return .error(code: 99, message: "transient")
            case .getPlayHistory:
                return self.reply(sessions: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        await vm.refreshCats()
        // The list MUST still show the prior data — the user's
        // already-displayed cats are not blanked by a transient
        // failure.
        if case let .loaded(profiles, isRefreshing) = vm.catsState {
            #expect(profiles == [pancake])
            #expect(!isRefreshing)
        } else {
            Issue.record("expected prior list preserved, got \(vm.catsState)")
        }
        // ...but the action banner DOES surface the diagnostic.
        #expect(vm.lastActionError != nil)
    }

    // MARK: - Reentrancy

    @Test
    func concurrentRefreshDoesNotDoubleFire() async throws {
        let callCount = LockedCounter()
        let pancake = makeProfile()
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles:
                callCount.increment()
                return self.reply(profiles: [pancake])
            case .getPlayHistory:
                return self.reply(sessions: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        let initialCount = callCount.value
        // Two refreshes started in parallel — only one should
        // actually issue.
        async let a: Void = vm.refreshCats()
        async let b: Void = vm.refreshCats()
        _ = await (a, b)
        #expect(callCount.value == initialCount + 1)
    }

    // MARK: - History range

    @Test
    func loadHistoryWithExplicitRangeIssuesCorrectQuery() async throws {
        let queryRange = LockedRange()
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [])
            case let .getPlayHistory(req):
                queryRange.set(start: req.startTime, end: req.endTime)
                return self.reply(sessions: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = Date(timeIntervalSince1970: 1_700_086_400)
        await vm.loadHistory(range: start ... end)
        let observed = queryRange.get()
        #expect(observed.start == 1_700_000_000)
        #expect(observed.end == 1_700_086_400)
    }

    @Test
    func loadHistoryEmptyRangeRendersEmpty() async throws {
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [])
            case .getPlayHistory: return self.reply(sessions: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        if case let .loaded(sessions, _, _) = vm.historyState {
            #expect(sessions.isEmpty)
        } else {
            Issue.record("expected empty .loaded, got \(vm.historyState)")
        }
    }

    @Test
    func refreshHistoryReusesLastRange() async throws {
        let observedRanges = LockedRangeList()
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [])
            case let .getPlayHistory(req):
                observedRanges.append(start: req.startTime, end: req.endTime)
                return self.reply(sessions: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        let pinned = Date(timeIntervalSince1970: 1_700_000_000) ... Date(timeIntervalSince1970: 1_700_086_400)
        await vm.loadHistory(range: pinned)
        await vm.refreshHistory()
        let ranges = observedRanges.snapshot()
        // start() issues one default load, then explicit, then
        // refresh — the last two must share the same bounds.
        #expect(ranges.count >= 3)
        let last = ranges.suffix(2)
        #expect(last.first?.start == 1_700_000_000)
        #expect(last.last?.start == 1_700_000_000)
        #expect(last.first?.end == 1_700_086_400)
        #expect(last.last?.end == 1_700_086_400)
    }

    // MARK: - NewCatDetected event handling

    /// When an event broker is supplied, unsolicited events must
    /// reach the VM through the broker's fanout subscription (not the
    /// direct ``DeviceClient/events`` path). This test pins the
    /// wiring so a regression that reverted to direct iteration would
    /// surface.
    @Test
    func newCatDetectedReachesVMViaBroker() async throws {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport, requestTimeout: 2.0)
        let server = ScriptedDeviceServer(transport: transport) { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [])
            case .getPlayHistory: return self.reply(sessions: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        try await client.connect()
        await server.run()
        let broker = DeviceEventBroker(client: client)
        broker.start()
        let vm = HistoryViewModel(
            deviceClient: client,
            eventBroker: broker,
            clock: { Date(timeIntervalSince1970: 1_712_345_678) },
        )
        defer {
            Task {
                broker.stop()
                await server.stop()
                await client.disconnect()
            }
        }

        await vm.start()

        try transport.deliver(event: makeNewCatEvent(trackID: 42, thumbnail: Data([0xAB])))
        await eventually { vm.pendingNewCats.count == 1 }
        #expect(vm.pendingNewCats.first?.trackIDHint == 42)
        #expect(vm.pendingNewCats.first?.thumbnail == Data([0xAB]))
    }

    @Test
    func unsolicitedNewCatDetectedAppendsToQueue() async throws {
        let (vm, transport, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [])
            case .getPlayHistory: return self.reply(sessions: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()

        let push = makeNewCatEvent(trackID: 7, thumbnail: Data([0xFF, 0xD8]))
        try transport.deliver(event: push)
        await eventually { vm.pendingNewCats.count == 1 }
        #expect(vm.pendingNewCats.count == 1)
        let prompt = vm.pendingNewCats.first
        #expect(prompt?.trackIDHint == 7)
        #expect(prompt?.thumbnail == Data([0xFF, 0xD8]))
    }

    @Test
    func duplicateNewCatDetectedCollapsesByTrackID() async throws {
        let (vm, transport, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [])
            case .getPlayHistory: return self.reply(sessions: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        try transport.deliver(event: makeNewCatEvent(trackID: 7, thumbnail: Data([0x01])))
        try transport.deliver(event: makeNewCatEvent(trackID: 7, thumbnail: Data([0x02])))
        try transport.deliver(event: makeNewCatEvent(trackID: 8, thumbnail: Data([0x03])))
        await eventually { vm.pendingNewCats.count == 2 }
        #expect(vm.pendingNewCats.map(\.trackIDHint) == [7, 8])
        // The newer payload for track 7 wins (newer thumbnail).
        let updated = vm.pendingNewCats.first { $0.trackIDHint == 7 }
        #expect(updated?.thumbnail == Data([0x02]))
    }

    @Test
    func solicitedResponsesDoNotEnqueuePrompts() async throws {
        // A cat_profile_list reply that happens to share the
        // request_id with a prior `get_cat_profiles` must NOT be
        // misclassified as an unsolicited NewCatDetected. The check
        // here exercises the `requestID == 0` gate — without it,
        // every reply event would trigger ``handleUnsolicited``.
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [self.makeProfile()])
            case .getPlayHistory: return self.reply(sessions: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        await vm.refreshCats()
        #expect(vm.pendingNewCats.isEmpty)
    }

    // MARK: - identifyNewCat

    @Test
    func identifyNewCatHappyPathDrainsQueue() async throws {
        let pancake = makeProfile(name: "Pancake")
        let identifyName = LockedString()
        let (vm, transport, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [])
            case .getPlayHistory: return self.reply(sessions: [])
            case let .identifyNewCat(req):
                identifyName.set(req.name)
                return self.reply(profiles: [pancake])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        try transport.deliver(event: makeNewCatEvent(trackID: 11, thumbnail: Data()))
        await eventually { vm.pendingNewCats.count == 1 }

        let prompt = vm.pendingNewCats.first!
        let outcome = await vm.identifyNewCat(prompt, name: "Pancake")
        if case .success = outcome { /* good */ } else {
            Issue.record("expected .success, got \(outcome)")
        }
        #expect(identifyName.get() == "Pancake")
        #expect(vm.pendingNewCats.isEmpty)
        if case let .loaded(profiles, _) = vm.catsState {
            #expect(profiles == [pancake])
        } else {
            Issue.record("expected list refreshed after identify, got \(vm.catsState)")
        }
    }

    @Test
    func identifyNewCatRejectsEmptyNameWithoutWireTraffic() async throws {
        let identifyCount = LockedCounter()
        let (vm, transport, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [])
            case .getPlayHistory: return self.reply(sessions: [])
            case .identifyNewCat:
                identifyCount.increment()
                return self.reply(profiles: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        try transport.deliver(event: makeNewCatEvent(trackID: 4, thumbnail: Data()))
        await eventually { vm.pendingNewCats.count == 1 }

        let prompt = vm.pendingNewCats.first!
        let outcome = await vm.identifyNewCat(prompt, name: "")
        guard case let .failure(error) = outcome, case .validation = error else {
            Issue.record("expected .failure(.validation), got \(outcome)")
            return
        }
        #expect(identifyCount.value == 0)
        // Prompt MUST stay in the queue so the user can retry with
        // a valid name.
        #expect(vm.pendingNewCats.count == 1)
    }

    @Test
    func identifyNewCatNotFoundDropsPromptAndSurfacesError() async throws {
        // Device returns NOT_FOUND if the track id has been retired
        // (cat left frame, embedding buffer expired). The VM must
        // drop the prompt — re-trying with the same hint is
        // guaranteed to fail again.
        let (vm, transport, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [])
            case .getPlayHistory: return self.reply(sessions: [])
            case .identifyNewCat:
                return .error(
                    code: HistoryError.notFoundCode,
                    message: "no pending cat with track_id_hint 99",
                )
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        try transport.deliver(event: makeNewCatEvent(trackID: 99, thumbnail: Data()))
        await eventually { vm.pendingNewCats.count == 1 }
        let prompt = vm.pendingNewCats.first!

        let outcome = await vm.identifyNewCat(prompt, name: "Whiskers")
        guard case let .failure(error) = outcome, case .notFound = error else {
            Issue.record("expected .failure(.notFound), got \(outcome)")
            return
        }
        #expect(vm.pendingNewCats.isEmpty)
        #expect(vm.lastActionError != nil)
    }

    @Test
    func identifyNewCatTransientErrorKeepsPromptAndSurfacesError() async throws {
        // A non-NOT_FOUND error must NOT drop the prompt — the user
        // can retry once the device recovers.
        let (vm, transport, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [])
            case .getPlayHistory: return self.reply(sessions: [])
            case .identifyNewCat:
                return .error(code: 99, message: "transient")
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        try transport.deliver(event: makeNewCatEvent(trackID: 5, thumbnail: Data()))
        await eventually { vm.pendingNewCats.count == 1 }
        let prompt = vm.pendingNewCats.first!

        let outcome = await vm.identifyNewCat(prompt, name: "Whiskers")
        if case .failure = outcome { /* good */ } else {
            Issue.record("expected .failure, got \(outcome)")
        }
        #expect(vm.pendingNewCats.count == 1)
        #expect(vm.lastActionError != nil)
    }

    // MARK: - SessionSummary celebration

    /// The device emits a ``SessionSummary`` event when a play
    /// session ends; the VM must surface it as ``pendingSessionCelebration``
    /// so the screen can present the post-session celebration sheet.
    /// This is the in-app counterpart to the FCM push that fires for
    /// the same event — without this hook the device's "session just
    /// ended" moment is silent on a foregrounded app.
    @Test
    func unsolicitedSessionSummaryAssignsCelebration() async throws {
        let (vm, transport, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [self.makeProfile()])
            case .getPlayHistory: return self.reply(sessions: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        #expect(vm.pendingSessionCelebration == nil)

        try transport.deliver(event: makeSessionSummaryEvent(
            catIDs: ["cat-a"],
            durationSec: 720,
            engagementScore: 0.87,
            treatsDispensed: 3,
            pounceCount: 23,
        ))
        await eventually { vm.pendingSessionCelebration != nil }

        let celebration = vm.pendingSessionCelebration
        #expect(celebration?.catIds == ["cat-a"])
        #expect(celebration?.durationSec == 720)
        #expect(celebration?.engagementScore == 0.87)
        #expect(celebration?.treatsDispensed == 3)
        #expect(celebration?.pounceCount == 23)
    }

    /// Most-recent-wins: a second summary arriving before the user
    /// has dismissed the first replaces the pending value rather
    /// than queuing. Sessions are several minutes long so back-to-
    /// back overlap is rare; when it does happen, the user cares
    /// about the latest celebration, not the older one.
    @Test
    func laterSessionSummaryReplacesPendingCelebration() async throws {
        let (vm, transport, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [])
            case .getPlayHistory: return self.reply(sessions: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        try transport.deliver(event: makeSessionSummaryEvent(
            catIDs: ["cat-a"],
            durationSec: 60,
            engagementScore: 0.20,
            treatsDispensed: 0,
            pounceCount: 1,
        ))
        await eventually { vm.pendingSessionCelebration?.durationSec == 60 }

        try transport.deliver(event: makeSessionSummaryEvent(
            catIDs: ["cat-b"],
            durationSec: 900,
            engagementScore: 0.85,
            treatsDispensed: 4,
            pounceCount: 30,
        ))
        await eventually { vm.pendingSessionCelebration?.durationSec == 900 }
        #expect(vm.pendingSessionCelebration?.catIds == ["cat-b"])
        #expect(vm.pendingSessionCelebration?.engagementScore == 0.85)
    }

    /// ``dismissSessionCelebration`` must clear the pending value so
    /// the sheet binding observes the optional flipping to nil and
    /// dismisses. Without this the user's "Nice" tap would do
    /// nothing user-visible.
    @Test
    func dismissSessionCelebrationClearsPending() async throws {
        let (vm, transport, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [])
            case .getPlayHistory: return self.reply(sessions: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        try transport.deliver(event: makeSessionSummaryEvent(
            catIDs: ["cat-a"],
            durationSec: 300,
            engagementScore: 0.65,
            treatsDispensed: 2,
            pounceCount: 12,
        ))
        await eventually { vm.pendingSessionCelebration != nil }

        vm.dismissSessionCelebration()
        #expect(vm.pendingSessionCelebration == nil)
    }

    /// A solicited reply event whose oneof happens to be
    /// ``sessionSummary`` (request_id != 0) must NOT be misclassified
    /// as an unsolicited celebration. The check exercises the
    /// ``requestID == 0`` gate alongside the new oneof handling.
    @Test
    func solicitedSessionSummaryDoesNotMintCelebration() async throws {
        let (vm, transport, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [])
            case .getPlayHistory: return self.reply(sessions: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        var event = makeSessionSummaryEvent(
            catIDs: ["cat-a"],
            durationSec: 100,
            engagementScore: 0.9,
            treatsDispensed: 1,
            pounceCount: 5,
        )
        // Mark the event as a reply by giving it a non-zero
        // request_id. The VM's unsolicited gate must drop it.
        event.requestID = 9_001
        try transport.deliver(event: event)
        // Give the events stream a chance to drain — without a real
        // pendingNewCats / state mutation to wait on, we just settle
        // briefly and assert.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(vm.pendingSessionCelebration == nil)
    }

    @Test
    func dismissNewCatPromptRemovesByTrackID() async throws {
        let (vm, transport, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [])
            case .getPlayHistory: return self.reply(sessions: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        try transport.deliver(event: makeNewCatEvent(trackID: 1, thumbnail: Data()))
        try transport.deliver(event: makeNewCatEvent(trackID: 2, thumbnail: Data()))
        await eventually { vm.pendingNewCats.count == 2 }

        vm.dismissNewCatPrompt(1)
        #expect(vm.pendingNewCats.map(\.trackIDHint) == [2])
        // Dismissing a non-existent id is a no-op.
        vm.dismissNewCatPrompt(999)
        #expect(vm.pendingNewCats.map(\.trackIDHint) == [2])
    }

    // MARK: - lastActionError lifecycle

    @Test
    func dismissActionErrorClearsBanner() async throws {
        let (vm, _, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [self.makeProfile()])
            case .getPlayHistory: return self.reply(sessions: [])
            case .deleteCatProfile:
                return .error(code: 99, message: "boom")
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        _ = await vm.deleteCat(catID: "cat-a")
        #expect(vm.lastActionError != nil)
        vm.dismissActionError()
        #expect(vm.lastActionError == nil)
    }

    // MARK: - Stop cancels events watcher

    @Test
    func stopCancelsEventsWatcher() async throws {
        let (vm, transport, server, client) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles: return self.reply(profiles: [])
            case .getPlayHistory: return self.reply(sessions: [])
            default: return .error(code: 2, message: "unexpected")
            }
        }
        defer { teardown(server: server, client: client) }

        await vm.start()
        vm.stop()

        // After stop, an unsolicited event should NOT enqueue a
        // prompt — give it a moment to land then assert.
        try transport.deliver(event: makeNewCatEvent(trackID: 42, thumbnail: Data()))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(vm.pendingNewCats.isEmpty)
    }

    // MARK: - swapDeviceClient (same-device reconnect)

    /// After a same-device reconnect the host hands the VM a fresh
    /// ``DeviceClient`` and ``DeviceEventBroker`` via ``swapDeviceClient``.
    /// The loaded cat list and the queued naming prompts must survive
    /// the swap; subsequent unsolicited pushes must route through the
    /// NEW broker; subsequent device round-trips must hit the NEW
    /// client.
    @Test
    func swapDeviceClientPreservesLoadedListAndRoutesToNewClient() async throws {
        let oldFetchCount = LockedCounter()
        let (vm, oldTransport, oldServer, oldClient) = try await makeHarness { request in
            switch request.request {
            case .getCatProfiles:
                oldFetchCount.increment()
                return self.reply(profiles: [self.makeProfile(id: "cat-old", name: "Old")])
            case .getPlayHistory:
                return self.reply(sessions: [])
            default:
                return .error(code: 2, message: "unexpected on old client")
            }
        }
        await vm.start()
        await eventually {
            if case let .loaded(profiles, _) = vm.catsState {
                return profiles.count == 1 && profiles[0].catID == "cat-old"
            }
            return false
        }

        // Queue a pending naming prompt before the swap; it must
        // survive because in-flight UI state is the whole point of
        // preserving the VM across the reconnect.
        try oldTransport.deliver(event: makeNewCatEvent(trackID: 7, thumbnail: Data()))
        await eventually { vm.pendingNewCats.count == 1 }

        // Build the fresh client + broker, mirroring composition.
        let newTransport = InMemoryDeviceTransport()
        let newClient = DeviceClient(transport: newTransport, requestTimeout: 2.0)
        let newRefreshCount = LockedCounter()
        let newServer = ScriptedDeviceServer(transport: newTransport, handler: { request in
            switch request.request {
            case .getCatProfiles:
                newRefreshCount.increment()
                return self.reply(profiles: [
                    self.makeProfile(id: "cat-old", name: "Old"),
                    self.makeProfile(id: "cat-new", name: "New"),
                ])
            default:
                return .error(code: 2, message: "unexpected on new client")
            }
        })
        try await newClient.connect()
        await newServer.run()
        let newBroker = DeviceEventBroker(client: newClient)
        newBroker.start()
        defer {
            Task {
                newBroker.stop()
                await newServer.stop()
                await newClient.disconnect()
                await oldServer.stop()
                await oldClient.disconnect()
            }
        }

        vm.swapDeviceClient(newClient, eventBroker: newBroker)

        // Loaded state and pending prompts survived the swap.
        if case let .loaded(profiles, _) = vm.catsState {
            #expect(profiles.count == 1)
            #expect(profiles[0].catID == "cat-old")
        } else {
            Issue.record("expected .loaded preserved across swap, got \(vm.catsState)")
        }
        #expect(vm.pendingNewCats.count == 1)
        #expect(vm.pendingNewCats[0].trackIDHint == 7)

        // A push on the OLD broker is now ignored by the VM (the
        // events task was rebound to the new broker).
        try oldTransport.deliver(event: makeNewCatEvent(trackID: 999, thumbnail: Data()))
        try await Task.sleep(nanoseconds: 60_000_000)
        #expect(vm.pendingNewCats.map(\.trackIDHint) == [7])

        // A push on the NEW broker is observed.
        try newTransport.deliver(event: makeNewCatEvent(trackID: 8, thumbnail: Data()))
        await eventually { vm.pendingNewCats.count == 2 }
        #expect(vm.pendingNewCats.map(\.trackIDHint).sorted() == [7, 8])

        // A subsequent refresh routes to the new client.
        await vm.refreshCats()
        if case let .loaded(profiles, _) = vm.catsState {
            #expect(profiles.map(\.catID).sorted() == ["cat-new", "cat-old"])
        } else {
            Issue.record("expected refreshed list, got \(vm.catsState)")
        }
        #expect(newRefreshCount.value == 1)
        // Original load was the only request that hit the old server.
        #expect(oldFetchCount.value == 1)
    }

    // MARK: - Helpers (event factory)

    nonisolated private func makeNewCatEvent(
        trackID: UInt32,
        thumbnail: Data,
        confidence: Float = 0.42,
    ) -> Catlaser_App_V1_DeviceEvent {
        var event = Catlaser_App_V1_DeviceEvent()
        var detected = Catlaser_App_V1_NewCatDetected()
        detected.trackIDHint = trackID
        detected.thumbnail = thumbnail
        detected.confidence = confidence
        event.newCatDetected = detected
        // Unsolicited push — request_id MUST be zero so the device
        // client routes it onto the events stream rather than to a
        // pending continuation.
        event.requestID = 0
        return event
    }

    nonisolated private func makeSessionSummaryEvent(
        catIDs: [String],
        durationSec: UInt32,
        engagementScore: Float,
        treatsDispensed: UInt32,
        pounceCount: UInt32,
        endedAt: UInt64 = 1_712_345_678,
    ) -> Catlaser_App_V1_DeviceEvent {
        var event = Catlaser_App_V1_DeviceEvent()
        var summary = Catlaser_App_V1_SessionSummary()
        summary.catIds = catIDs
        summary.durationSec = durationSec
        summary.engagementScore = engagementScore
        summary.treatsDispensed = treatsDispensed
        summary.pounceCount = pounceCount
        summary.endedAt = endedAt
        event.sessionSummary = summary
        // Unsolicited — request_id zero so the device client routes
        // it onto the events stream.
        event.requestID = 0
        return event
    }
}

// MARK: - Test sync primitives

/// Tiny locked-string helper used inside scripted handler closures.
final class LockedString: @unchecked Sendable {
    private var value: String = ""
    private let lock = NSLock()
    func set(_ newValue: String) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
    func get() -> String {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Tiny locked-counter helper used to assert request fan-out.
final class LockedCounter: @unchecked Sendable {
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

/// Locked single-range capture for tests that observe one query.
final class LockedRange: @unchecked Sendable {
    private var start: UInt64 = 0
    private var end: UInt64 = 0
    private let lock = NSLock()
    func set(start: UInt64, end: UInt64) {
        lock.lock(); defer { lock.unlock() }
        self.start = start
        self.end = end
    }

    func get() -> (start: UInt64, end: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (start, end)
    }
}

/// Locked range-list capture for tests that observe multiple queries.
final class LockedRangeList: @unchecked Sendable {
    struct Entry: Sendable {
        let start: UInt64
        let end: UInt64
    }

    private var entries: [Entry] = []
    private let lock = NSLock()
    func append(start: UInt64, end: UInt64) {
        lock.lock(); defer { lock.unlock() }
        entries.append(Entry(start: start, end: end))
    }

    func snapshot() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}
