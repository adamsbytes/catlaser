import Foundation

/// Deployment-time configuration for the observability pipeline.
/// Validated at construction; production callers build one of these
/// from ``Bundle.main`` and the shared ``AppComposition/DeploymentConfig``.
public struct ObservabilityConfig: Sendable, Equatable {
    /// Absolute URL of the telemetry ingest endpoint. MUST be
    /// https.
    public let telemetryURL: URL
    /// Absolute URL of the crash-payload ingest endpoint. MUST be
    /// https. Split from ``telemetryURL`` because crash uploads can
    /// be large (Apple's `MXDiagnosticPayload` JSON is hundreds of
    /// KB) and typically warrant their own rate-limit bucket.
    public let crashURL: URL
    /// Per-app salt for the device ID hash. Rotating the salt is a
    /// backwards-incompatible change — every existing device reads
    /// as a new installation after a rotation. Do not change
    /// casually.
    public let deviceIDSalt: String
    public let appVersion: String
    public let buildNumber: String
    public let bundleID: String
    /// Directory the breadcrumb snapshot is persisted to. Defaults
    /// to `<caches>/Observability/breadcrumbs.json`.
    public let breadcrumbsURL: URL
    /// Directory that pending tombstones live in.
    public let tombstoneDirectory: URL
    /// Telemetry queue file.
    public let queueURL: URL

    public init(
        telemetryURL: URL,
        crashURL: URL,
        deviceIDSalt: String,
        appVersion: String,
        buildNumber: String,
        bundleID: String,
        breadcrumbsURL: URL,
        tombstoneDirectory: URL,
        queueURL: URL,
    ) throws(ObservabilityConfigError) {
        guard telemetryURL.scheme?.lowercased() == "https" else {
            throw .insecureTelemetryURL
        }
        guard crashURL.scheme?.lowercased() == "https" else {
            throw .insecureCrashURL
        }
        guard !deviceIDSalt.isEmpty else {
            throw .missingSalt
        }
        let trimmedVersion = appVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVersion.isEmpty else { throw .missingVersion }
        let trimmedBuild = buildNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBuild.isEmpty else { throw .missingBuildNumber }
        let trimmedBundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBundle.isEmpty else { throw .missingBundleID }

        self.telemetryURL = telemetryURL
        self.crashURL = crashURL
        self.deviceIDSalt = deviceIDSalt
        self.appVersion = trimmedVersion
        self.buildNumber = trimmedBuild
        self.bundleID = trimmedBundle
        self.breadcrumbsURL = breadcrumbsURL
        self.tombstoneDirectory = tombstoneDirectory
        self.queueURL = queueURL
    }

    /// Convenience factory that derives the observability endpoints
    /// from a coordination-server base URL (the same
    /// ``AuthConfig/baseURL`` that auth + pairing share) and wires
    /// storage paths under the app's caches directory.
    ///
    /// The storage directory is derived via
    /// ``FileManager/urls(for:in:)`` with
    /// ``FileManager.SearchPathDirectory/cachesDirectory`` — crash
    /// reports and breadcrumbs are NEVER backed up to iCloud
    /// (Documents would be) and ARE deleted on cache pressure
    /// (acceptable: the server eventually consumes the payload).
    public static func derived(
        baseURL: URL,
        deviceIDSalt: String,
        appVersion: String,
        buildNumber: String,
        bundleID: String,
        fileManager: FileManager = .default,
    ) throws(ObservabilityConfigError) -> ObservabilityConfig {
        let telemetry = baseURL.appendingPathComponent("api/v1/observability/events")
        let crash = baseURL.appendingPathComponent("api/v1/observability/crashes")
        let cachesRoot = Self.cachesRoot(fileManager: fileManager)
        let root = cachesRoot.appendingPathComponent("Observability", isDirectory: true)
        return try ObservabilityConfig(
            telemetryURL: telemetry,
            crashURL: crash,
            deviceIDSalt: deviceIDSalt,
            appVersion: appVersion,
            buildNumber: buildNumber,
            bundleID: bundleID,
            breadcrumbsURL: root.appendingPathComponent("breadcrumbs.json"),
            tombstoneDirectory: root.appendingPathComponent("Tombstones", isDirectory: true),
            queueURL: root.appendingPathComponent("events.ndjson"),
        )
    }

    private static func cachesRoot(fileManager: FileManager) -> URL {
        if let url = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            return url
        }
        // Fallback — Linux SPM CI does not always surface a caches
        // dir. Use the temp dir so tests can construct a config
        // without a bespoke harness.
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }
}

public enum ObservabilityConfigError: Error, Equatable, Sendable {
    case insecureTelemetryURL
    case insecureCrashURL
    case missingSalt
    case missingVersion
    case missingBuildNumber
    case missingBundleID
}
