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
///    with the subscriber JWT. Once connected, only video tracks whose
///    publisher's `participant.identity` matches the caller-supplied
///    `expectedPublisherIdentity` are surfaced; tracks from any other
///    identity are ignored. This guards against a rogue participant
///    joining the same room and presenting a spoofed video feed — the
///    JWT grant constrains *subscribing*, not *who else is allowed to
///    publish*, so identity-matching at the subscribe delegate is the
///    last line of defence.
/// 2. `disconnect()` forces the room down. The delegate fires a
///    `.disconnected(reason: .localRequest)` event before returning.
///
/// The session is intentionally a single-use handle — after
/// `disconnect()`, further `connect` calls throw. `LiveViewModel`
/// builds one via `sessionFactory` per stream, so that's fine.
///
/// The expected publisher identity is the `catlaser-device-{slug}`
/// string the Python streaming module derives from `DEVICE_SLUG`. The
/// composition root knows which slug the app is paired with (it holds
/// the `PairedDevice` keychain row) and threads the derived identity
/// into `sessionFactory` before handing the VM its closure.
public actor LiveKitStreamSession: LiveStreamSession {
    private let room: Room
    private let delegate: Delegate
    private let eventStream: AsyncStream<LiveStreamEvent>
    private let eventContinuation: AsyncStream<LiveStreamEvent>.Continuation
    private var connected = false
    private var terminated = false

    /// Prefix the device daemon uses for its LiveKit publisher identity.
    /// Must match `_PUBLISHER_IDENTITY_PREFIX` in
    /// `python/catlaser_brain/network/streaming.py`. The full identity
    /// is `"\(devicePublisherIdentityPrefix)\(slug)"`.
    public static let devicePublisherIdentityPrefix = "catlaser-device-"

    /// Compose the expected publisher identity from a paired device
    /// slug. The composition root typically calls this once per
    /// pairing and threads the result into the session factory.
    public static func expectedPublisherIdentity(forDeviceSlug slug: String) -> String {
        "\(devicePublisherIdentityPrefix)\(slug)"
    }

    public init(expectedPublisherIdentity: String) {
        var continuation: AsyncStream<LiveStreamEvent>.Continuation!
        self.eventStream = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.eventContinuation = continuation

        let delegate = Delegate(
            expectedPublisherIdentity: expectedPublisherIdentity,
            continuation: continuation,
        )
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
        private let expectedPublisherIdentity: String
        private let continuation: AsyncStream<LiveStreamEvent>.Continuation

        init(
            expectedPublisherIdentity: String,
            continuation: AsyncStream<LiveStreamEvent>.Continuation,
        ) {
            self.expectedPublisherIdentity = expectedPublisherIdentity
            self.continuation = continuation
            super.init()
        }

        func room(
            _ room: Room,
            participant: RemoteParticipant,
            didSubscribeTrack publication: RemoteTrackPublication,
        ) {
            // Identity match is load-bearing: LiveKit's subscriber
            // token authorises JOINING the room, not WHO ELSE may
            // publish into it. Without this check, any rogue
            // participant that gained publish grants on the same
            // room could surface a video track the app would render
            // as "the cat's home". Track is dropped silently on
            // mismatch — logging plus silent drop lets a legitimate
            // viewer experience age-out gracefully if somehow two
            // publishers collide, while denying a spoofed stream.
            let identity = participant.identity?.stringValue ?? ""
            guard identity == expectedPublisherIdentity else {
                return
            }
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
