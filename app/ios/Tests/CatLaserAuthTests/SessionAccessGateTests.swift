#if canImport(LocalAuthentication) && canImport(Darwin)
import Foundation
import LocalAuthentication
import Testing

@testable import CatLaserAuth

/// Controlled clock that tests advance by hand.
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

private final class EvaluationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: Int = 0
    private(set) var lastReason: String?
    private var nextOutcome: Result<Void, Error>

    init(outcome: Result<Void, Error> = .success(())) {
        self.nextOutcome = outcome
    }

    func setOutcome(_ outcome: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        nextOutcome = outcome
    }

    func evaluate(reason: String) throws {
        lock.lock()
        calls += 1
        lastReason = reason
        let outcome = nextOutcome
        lock.unlock()
        switch outcome {
        case .success: return
        case let .failure(error): throw error
        }
    }
}

private func makeGate(
    clock: TestClock,
    recorder: EvaluationRecorder,
    idleTimeout: TimeInterval = 15 * 60,
) -> SessionAccessGate {
    SessionAccessGate(
        idleTimeout: idleTimeout,
        policy: .deviceOwnerAuthentication,
        clock: clock.current,
        contextFactory: { LAContext() },
        evaluator: { reason, _, _ in
            try recorder.evaluate(reason: reason)
        },
    )
}

@Suite("SessionAccessGate")
struct SessionAccessGateTests {
    @Test
    func startsNotFresh() async throws {
        let clock = TestClock()
        let recorder = EvaluationRecorder()
        let gate = makeGate(clock: clock, recorder: recorder)
        #expect(await gate.isFresh() == false)
    }

    @Test
    func authenticateSuccessMarksFresh() async throws {
        let clock = TestClock()
        let recorder = EvaluationRecorder()
        let gate = makeGate(clock: clock, recorder: recorder)
        _ = try await gate.authenticate(reason: "unit test")
        #expect(await gate.isFresh() == true)
        #expect(recorder.calls == 1)
        #expect(recorder.lastReason == "unit test")
    }

    @Test
    func freshnessExpiresAfterIdleWindow() async throws {
        let clock = TestClock()
        let recorder = EvaluationRecorder()
        let gate = makeGate(clock: clock, recorder: recorder, idleTimeout: 60)
        _ = try await gate.authenticate(reason: "r")
        #expect(await gate.isFresh() == true)
        clock.advance(by: 59)
        #expect(await gate.isFresh() == true)
        clock.advance(by: 2) // total 61 > 60
        #expect(await gate.isFresh() == false)
    }

    @Test
    func freshnessExactlyAtBoundaryIsNotFresh() async throws {
        // `isFresh` uses strict inequality: freshness expires AT the timeout,
        // not after it. Security default: when in doubt, prompt.
        let clock = TestClock()
        let recorder = EvaluationRecorder()
        let gate = makeGate(clock: clock, recorder: recorder, idleTimeout: 60)
        _ = try await gate.authenticate(reason: "r")
        clock.advance(by: 60)
        #expect(await gate.isFresh() == false, "at-boundary must be stale — err on the side of prompting")
    }

    @Test
    func authenticateAlwaysPromptsEvenIfFresh() async throws {
        // Per contract: authenticate() always calls the evaluator. The
        // caller needs an LAContext that has *just* satisfied the policy,
        // because an LAContext's usable window for a keychain read is
        // narrow. We must not skip the prompt just because the gate says
        // fresh — that would hand back an unauthenticated LAContext.
        let clock = TestClock()
        let recorder = EvaluationRecorder()
        let gate = makeGate(clock: clock, recorder: recorder)
        _ = try await gate.authenticate(reason: "a")
        _ = try await gate.authenticate(reason: "b")
        #expect(recorder.calls == 2)
    }

    @Test
    func requireStrictAlwaysPrompts() async throws {
        let clock = TestClock()
        let recorder = EvaluationRecorder()
        let gate = makeGate(clock: clock, recorder: recorder)
        _ = try await gate.requireStrict(reason: "strict")
        _ = try await gate.requireStrict(reason: "strict")
        #expect(recorder.calls == 2)
        #expect(recorder.lastReason == "strict")
    }

    @Test
    func invalidateClearsFreshness() async throws {
        let clock = TestClock()
        let recorder = EvaluationRecorder()
        let gate = makeGate(clock: clock, recorder: recorder)
        _ = try await gate.authenticate(reason: "r")
        #expect(await gate.isFresh() == true)
        await gate.invalidate()
        #expect(await gate.isFresh() == false)
    }

    @Test
    func markFreshDoesNotPromptButSetsFreshness() async throws {
        let clock = TestClock()
        let recorder = EvaluationRecorder()
        let gate = makeGate(clock: clock, recorder: recorder)
        await gate.markFresh()
        #expect(recorder.calls == 0, "markFresh must not prompt — identity provider already authenticated the user")
        #expect(await gate.isFresh() == true)
    }

    @Test
    func authenticateFailurePropagatesAndLeavesGateStale() async throws {
        let clock = TestClock()
        let recorder = EvaluationRecorder(outcome: .failure(AuthError.cancelled))
        let gate = makeGate(clock: clock, recorder: recorder)
        await #expect(throws: AuthError.cancelled) {
            _ = try await gate.authenticate(reason: "r")
        }
        #expect(await gate.isFresh() == false, "failed auth must not mark the gate fresh")
    }

    @Test
    func authenticateRethrowsAuthErrorUnchanged() async throws {
        let clock = TestClock()
        let recorder = EvaluationRecorder(outcome: .failure(AuthError.biometricUnavailable("no passcode")))
        let gate = makeGate(clock: clock, recorder: recorder)
        do {
            _ = try await gate.authenticate(reason: "r")
            Issue.record("expected throw")
        } catch AuthError.biometricUnavailable(let msg) {
            #expect(msg == "no passcode")
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test
    func authenticateTranslatesLAErrorUserCancel() async throws {
        let clock = TestClock()
        let recorder = EvaluationRecorder(outcome: .failure(LAError(.userCancel)))
        let gate = makeGate(clock: clock, recorder: recorder)
        await #expect(throws: AuthError.cancelled) {
            _ = try await gate.authenticate(reason: "r")
        }
    }

    @Test
    func authenticateTranslatesLAErrorPasscodeNotSet() async throws {
        let clock = TestClock()
        let recorder = EvaluationRecorder(outcome: .failure(LAError(.passcodeNotSet)))
        let gate = makeGate(clock: clock, recorder: recorder)
        do {
            _ = try await gate.authenticate(reason: "r")
            Issue.record("expected throw")
        } catch let error as AuthError {
            guard case .biometricUnavailable = error else {
                Issue.record("expected biometricUnavailable, got \(error)")
                return
            }
        }
    }

    @Test
    func authenticateTranslatesUnmappedErrorToBiometricFailed() async throws {
        struct Random: Error {}
        let clock = TestClock()
        let recorder = EvaluationRecorder(outcome: .failure(Random()))
        let gate = makeGate(clock: clock, recorder: recorder)
        do {
            _ = try await gate.authenticate(reason: "r")
            Issue.record("expected throw")
        } catch let error as AuthError {
            guard case .biometricFailed = error else {
                Issue.record("expected biometricFailed, got \(error)")
                return
            }
        }
    }
}

#endif
