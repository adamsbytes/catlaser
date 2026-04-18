import Foundation

/// Network address of a Catlaser device reachable over Tailscale.
///
/// The architecture (`docs/ARCHITECTURE.md` — "App ↔ Device API") pins the
/// app-facing channel to TCP over a WireGuard tunnel. The device's
/// Tailscale IP is not discoverable by the app locally; it is brokered
/// by the coordination server during pairing. This value type captures
/// the result of that lookup so the transport layer never has to parse
/// raw strings at use time.
///
/// Validation is strict because the transport feeds the host string
/// directly into `NWEndpoint.Host(...)`. Rejecting malformed input at
/// construction moves connect-time failures into config-build failures,
/// which is easier to diagnose and prevents a bad write to persistent
/// storage from recurring on every app launch.
public struct DeviceEndpoint: Sendable, Equatable, Hashable, Codable {
    /// Maximum DNS name length per RFC 1035. Also caps IP literal length
    /// (longest plausible IPv6 with zone is ~45 chars; 253 is conservative).
    public static let maxHostLength = 253

    /// Default TCP port for the app-to-device API server (see
    /// `python/catlaser_brain/network/server.py`).
    public static let defaultPort: UInt16 = 9820

    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16 = DeviceEndpoint.defaultPort) throws(DeviceEndpointError) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw .emptyHost
        }
        guard trimmed.count <= Self.maxHostLength else {
            throw .hostTooLong
        }
        guard Self.isPlausibleHost(trimmed) else {
            throw .invalidHost
        }
        guard port > 0 else {
            throw .invalidPort
        }
        self.host = trimmed
        self.port = port
    }

    /// Accepts: IPv4 dotted-quad, IPv6 literal (optionally bracketed on
    /// input — stored without brackets), or DNS names (alphanumeric + `-`
    /// labels per RFC 1035). Rejects anything containing URL syntax or
    /// whitespace. IDN and punycode must be pre-encoded by the caller.
    private static func isPlausibleHost(_ candidate: String) -> Bool {
        let inner: String
        if candidate.hasPrefix("["), candidate.hasSuffix("]") {
            inner = String(candidate.dropFirst().dropLast())
        } else {
            inner = candidate
        }
        guard !inner.isEmpty else { return false }

        // Reject anything that looks like smuggled scheme, path, port,
        // userinfo, or control bytes.
        let disallowed = CharacterSet(charactersIn: "/?#@\\ \t\n\r").union(.controlCharacters)
        if inner.unicodeScalars.contains(where: disallowed.contains) {
            return false
        }

        // IPv6: hex + colons + optional %zone. One or more colons and
        // nothing outside the allowed alphabet.
        if inner.contains(":") {
            let ipv6Allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.%-")
            return inner.unicodeScalars.allSatisfy(ipv6Allowed.contains)
        }

        // DNS name or IPv4. Split on `.`; each label must be 1..63,
        // alphanumeric + `-`, not starting/ending with `-`.
        let labels = inner.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, !labels.contains(where: \.isEmpty) else {
            return false
        }
        for label in labels {
            guard label.count <= 63 else { return false }
            guard label.first != "-", label.last != "-" else { return false }
            for scalar in label.unicodeScalars {
                let ok = (scalar.value >= 0x30 && scalar.value <= 0x39)
                    || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                    || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                    || scalar == "-"
                guard ok else { return false }
            }
        }
        return true
    }
}

public enum DeviceEndpointError: Error, Equatable, Sendable {
    case emptyHost
    case hostTooLong
    case invalidHost
    case invalidPort
}
