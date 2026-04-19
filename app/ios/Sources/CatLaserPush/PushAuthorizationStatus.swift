import Foundation

/// Cross-platform mirror of ``UNAuthorizationStatus``.
///
/// Exists so the pure ``PushViewModel`` state machine compiles on
/// Linux CI — ``UserNotifications`` is Darwin-only. The Darwin bridge
/// (``PushAuthorizationController``) maps between ``UNAuthorizationStatus``
/// and this type so every screen-state decision goes through a single
/// typed surface.
public enum PushAuthorizationStatus: Sendable, Equatable {
    /// The user has never been prompted. Default state on first
    /// launch. The VM surfaces a pre-prompt primer — once
    /// ``requestAuthorization`` is called the state transitions to
    /// ``authorized`` or ``denied`` and never back.
    case notDetermined

    /// The user granted authorization. ``UNAuthorizationStatus`` may
    /// distinguish `.provisional`, `.ephemeral`, or full
    /// `.authorized`; from this app's perspective any "permission to
    /// deliver" outcome collapses into this single case. The Darwin
    /// bridge makes the collapse explicit so the VM never branches on
    /// provisional-vs-full.
    case authorized

    /// The user denied OS push authorization. Terminal until they
    /// re-grant in Settings; the VM surfaces a "deep-link to Settings"
    /// hint rather than prompting again (the OS would silently
    /// no-op a second prompt in the same session).
    case denied
}
