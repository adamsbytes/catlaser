import Foundation

/// Canonical set of device descriptors that, hashed together, form the
/// per-install fingerprint used to bind a magic-link request to its
/// completion. The raw JSON is NEVER sent over the wire — the client
/// only transmits `sha256(canonicalJSONBytes)` inside a
/// `DeviceAttestation`. This keeps the underlying identifiers out of
/// server-side request logs while still allowing the server to do a
/// byte-equality check between request time and verify time.
///
/// Only **stable** identifiers participate in the fingerprint:
///
/// * `installID`: base64url(sha256(SPKI)) of the Secure-Enclave-rooted
///   P-256 key. The load-bearing device identity — the SE private key
///   cannot leave the device, so possession of a matching `installID` is
///   proof of the same hardware.
/// * `bundleID`: the app identifier. Immutable between store releases;
///   a changed bundle ID means a different app.
/// * `platform`, `systemName`, `model`: hardware descriptors. `platform`
///   tags the OS family (`ios`, `macos`, …), `systemName` is the
///   canonical OS name, and `model` is the hardware machine identifier
///   (`iPhone15,4`) — all three are fixed for the lifetime of the
///   device.
///
/// **Intentionally excluded** from the fingerprint: `osVersion`,
/// `appVersion`, `appBuild`, `locale`, `timezone`. These drift across
/// the ~5-minute magic-link window during ordinary use (OS point
/// release, TestFlight build promotion, user crosses a time zone,
/// Region change in Settings) and, if hashed in, would generate spurious
/// `DEVICE_MISMATCH` rejections for legitimate users without adding any
/// security value — the `installID` already binds identity to a key
/// that cannot be exfiltrated.
public struct DeviceFingerprint: Sendable, Equatable, Codable {
    public let platform: String
    public let model: String
    public let systemName: String
    public let bundleID: String
    public let installID: String

    public init(
        platform: String,
        model: String,
        systemName: String,
        bundleID: String,
        installID: String,
    ) {
        self.platform = platform
        self.model = model
        self.systemName = systemName
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
