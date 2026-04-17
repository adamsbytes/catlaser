#if canImport(LocalAuthentication) && canImport(Security) && canImport(Darwin)
import Foundation
import LocalAuthentication
import Testing

@testable import CatLaserAuth

private actor MockAuthenticatingStore: AuthenticatingBearerTokenStore {
    enum Event: Equatable, Sendable {
        case save(AuthSession)
        case load(hadContext: Bool)
        case delete
    }

    private var stored: AuthSession?
    private(set) var events: [Event] = []
    private(set) var loadCalls: Int = 0

    init(initial: AuthSession? = nil) {
        self.stored = initial
    }

    func save(_ session: AuthSession) async throws {
        events.append(.save(session))
        stored = session
    }

    func load(authenticatedWith context: LAContext?) async throws -> AuthSession? {
        events.append(.load(hadContext: context != nil))
        loadCalls += 1
        return stored
    }

    func delete() async throws {
        events.append(.delete)
        stored = nil
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.now = start
    }

    func current() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return now
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        now = now.addingTimeInterval(seconds)
    }
}

private final class PromptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count: Int = 0
    private(set) var reasons: [String] = []
    private var outcome: Result<Void, Error>

    init(outcome: Result<Void, Error> = .success(())) {
        self.outcome = outcome
    }

    func setOutcome(_ outcome: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.outcome = outcome
    }

    func bump(reason: String) throws {
        lock.lock()
        count += 1
        reasons.append(reason)
        let result = outcome
        lock.unlock()
        switch result {
        case .success: return
        case let .failure(error): throw error
        }
    }
}

private func makeGate(
    clock: TestClock,
    prompts: PromptCounter,
    idleTimeout: TimeInterval = 15 * 60,
) -> SessionAccessGate {
    SessionAccessGate(
        idleTimeout: idleTimeout,
        policy: .deviceOwnerAuthentication,
        clock: clock.current,
        contextFactory: { LAContext() },
        evaluator: { reason, _, _ in try prompts.bump(reason: reason) },
    )
}

private func makeSession(token: String = "t") -> AuthSession {
    AuthSession(
        bearerToken: token,
        user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
        provider: .apple,
        establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
    )
}

@Suite("GatedBearerTokenStore")
struct GatedBearerTokenStoreTests {
    @Test
    func saveMarksGateFreshAndCachesSession() async throws {
        let clock = TestClock()
        let prompts = PromptCounter()
        let underlying = MockAuthenticatingStore()
        let gate = makeGate(clock: clock, prompts: prompts)
        let store = GatedBearerTokenStore(underlying: underlying, gate: gate)

        let session = makeSession(token: "saved")
        try await store.save(session)

        #expect(await underlying.events == [.save(session)])
        #expect(prompts.count == 0, "save() must not prompt — identity provider already authenticated")

        // Immediately-following load must not prompt and must not hit underlying.
        let loaded = try await store.load()
        #expect(loaded == session)
        #expect(prompts.count == 0, "load() within idle window must not prompt")
        #expect(await underlying.events.count == 1, "load() hit from cache must not re-read keychain")
    }

    @Test
    func coldLoadPromptsAndThreadsContextToUnderlying() async throws {
        let clock = TestClock()
        let prompts = PromptCounter()
        let session = makeSession(token: "cold")
        let underlying = MockAuthenticatingStore(initial: session)
        let gate = makeGate(clock: clock, prompts: prompts)
        let store = GatedBearerTokenStore(underlying: underlying, gate: gate)

        let loaded = try await store.load()
        #expect(loaded == session)
        #expect(prompts.count == 1, "cold load must prompt exactly once")
        let events = await underlying.events
        #expect(events == [.load(hadContext: true)], "underlying must receive the authenticated LAContext")
    }

    @Test
    func repeatedLoadsWithinIdleWindowReturnCacheWithoutPromptOrKeychain() async throws {
        let clock = TestClock()
        let prompts = PromptCounter()
        let session = makeSession(token: "cached")
        let underlying = MockAuthenticatingStore(initial: session)
        let gate = makeGate(clock: clock, prompts: prompts, idleTimeout: 900)
        let store = GatedBearerTokenStore(underlying: underlying, gate: gate)

        _ = try await store.load() // prompts once, caches
        for _ in 0 ..< 20 {
            _ = try await store.load()
        }
        #expect(prompts.count == 1, "only the cold load should prompt; subsequent loads must use the cache")
        #expect(await underlying.loadCalls == 1, "subsequent loads must not re-read the keychain")
    }

    @Test
    func loadAfterIdleExpiryPromptsAgain() async throws {
        let clock = TestClock()
        let prompts = PromptCounter()
        let session = makeSession(token: "expires")
        let underlying = MockAuthenticatingStore(initial: session)
        let gate = makeGate(clock: clock, prompts: prompts, idleTimeout: 100)
        let store = GatedBearerTokenStore(underlying: underlying, gate: gate)

        _ = try await store.load()
        #expect(prompts.count == 1)
        clock.advance(by: 101)
        _ = try await store.load()
        #expect(prompts.count == 2, "idle window expired — must re-prompt before returning cached token")
        #expect(await underlying.loadCalls == 2, "expired idle window must re-read keychain under a fresh LAContext")
    }

    @Test
    func invalidateSessionForcesPromptOnNextLoad() async throws {
        let clock = TestClock()
        let prompts = PromptCounter()
        let session = makeSession(token: "invalidate")
        let underlying = MockAuthenticatingStore(initial: session)
        let gate = makeGate(clock: clock, prompts: prompts)
        let store = GatedBearerTokenStore(underlying: underlying, gate: gate)

        try await store.save(session)
        _ = try await store.load()
        #expect(prompts.count == 0) // save marked fresh, load from cache

        await store.invalidateSession()
        _ = try await store.load()
        #expect(prompts.count == 1, "invalidateSession must force a re-prompt on the next load")
    }

    @Test
    func deleteClearsCacheAndInvalidatesGate() async throws {
        let clock = TestClock()
        let prompts = PromptCounter()
        let session = makeSession()
        let underlying = MockAuthenticatingStore(initial: session)
        let gate = makeGate(clock: clock, prompts: prompts)
        let store = GatedBearerTokenStore(underlying: underlying, gate: gate)

        try await store.save(session)
        try await store.delete()

        let events = await underlying.events
        #expect(events.contains(.delete))
        #expect(await gate.isFresh() == false, "delete() must invalidate the gate — a stolen unlocked phone cannot recover the token from memory")
    }

    @Test
    func loadFailsWhenUserCancelsBiometric() async throws {
        let clock = TestClock()
        let prompts = PromptCounter(outcome: .failure(AuthError.cancelled))
        let underlying = MockAuthenticatingStore(initial: makeSession())
        let gate = makeGate(clock: clock, prompts: prompts)
        let store = GatedBearerTokenStore(underlying: underlying, gate: gate)

        await #expect(throws: AuthError.cancelled) {
            _ = try await store.load()
        }
        let events = await underlying.events
        #expect(events.isEmpty, "keychain must not be read when biometric auth was cancelled")
    }

    @Test
    func requireLiveVideoAlwaysPromptsEvenWhenFresh() async throws {
        let clock = TestClock()
        let prompts = PromptCounter()
        let underlying = MockAuthenticatingStore(initial: makeSession())
        let gate = makeGate(clock: clock, prompts: prompts)
        let store = GatedBearerTokenStore(underlying: underlying, gate: gate)

        try await store.save(makeSession()) // gate fresh
        #expect(await gate.isFresh() == true)

        try await store.requireLiveVideo()
        #expect(prompts.count == 1, "requireLiveVideo must prompt even when gate is fresh")

        try await store.requireLiveVideo()
        #expect(prompts.count == 2, "each requireLiveVideo call must re-prompt")
    }

    @Test
    func requireLiveVideoFailurePropagatesAndDoesNotReadKeychain() async throws {
        let clock = TestClock()
        let prompts = PromptCounter(outcome: .failure(AuthError.cancelled))
        let underlying = MockAuthenticatingStore(initial: makeSession())
        let gate = makeGate(clock: clock, prompts: prompts)
        let store = GatedBearerTokenStore(underlying: underlying, gate: gate)

        try await store.save(makeSession())
        let eventsBefore = await underlying.events

        await #expect(throws: AuthError.cancelled) {
            try await store.requireLiveVideo()
        }
        let eventsAfter = await underlying.events
        #expect(eventsBefore.count == eventsAfter.count, "requireLiveVideo must never touch the keychain")
    }

    @Test
    func saveAfterInvalidateRestoresCache() async throws {
        let clock = TestClock()
        let prompts = PromptCounter()
        let underlying = MockAuthenticatingStore()
        let gate = makeGate(clock: clock, prompts: prompts)
        let store = GatedBearerTokenStore(underlying: underlying, gate: gate)

        try await store.save(makeSession(token: "one"))
        await store.invalidateSession()

        // Save again → cache restored, gate marked fresh, next load hits cache.
        try await store.save(makeSession(token: "two"))
        let loaded = try await store.load()
        #expect(loaded?.bearerToken == "two")
        #expect(prompts.count == 0, "save → load round trip must not prompt")
    }
}

#endif
