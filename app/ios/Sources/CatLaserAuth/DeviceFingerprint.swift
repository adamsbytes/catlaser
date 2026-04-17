import Foundation

/// Canonical set of device descriptors that, hashed together, form the
/// per-install fingerprint used to bind a magic-link request to its
/// completion. The raw JSON is NEVER sent over the wire — the client
/// only transmits `sha256(canonicalJSONBytes)` inside a
/// `DeviceAttestation`. This keeps model/OS/locale/timezone/installID
/// out of server-side request logs while still allowing the server to do
/// a byte-equality check between request time and verify time.
///
/// Schema is adapted from `better-auth-device-fingerprint` for native
/// mobile: browser-centric fields (viewport, DPR, etc.) are replaced with
/// identifiers that are stable on mobile but vary between devices —
/// hardware model, OS version, locale, timezone, app build, bundle ID,
/// and the SE-key-derived install ID.
public struct DeviceFingerprint: Sendable, Equatable, Codable {
    public let platform: String
    public let model: String
    public let systemName: String
    public let osVersion: String
    public let locale: String
    public let timezone: String
    public let appVersion: String
    public let appBuild: String
    public let bundleID: String
    public let installID: String

    public init(
        platform: String,
        model: String,
        systemName: String,
        osVersion: String,
        locale: String,
        timezone: String,
        appVersion: String,
        appBuild: String,
        bundleID: String,
        installID: String,
    ) {
        self.platform = platform
        self.model = model
        self.systemName = systemName
        self.osVersion = osVersion
        self.locale = locale
        self.timezone = timezone
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.bundleID = bundleID
        self.installID = installID
    }

    /// Deterministic canonical serialization used as input to the SHA-256
    /// hash placed on the wire.
    ///
    /// Contract (must be preserved for server-port compatibility):
    ///
    /// * JSON object with keys sorted lexicographically.
    /// * UTF-8 encoded.
    /// * No whitespace outside string values.
    /// * Forward slashes NOT escaped (`"/"` not `"\/"`).
    /// * All fields present and non-null; missing values render as empty
    ///   strings (populated by the provider, not omitted).
    public func canonicalJSONBytes() throws(AuthError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(self)
        } catch {
            throw .attestationFailed("canonical JSON encode failed: \(error.localizedDescription)")
        }
    }
}
