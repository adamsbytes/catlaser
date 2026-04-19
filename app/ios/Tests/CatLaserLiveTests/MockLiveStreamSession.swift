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
    }

    // MARK: - Test controls

    func setConnectBehavior(_ behavior: ConnectBehavior) async {
        await state.setConnectBehavior(behavior)
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
    var connectCount: Int = 0
    var disconnectCount: Int = 0
    var lastCredentials: LiveStreamCredentials?
    private var manualContinuation: CheckedContinuation<Result<Void, any Error>, any Error>?

    func setConnectBehavior(_ behavior: MockLiveStreamSession.ConnectBehavior) {
        self.connectBehavior = behavior
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
}

/// Opaque handle that tests assert on via `trackID`.
struct MockTrack: LiveVideoTrackHandle, Sendable {
    let id: String
    var trackID: String { id }
}

enum MockError: Error, Equatable, Sendable {
    case forcedFailure
}
