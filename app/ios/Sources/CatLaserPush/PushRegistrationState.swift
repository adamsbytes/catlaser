import Foundation

/// State machine backing the push-notification screen.
///
/// Each state maps to exactly one set of controls in the UI — the VM
/// never has to expose multiple orthogonal booleans. Transitions are
/// unidirectional except for the explicit ``.registered → .registering``
/// re-registration path (e.g. the device dropped and reconnected), and
/// ``.failed → .registering`` for user-initiated retry.
///
/// The state intentionally does NOT store the raw ``Data`` APNs token.
/// Only the ``PushToken`` (validated hex) is kept so a garbage token
/// path is unrepresentable at this layer.
public enum PushRegistrationState: Sendable, Equatable {
    /// Pre-prompt default. The app has not yet asked the OS for push
    /// authorization in this session; the view shows a primer screen.
    case idle

    /// OS permission sheet is on-screen. Terminal values land in
    /// ``authorized(not-yet-registered)``, ``authorizationDenied``, or
    /// ``failed``.
    case requestingAuthorization

    /// User granted OS permission but the APNs registration round-trip
    /// has not completed yet. Holds the UI "you're almost there"
    /// spinner while waiting for APNs → device token callback.
    case awaitingAPNsToken

    /// APNs handed back a device token and the registrar is mid-flight
    /// talking to the device. Holds the UI's "registering" spinner.
    case registering(PushToken)

    /// Successful round-trip with the device. ``token`` is the hex-
    /// encoded APNs token the device has on file; the registrar uses
    /// this to short-circuit a re-register of an unchanged token.
    case registered(PushToken)

    /// OS authorization denied; see ``PushError/authorizationDenied``
    /// for the full rationale.
    case authorizationDenied

    /// Any non-denial failure — APNs registration error, device-channel
    /// failure, device response classified by ``PushError``. The UI
    /// renders the error via ``PushStrings.message(for:)`` and surfaces
    /// a retry button; tapping it transitions back to
    /// ``requestingAuthorization`` or ``registering`` depending on
    /// where we were.
    case failed(PushError)
}

extension PushRegistrationState {
    /// True if an outbound wire call is currently in flight. Guards
    /// against reentrant register / unregister calls.
    public var isBusy: Bool {
        switch self {
        case .requestingAuthorization, .awaitingAPNsToken, .registering:
            true
        case .idle, .registered, .authorizationDenied, .failed:
            false
        }
    }

    /// Token held by the state, if any. Exposed so the registrar can
    /// decide whether a repeated register call is a no-op (token
    /// matches) or a re-register (token differs).
    public var token: PushToken? {
        switch self {
        case let .registering(token), let .registered(token):
            token
        case .idle, .requestingAuthorization, .awaitingAPNsToken, .authorizationDenied, .failed:
            nil
        }
    }
}
