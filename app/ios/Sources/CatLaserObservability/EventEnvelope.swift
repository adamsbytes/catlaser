import Foundation

/// Device + session metadata attached to every upload. The ingest
/// side uses it to group events by installation and by launch, and
/// to reject stale or malformed batches.
///
/// Every field is stringly typed on the wire so a schema change at
/// the ingest side does not break older clients. Empty strings are
/// rejected at construction time — a partial envelope is worse than
/// no envelope.
public struct ObservabilityContext: Sendable, Codable, Equatable {
    /// SHA-256 of `identifierForVendor` + ``deviceIDSalt``. Never the
    /// raw identifier.
    public let deviceIDHash: String
    /// UUID regenerated at every process launch. Groups events from
    /// a single run.
    public let sessionID: String
    /// Human-readable version from `CFBundleShortVersionString`.
    public let appVersion: String
    /// Build number from `CFBundleVersion`.
    public let buildNumber: String
    public let bundleID: String
    public let platform: String
    public let osVersion: String
    public let deviceModel: String
    public let locale: String

    public init(
        deviceIDHash: String,
        sessionID: String,
        appVersion: String,
        buildNumber: String,
        bundleID: String,
        platform: String,
        osVersion: String,
        deviceModel: String,
        locale: String,
    ) {
        self.deviceIDHash = deviceIDHash
        self.sessionID = sessionID
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.bundleID = bundleID
        self.platform = platform
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.locale = locale
    }

    enum CodingKeys: String, CodingKey {
        case deviceIDHash = "device_id_hash"
        case sessionID = "session_id"
        case appVersion = "app_version"
        case buildNumber = "build_number"
        case bundleID = "bundle_id"
        case platform
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case locale
    }
}

/// Single on-wire event.
public struct EventEnvelope: Sendable, Codable, Equatable {
    /// Locally-generated UUID. The ingest endpoint uses it as an
    /// idempotency key so an upload retried after a network drop
    /// does not double-count the event.
    public let id: String
    /// Stable event name (e.g. `sign_in_succeeded`).
    public let name: String
    /// Event-specific attributes, stringly typed.
    public let attributes: [String: String]
    /// Monotonic nanoseconds since process start. Orders events
    /// within a single session without relying on wall clock.
    public let monotonicNS: UInt64
    /// Wall-clock timestamp at record time (UTC, ISO-8601 with
    /// milliseconds).
    public let wallTimeUTC: String

    public init(
        id: String,
        name: String,
        attributes: [String: String],
        monotonicNS: UInt64,
        wallTimeUTC: String,
    ) {
        self.id = id
        self.name = name
        self.attributes = attributes
        self.monotonicNS = monotonicNS
        self.wallTimeUTC = wallTimeUTC
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case attributes
        case monotonicNS = "monotonic_ns"
        case wallTimeUTC = "wall_time_utc"
    }
}

/// Wrapper submitted to the ingest endpoint.
public struct UploadBatch: Sendable, Codable, Equatable {
    public let context: ObservabilityContext
    public let events: [EventEnvelope]
    /// Optional crash payload attached when the batch is a crash
    /// delivery. `nil` on normal telemetry uploads.
    public let crash: CrashPayload?

    public init(
        context: ObservabilityContext,
        events: [EventEnvelope],
        crash: CrashPayload? = nil,
    ) {
        self.context = context
        self.events = events
        self.crash = crash
    }
}

/// Crash payload shape. Carries the raw diagnostic blob (`MetricKit`
/// JSON representation or the serialized tombstone) plus the trailing
/// breadcrumb snapshot captured alongside it.
public struct CrashPayload: Sendable, Codable, Equatable {
    public enum Source: String, Sendable, Codable, Equatable {
        case metricKit = "metric_kit"
        case tombstone
    }

    public let id: String
    public let source: Source
    /// Raw JSON payload as a UTF-8 string. For MetricKit deliveries
    /// this is `MXDiagnosticPayload.jsonRepresentation`; for tombstones
    /// it is the encoded ``Tombstone``.
    public let payload: String
    public let breadcrumbs: [Breadcrumb]

    public init(
        id: String,
        source: Source,
        payload: String,
        breadcrumbs: [Breadcrumb],
    ) {
        self.id = id
        self.source = source
        self.payload = payload
        self.breadcrumbs = breadcrumbs
    }
}
