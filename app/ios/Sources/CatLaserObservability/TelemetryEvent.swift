import Foundation

/// Closed set of events the app records.
///
/// Every user-visible flow that we want counts for resolves to one
/// of these cases. Adding an event is a code change here — the
/// backend accepts a fixed vocabulary of `event_name`s and an
/// unknown name is dropped on the floor, so emission and ingestion
/// stay in lockstep.
///
/// Each case carries strictly-typed associated values. Free-string
/// attributes are forbidden; anything that looks like PII (emails,
/// user-supplied names, device-local identifiers) is out-of-scope
/// for telemetry and MUST be recorded as a breadcrumb on the device
/// only.
public enum TelemetryEvent: Sendable, Codable, Equatable {
    // MARK: - App lifecycle
    case appLaunched(coldStart: Bool)
    case appBackgrounded
    case appForegrounded

    // MARK: - Auth
    case signInStarted(provider: AuthProvider)
    case signInSucceeded(provider: AuthProvider)
    case signInFailed(provider: AuthProvider, reason: FailureReason)
    case sessionExpired
    case signedOut

    // MARK: - Pairing
    case pairingStarted(entry: PairingEntry)
    case pairingSucceeded
    case pairingFailed(reason: FailureReason)
    case unpaired

    // MARK: - Connection
    case deviceConnected
    case deviceDisconnected(reason: FailureReason)
    case deviceReconnecting(attempt: UInt8)

    // MARK: - Live
    case liveStreamRequested
    case liveStreamStarted
    case liveStreamStopped(reason: StreamStopReason)
    case liveStreamFailed(reason: FailureReason)

    // MARK: - Push
    case pushPrompted
    case pushAuthorized
    case pushDenied
    case pushRegistered

    // MARK: - Schedule
    case scheduleLoaded(entryCount: UInt16)
    case scheduleSaved(entryCount: UInt16)

    // MARK: - History
    case historyLoaded(catCount: UInt16, sessionCount: UInt16)
    case catProfileEdited
    case catProfileDeleted
    case newCatIdentified

    // MARK: - Consent
    case consentGranted(crashReporting: Bool, telemetry: Bool)
    case consentUpdated(crashReporting: Bool, telemetry: Bool)
    case consentDeclined

    // MARK: - Observability self-reports
    case crashReportDelivered(source: CrashSource)

    /// Which sign-in provider was involved. A tag only; identity is
    /// never attached to the event.
    public enum AuthProvider: String, Sendable, Codable, Equatable {
        case apple
        case google
        case magicLink = "magic_link"
    }

    /// How the user entered the pairing flow.
    public enum PairingEntry: String, Sendable, Codable, Equatable {
        case qrScan = "qr_scan"
        case manualEntry = "manual_entry"
    }

    /// Why a live stream ended — user action vs. an error path.
    public enum StreamStopReason: String, Sendable, Codable, Equatable {
        case userStopped = "user_stopped"
        case backgrounded
        case cancelled
    }

    /// Where a crash payload originated.
    public enum CrashSource: String, Sendable, Codable, Equatable {
        /// Delivered via ``MXMetricManager`` on the next launch.
        case metricKit = "metric_kit"
        /// Captured in-process by the ``NSException`` / signal
        /// handler and persisted to a tombstone file.
        case tombstone
    }

    /// Bounded reason tag attached to failure events. A caller picks
    /// the closest match; freeform detail is OUT OF SCOPE for
    /// telemetry (it lives on the on-device breadcrumb ring, which is
    /// only uploaded as part of a crash payload under a separate
    /// consent toggle).
    public enum FailureReason: String, Sendable, Codable, Equatable {
        case cancelled
        case network
        case timeout
        case offline
        case unauthorized
        case forbidden
        case notFound = "not_found"
        case conflict
        case rateLimited = "rate_limited"
        case serverError = "server_error"
        case validation
        case biometricDenied = "biometric_denied"
        case permissionDenied = "permission_denied"
        case configurationInvalid = "configuration_invalid"
        case unknown
    }

    /// Stable wire name the backend ingests. Picked so a rename of a
    /// Swift case name never cascades into a telemetry schema break.
    public var wireName: String {
        switch self {
        case .appLaunched: "app_launched"
        case .appBackgrounded: "app_backgrounded"
        case .appForegrounded: "app_foregrounded"
        case .signInStarted: "sign_in_started"
        case .signInSucceeded: "sign_in_succeeded"
        case .signInFailed: "sign_in_failed"
        case .sessionExpired: "session_expired"
        case .signedOut: "signed_out"
        case .pairingStarted: "pairing_started"
        case .pairingSucceeded: "pairing_succeeded"
        case .pairingFailed: "pairing_failed"
        case .unpaired: "unpaired"
        case .deviceConnected: "device_connected"
        case .deviceDisconnected: "device_disconnected"
        case .deviceReconnecting: "device_reconnecting"
        case .liveStreamRequested: "live_stream_requested"
        case .liveStreamStarted: "live_stream_started"
        case .liveStreamStopped: "live_stream_stopped"
        case .liveStreamFailed: "live_stream_failed"
        case .pushPrompted: "push_prompted"
        case .pushAuthorized: "push_authorized"
        case .pushDenied: "push_denied"
        case .pushRegistered: "push_registered"
        case .scheduleLoaded: "schedule_loaded"
        case .scheduleSaved: "schedule_saved"
        case .historyLoaded: "history_loaded"
        case .catProfileEdited: "cat_profile_edited"
        case .catProfileDeleted: "cat_profile_deleted"
        case .newCatIdentified: "new_cat_identified"
        case .consentGranted: "consent_granted"
        case .consentUpdated: "consent_updated"
        case .consentDeclined: "consent_declined"
        case .crashReportDelivered: "crash_report_delivered"
        }
    }

    /// Render the event's associated values as a string-keyed attribute
    /// dictionary for wire serialisation. All values are stringly-typed
    /// on the wire for schema flexibility — the ingest side validates
    /// per-event.
    public var wireAttributes: [String: String] {
        switch self {
        case let .appLaunched(coldStart):
            return ["cold_start": coldStart ? "true" : "false"]
        case .appBackgrounded, .appForegrounded,
             .sessionExpired, .signedOut,
             .pairingSucceeded, .unpaired,
             .deviceConnected,
             .liveStreamRequested, .liveStreamStarted,
             .pushPrompted, .pushAuthorized, .pushDenied, .pushRegistered,
             .catProfileEdited, .catProfileDeleted, .newCatIdentified,
             .consentDeclined:
            return [:]
        case let .signInStarted(provider),
             let .signInSucceeded(provider):
            return ["provider": provider.rawValue]
        case let .signInFailed(provider, reason):
            return ["provider": provider.rawValue, "reason": reason.rawValue]
        case let .pairingStarted(entry):
            return ["entry": entry.rawValue]
        case let .pairingFailed(reason),
             let .deviceDisconnected(reason),
             let .liveStreamFailed(reason):
            return ["reason": reason.rawValue]
        case let .deviceReconnecting(attempt):
            return ["attempt": String(attempt)]
        case let .liveStreamStopped(reason):
            return ["reason": reason.rawValue]
        case let .scheduleLoaded(entryCount),
             let .scheduleSaved(entryCount):
            return ["entry_count": String(entryCount)]
        case let .historyLoaded(catCount, sessionCount):
            return [
                "cat_count": String(catCount),
                "session_count": String(sessionCount),
            ]
        case let .consentGranted(crash, telemetry),
             let .consentUpdated(crash, telemetry):
            return [
                "crash_reporting": crash ? "true" : "false",
                "telemetry": telemetry ? "true" : "false",
            ]
        case let .crashReportDelivered(source):
            return ["source": source.rawValue]
        }
    }
}
