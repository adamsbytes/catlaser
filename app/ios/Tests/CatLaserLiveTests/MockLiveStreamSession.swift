import CatLaserLive
import Foundation

/// Fully-scriptable `LiveStreamSession` for `LiveViewModel` tests.
///
/// The mock exposes three imperative hooks:
///
/// * `setConnectBehavior(...)` — make the next `connect(using:)` call
///   succeed or throw a specified error.
/// * `emitStreaming(trackID:)` — push a `.streaming(track)` event
///   onto the events stream after a successful connect.
/// * `emit(disconnectReason:)` — push a `.disconnected(reason:)`
///   event onto the events stream to simulate a server-side or
///   network-side drop.
///
/// Every call is observable via `connectCount`, `disconnectCount`,
/// and `lastCredentials` so the view-model contract can be asserted
/// without peeking into the VM's private state.
final class MockLiveStreamSession: LiveStreamSession, @unchecked Sendable {
    enum ConnectBehavior: Sendable {
        case succeed
        case fail(any Error & Sendable)
        /// Block until the test explicitly resumes via
        /// `finishConnect(result:)`.
        case manual
    }

    /// Behaviour for `disconnect()`. Defaults to `.immediate` so
    /// every existing test that did not care about the stop path
    /// continues to see the prior behaviour; the `.manual` variant
    /// parks the caller until the test explicitly resumes and is the
    /// scaffolding for the stop-watchdog coverage.
    enum DisconnectBehavior: Sendable {
        case immediate
        case manual
    }

    private let state = MockState()

    private let eventStream: AsyncStream<LiveStreamEvent>
    private let eventContinuation: AsyncStream<LiveStreamEvent>.Continuation

    init() {
        var captured: AsyncStream<LiveStreamEvent>.Continuation!
        self.eventStream = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        self.eventContinuation = captured
    }

    var events: AsyncStream<LiveStreamEvent> {
        get async { eventStream }
    }

    func connect(using credentials: LiveStreamCredentials) async throws {
        await state.recordConnect(credentials: credentials)
        eventContinuation.yield(.connecting)
        let behavior = await state.connectBehavior
        switch behavior {
        case .succeed:
            return
        case let .fail(error):
            throw error
        case .manual:
            let outcome = try await state.awaitManualCompletion()
            switch outcome {
            case .success:
                return
            case let .failure(error):
                throw error
            }
        }
    }

    func disconnect() async {
        await state.recordDisconnect()
        eventContinuation.yield(.disconnected(reason: .localRequest))
        if await state.disconnectBehavior == .manual {
            await state.awaitManualDisconnect()
        }
    }

    // MARK: - Test controls

    func setConnectBehavior(_ behavior: ConnectBehavior) async {
        await state.setConnectBehavior(behavior)
    }

    func setDisconnectBehavior(_ behavior: DisconnectBehavior) async {
        await state.setDisconnectBehavior(behavior)
    }

    /// Unblock any `disconnect()` call parked on the `.manual`
    /// behaviour. Safe to call when nothing is parked.
    func releaseManualDisconnect() async {
        await state.releaseManualDisconnect()
    }

    func finishManualConnect(success: Bool) async {
        if success {
            await state.finishManual(outcome: .success(()))
        } else {
            await state.finishManual(outcome: .failure(MockError.forcedFailure))
        }
    }

    func emitStreaming(trackID: String) {
        eventContinuation.yield(.streaming(MockTrack(id: trackID)))
    }

    func emit(disconnectReason: LiveStreamDisconnectReason) {
        eventContinuation.yield(.disconnected(reason: disconnectReason))
    }

    /// Push an `.unexpectedPublisher` event — the production
    /// `LiveKitStreamSession.Delegate` yields this on identity
    /// mismatch. Tests use it to exercise the VM's terminal-failure
    /// path without spinning up a real LiveKit SDK.
    func emitUnexpectedPublisher(identity: String) {
        eventContinuation.yield(.unexpectedPublisher(identity: identity))
    }

    func finishEvents() {
        eventContinuation.finish()
    }

    // MARK: - Observables

    var connectCount: Int {
        get async { await state.connectCount }
    }

    var disconnectCount: Int {
        get async { await state.disconnectCount }
    }

    var lastCredentials: LiveStreamCredentials? {
        get async { await state.lastCredentials }
    }
}

private actor MockState {
    var connectBehavior: MockLiveStreamSession.ConnectBehavior = .succeed
    var disconnectBehavior: MockLiveStreamSession.DisconnectBehavior = .immediate
    var connectCount: Int = 0
    var disconnectCount: Int = 0
    var lastCredentials: LiveStreamCredentials?
    private var manualContinuation: CheckedContinuation<Result<Void, any Error>, any Error>?
    private var manualDisconnectContinuations: [CheckedContinuation<Void, Never>] = []

    func setConnectBehavior(_ behavior: MockLiveStreamSession.ConnectBehavior) {
        self.connectBehavior = behavior
    }

    func setDisconnectBehavior(_ behavior: MockLiveStreamSession.DisconnectBehavior) {
        self.disconnectBehavior = behavior
    }

    func recordConnect(credentials: LiveStreamCredentials) {
        connectCount += 1
        lastCredentials = credentials
    }

    func recordDisconnect() {
        disconnectCount += 1
    }

    func awaitManualCompletion() async throws -> Result<Void, any Error> {
        try await withCheckedThrowingContinuation { continuation in
            manualContinuation = continuation
        }
    }

    func finishManual(outcome: Result<Void, any Error>) {
        manualContinuation?.resume(returning: outcome)
        manualContinuation = nil
    }

    /// Park the current ``disconnect()`` call until the test
    /// releases it. Multiple concurrent disconnects each get their
    /// own continuation so the release is broadcast cleanly.
    func awaitManualDisconnect() async {
        await withCheckedContinuation { continuation in
            manualDisconnectContinuations.append(continuation)
        }
    }

    func releaseManualDisconnect() {
        let pending = manualDisconnectContinuations
        manualDisconnectContinuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

/// Opaque handle that tests assert on via `trackID`.
struct MockTrack: LiveVideoTrackHandle, Sendable {
    let id: String
    var trackID: String { id }
}

enum MockError: Error, Equatable, Sendable {
    case forcedFailure
}
