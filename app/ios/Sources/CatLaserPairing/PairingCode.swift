import Foundation

/// Parsed QR-code payload embedded on the device during first-boot
/// provisioning.
///
/// ## Wire format
///
/// The QR the device's Bluetooth-less provisioning flow renders carries
/// a custom-scheme URL, not an HTTP(S) URL:
///
/// ```
/// catlaser://pair?code=<base32_opaque_secret>&device=<stable_device_id>
/// ```
///
/// A custom scheme is deliberate. An HTTPS URL scanned by a camera
/// would open Safari on any device without the app installed, and any
/// fallback Universal-Link handler would have to serve *something* at
/// that path — a surface we don't want to expose. `catlaser://` is
/// claimed by the app's `CFBundleURLTypes`; scanning on a device
/// without the app installed does nothing.
///
/// The QR is NOT the Tailscale endpoint. The endpoint is brokered by
/// the coordination server against the `code` parameter; see
/// `PairingClient.exchange(...)`. Keeping the endpoint out of the QR
/// means a stolen QR that never reaches the coordination server still
/// can't be used to reach the device directly, and it means the device
/// can change its Tailscale IP (which it will, routinely, as Tailscale
/// MagicDNS rotates) without rotating the QR.
///
/// ## Validation
///
/// `parse(...)` enforces:
/// - Scheme `catlaser` (lowercase; Foundation lowercases on parse).
/// - Host `pair`.
/// - Exactly two query parameters: `code` and `device`, in either order.
/// - `code`: 16..128 characters drawn from the base32 alphabet
///   (RFC 4648, uppercase, no padding). The server issues 160-bit codes
///   (32 characters), so 16..128 is a generous bracket that allows
///   future growth but cleanly rejects obviously-wrong input — a
///   fingerprint of base64, a UUID, a URL fragment.
/// - `device`: 1..64 ASCII characters drawn from `[A-Za-z0-9_-]`. The
///   server uses a slug derived from the serial; exact format is
///   server-owned, so the client only asserts a safe subset.
///
/// Parsing is strict by design. A malformed QR that made it into
/// `PairingClient.exchange` would flow straight to the server as an
/// HTTP POST — cheap to handle but pointless to send, and the parse
/// failure here gives the UI a localisable error without a round-trip.
public struct PairingCode: Sendable, Equatable {
    public static let scheme = "catlaser"
    public static let host = "pair"
    public static let codeQueryName = "code"
    public static let deviceQueryName = "device"

    /// Minimum acceptable `code` length. 16 base32 chars = 80 bits of
    /// entropy, the absolute floor we'll entertain for a pairing
    /// secret with a server-enforced rate limit. Real codes are 32
    /// chars / 160 bits.
    public static let minCodeLength = 16

    /// Maximum acceptable `code` length. Base32 payloads above 128
    /// characters (640 bits) are not expected; rejecting the tail
    /// catches pathological input (a QR decode that swallowed a URL
    /// fragment, a buffer overrun from a rogue scanner).
    public static let maxCodeLength = 128

    /// Maximum acceptable `device` identifier length. Server-side
    /// slugs are deliberately short (serial-derived, ~10-20 chars);
    /// the 64-byte ceiling is a conservative safety net.
    public static let maxDeviceIDLength = 64

    public let code: String
    public let deviceID: String

    public init(code: String, deviceID: String) throws(PairingCodeError) {
        try Self.validateCode(code)
        try Self.validateDeviceID(deviceID)
        self.code = code
        self.deviceID = deviceID
    }

    /// Parse a raw scanned URL string into a `PairingCode`. Every
    /// failure mode maps to a distinct `PairingCodeError` so the UI
    /// can render a specific message without re-parsing.
    public static func parse(_ raw: String) throws(PairingCodeError) -> PairingCode {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw .empty
        }
        guard let components = URLComponents(string: trimmed) else {
            throw .malformedURL
        }
        guard let rawScheme = components.scheme?.lowercased(), rawScheme == scheme else {
            throw .wrongScheme
        }
        guard let rawHost = components.host?.lowercased(), rawHost == host else {
            throw .wrongHost
        }
        if let path = components.path as String?, !path.isEmpty, path != "/" {
            // A trailing slash is tolerated by URLComponents but a non-
            // empty path smells like a smuggled route; refuse.
            throw .unexpectedPath
        }
        let items = components.queryItems ?? []
        guard !items.isEmpty else {
            throw .missingQueryItems
        }
        var code: String?
        var device: String?
        for item in items {
            switch item.name {
            case codeQueryName:
                guard code == nil else { throw .duplicateQueryItem(codeQueryName) }
                code = item.value
            case deviceQueryName:
                guard device == nil else { throw .duplicateQueryItem(deviceQueryName) }
                device = item.value
            default:
                // Extra items are a sign of a crafted URL (tracking
                // params injected by a MitM, smuggled `callback=` an
                // attacker wants the app to honour). Reject rather
                // than silently ignore.
                throw .unexpectedQueryItem(item.name)
            }
        }
        guard let codeValue = code, !codeValue.isEmpty else {
            throw .missingCode
        }
        guard let deviceValue = device, !deviceValue.isEmpty else {
            throw .missingDeviceID
        }
        return try PairingCode(code: codeValue, deviceID: deviceValue)
    }

    /// Build the canonical URL representation of this code. Symmetric
    /// with `parse(_:)` so tests can round-trip. Used in diagnostics
    /// (log scrubber strips `code`) and to render a QR for debug
    /// builds.
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: Self.codeQueryName, value: code),
            URLQueryItem(name: Self.deviceQueryName, value: deviceID),
        ]
        guard let url = components.url else {
            preconditionFailure("PairingCode validated at init but still failed to form URL")
        }
        return url
    }

    private static func validateCode(_ candidate: String) throws(PairingCodeError) {
        guard !candidate.isEmpty else { throw .missingCode }
        guard candidate.count >= minCodeLength else { throw .codeTooShort }
        guard candidate.count <= maxCodeLength else { throw .codeTooLong }
        for scalar in candidate.unicodeScalars {
            let v = scalar.value
            let isUpperAlpha = (v >= 0x41 && v <= 0x5A)
            let isDigit2To7 = (v >= 0x32 && v <= 0x37)
            guard isUpperAlpha || isDigit2To7 else {
                throw .codeIllegalCharacter
            }
        }
    }

    private static func validateDeviceID(_ candidate: String) throws(PairingCodeError) {
        guard !candidate.isEmpty else { throw .missingDeviceID }
        guard candidate.count <= maxDeviceIDLength else { throw .deviceIDTooLong }
        for scalar in candidate.unicodeScalars {
            let v = scalar.value
            let isAlpha = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
            let isDigit = (v >= 0x30 && v <= 0x39)
            let isUnderscoreOrHyphen = (scalar == "_" || scalar == "-")
            guard isAlpha || isDigit || isUnderscoreOrHyphen else {
                throw .deviceIDIllegalCharacter
            }
        }
    }
}

public enum PairingCodeError: Error, Equatable, Sendable {
    case empty
    case malformedURL
    case wrongScheme
    case wrongHost
    case unexpectedPath
    case missingQueryItems
    case missingCode
    case missingDeviceID
    case duplicateQueryItem(String)
    case unexpectedQueryItem(String)
    case codeTooShort
    case codeTooLong
    case codeIllegalCharacter
    case deviceIDTooLong
    case deviceIDIllegalCharacter
}
