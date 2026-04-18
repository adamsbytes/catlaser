#if canImport(LiveKit)
import Foundation
import LiveKit

/// Production `LiveStreamSession` implemented on LiveKit's Swift SDK.
///
/// Activated whenever the host target links the `LiveKit` module (via
/// SwiftPM or Xcode). On Linux CI the import fails and the whole file
/// is skipped, keeping `swift test` green; the view model is driven
/// by a mock session in that environment.
///
/// Lifecycle:
///
/// 1. `connect(using:)` builds a fresh `Room` and `room.connect(...)`s
///    with the subscriber JWT. Once connected, the first published
///    remote video track from the device participant (identity
///    `catlaser-device`, matching `streaming.py`) is surfaced as a
///    `LiveKitVideoTrackHandle` on the `events` stream.
/// 2. `disconnect()` forces the room down. The delegate fires a
///    `.disconnected(reason: .localRequest)` event before returning.
///
/// The session is intentionally a single-use handle — after
/// `disconnect()`, further `connect` calls throw. `LiveViewModel`
/// builds one via `sessionFactory` per stream, so that's fine.
public actor LiveKitStreamSession: LiveStreamSession {
    private let room: Room
    private let delegate: Delegate
    private let eventStream: AsyncStream<LiveStreamEvent>
    private let eventContinuation: AsyncStream<LiveStreamEvent>.Continuation
    private var connected = false
    private var terminated = false

    /// LiveKit identity for the device-side participant. Must match
    /// `_PUBLISHER_IDENTITY` in `python/catlaser_brain/network/streaming.py`.
    public static let deviceIdentity = "catlaser-device"

    public init() {
        var continuation: AsyncStream<LiveStreamEvent>.Continuation!
        self.eventStream = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.eventContinuation = continuation

        let delegate = Delegate(continuation: continuation)
        self.delegate = delegate
        self.room = Room(delegate: delegate)
    }

    public var events: AsyncStream<LiveStreamEvent> {
        get async { eventStream }
    }

    public func connect(using credentials: LiveStreamCredentials) async throws {
        guard !terminated else {
            throw LiveKitSessionError.terminated
        }
        guard !connected else {
            throw LiveKitSessionError.alreadyConnected
        }
        eventContinuation.yield(.connecting)
        do {
            try await room.connect(
                url: credentials.url.absoluteString,
                token: credentials.token,
                connectOptions: ConnectOptions(autoSubscribe: true),
            )
        } catch {
            eventContinuation.yield(.disconnected(reason: .networkFailure(error.localizedDescription)))
            throw error
        }
        connected = true
    }

    public func disconnect() async {
        guard !terminated else { return }
        terminated = true
        if connected {
            await room.disconnect()
            connected = false
        }
        eventContinuation.yield(.disconnected(reason: .localRequest))
        eventContinuation.finish()
    }

    // MARK: - Delegate

    private final class Delegate: NSObject, RoomDelegate, @unchecked Sendable {
        private let continuation: AsyncStream<LiveStreamEvent>.Continuation

        init(continuation: AsyncStream<LiveStreamEvent>.Continuation) {
            self.continuation = continuation
            super.init()
        }

        func room(
            _ room: Room,
            participant _: RemoteParticipant,
            didSubscribeTrack publication: RemoteTrackPublication,
        ) {
            guard publication.kind == .video,
                  let track = publication.track as? VideoTrack else {
                return
            }
            continuation.yield(.streaming(LiveKitVideoTrackHandle(track: track)))
        }

        func room(_ room: Room, didDisconnect error: Error?) {
            if let error {
                continuation.yield(.disconnected(reason: .networkFailure(error.localizedDescription)))
            } else {
                continuation.yield(.disconnected(reason: .serverClosed(nil)))
            }
            continuation.finish()
        }
    }
}

/// Track handle wrapping a LiveKit `VideoTrack`.
public struct LiveKitVideoTrackHandle: LiveVideoTrackHandle, @unchecked Sendable {
    public let track: VideoTrack

    public var trackID: String { track.sid?.stringValue ?? track.name }

    init(track: VideoTrack) {
        self.track = track
    }
}

public enum LiveKitSessionError: Error, Equatable, Sendable {
    case alreadyConnected
    case terminated
}
#endif
