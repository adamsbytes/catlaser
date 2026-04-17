import Foundation

/// The request-time device fingerprint payload sent to the coordination server
/// when requesting a magic link. The same fingerprint is re-sent at link
/// completion; the server compares the two to defend against email-interception
/// phishing (an attacker who captures the email cannot complete sign-in from
/// a different device).
///
/// Schema is vendored from `better-auth-device-fingerprint` and adapted for
/// native mobile clients — browser-centric fields (viewport, DPR, etc.) are
/// replaced with identifiers that are stable on mobile but vary between
/// devices: hardware model, OS version, locale, timezone, app build, and a
/// Keychain-bound install ID.
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
}

public enum DeviceFingerprintEncoder {
    /// Wire header name consumed by the server-side plugin.
    public static let headerName = "x-device-fingerprint"

    /// Upper bound on the serialized base64 value. HTTP stacks typically reject
    /// header values past 8 KiB; we keep a conservative ceiling to avoid
    /// surprises. The adapted schema serializes to ~350 bytes in practice.
    public static let maxHeaderValueBytes = 4096

    public static func encodeHeaderValue(_ fingerprint: DeviceFingerprint) throws(AuthError) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(fingerprint)
        } catch {
            throw AuthError.fingerprintCaptureFailed("encode failed: \(error.localizedDescription)")
        }
        let base64 = data.base64EncodedString()
        guard base64.utf8.count <= maxHeaderValueBytes else {
            throw AuthError.fingerprintCaptureFailed(
                "header value exceeds \(maxHeaderValueBytes) bytes (got \(base64.utf8.count))",
            )
        }
        return base64
    }

    /// Decode a header value back to a fingerprint. Used by tests and by the
    /// server plugin when porting to Swift; not used by the app at runtime.
    public static func decodeHeaderValue(_ value: String) throws(AuthError) -> DeviceFingerprint {
        guard let data = Data(base64Encoded: value) else {
            throw AuthError.fingerprintCaptureFailed("invalid base64 header")
        }
        do {
            return try JSONDecoder().decode(DeviceFingerprint.self, from: data)
        } catch {
            throw AuthError.fingerprintCaptureFailed("decode failed: \(error.localizedDescription)")
        }
    }
}
