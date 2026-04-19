import Foundation

/// Abstracts the LiveKit client from the view-model layer.
///
/// `LiveViewModel` drives a session through three states:
///
/// 1. Idle / never connected.
/// 2. `connect(using:)` — dial the LiveKit room, subscribe to the
///    device's published video track. On success, yields a
///    sequence of `.connecting` → `.streaming(videoTrack)` events on
///    the `events` stream. On failure, the call throws.
/// 3. `disconnect()` — idempotent tear-down.
///
/// Two implementations ship with the module:
///
/// * `LiveKitStreamSession` — the real thing, active when the host
///   target includes `LiveKit` via Swift Package Manager or Xcode.
/// * `MockLiveStreamSession` (in the test target) — scriptable,
///   deterministic, runs on Linux.
///
/// The session is an actor so `LiveViewModel` can drive it from the
/// `MainActor` without blocking.
public protocol LiveStreamSession: Sendable {
    /// Events emitted by the session. The stream terminates when the
    /// session is torn down; consumers should treat end-of-stream as
    /// a normal end-of-life signal.
    var events: AsyncStream<LiveStreamEvent> { get async }

    /// Connect to LiveKit and subscribe to the device's video track.
    /// Returns once the subscription is established. Throws on
    /// connect / subscribe failure; the session remains usable for
    /// another connect attempt after a throw.
    func connect(using credentials: LiveStreamCredentials) async throws

    /// Disconnect. Idempotent.
    func disconnect() async
}

/// Opaque handle to the subscribed video track that the view layer
/// renders. `Sendable` so it can be stored in the `@Observable` VM.
public protocol LiveVideoTrackHandle: Sendable {
    /// Stable identifier for the track. Used for diagnostics and in
    /// tests; the SwiftUI view doesn't need it.
    var trackID: String { get }
}

/// Events published by a `LiveStreamSession`.
public enum LiveStreamEvent: Sendable, Equatable {
    case connecting
    case streaming(any LiveVideoTrackHandle)
    case disconnected(reason: LiveStreamDisconnectReason)
    /// A participant joined the room and published a video track,
    /// but their `identity` did not match the expected
    /// `catlaser-device-<slug>` identity derived from the
    /// pairing. An impostor with publish grants. The VM turns this
    /// into a terminal `.failed` state so the user sees a clear
    /// error rather than spinning indefinitely behind a silent
    /// drop. ``identity`` surfaces the offender's claimed identity
    /// for diagnostics — never rendered unescaped to the UI.
    case unexpectedPublisher(identity: String)

    public static func == (lhs: LiveStreamEvent, rhs: LiveStreamEvent) -> Bool {
        switch (lhs, rhs) {
        case (.connecting, .connecting):
            true
        case let (.streaming(a), .streaming(b)):
            a.trackID == b.trackID
        case let (.disconnected(a), .disconnected(b)):
            a == b
        case let (.unexpectedPublisher(a), .unexpectedPublisher(b)):
            a == b
        default:
            false
        }
    }
}

public enum LiveStreamDisconnectReason: Sendable, Equatable {
    /// The local side (view model, user, app lifecycle) asked to stop.
    case localRequest
    /// The LiveKit server dropped the room or the publisher stopped.
    case serverClosed(String?)
    /// The network underneath LiveKit failed (e.g. Wi-Fi drop, TLS).
    case networkFailure(String?)
}

/// Constants shared between the LiveKit-backed session and the
/// composition root. Kept out of ``LiveKitStreamSession`` itself so
/// non-LiveKit targets (SPM Linux CI) can still reference the
/// expected-identity derivation without conditionally importing the
/// LiveKit SDK.
public enum LiveStreamIdentity {
    /// Prefix the device daemon uses for its LiveKit publisher
    /// identity. Must match `_PUBLISHER_IDENTITY_PREFIX` in
    /// `python/catlaser_brain/network/streaming.py`.
    public static let devicePublisherIdentityPrefix = "catlaser-device-"

    /// Compose the expected publisher identity from a paired device
    /// slug. The composition root calls this once per pairing and
    /// threads the result into the session factory.
    public static func expectedPublisherIdentity(forDeviceSlug slug: String) -> String {
        "\(devicePublisherIdentityPrefix)\(slug)"
    }
}
