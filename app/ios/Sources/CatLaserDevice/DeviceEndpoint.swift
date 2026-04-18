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
/// ## Why tailnet-only
///
/// The app opens plaintext TCP to `host:port` and sends control frames
/// plus receives `StreamOffer` payloads whose LiveKit URL is dialed
/// unconditionally. If the server (or a compromised issuance pipeline)
/// returned an arbitrary public host, the compound effect would be that
/// the device daemon is impersonated from anywhere on the internet —
/// credentials exfiltrated, commands accepted. Constraining `host` to
/// Tailscale-only addresses means impersonation requires tailnet
/// membership for the victim's account, a dramatically higher bar than
/// "controls any DNS name."
///
/// Accepted:
/// - IPv4 inside `100.64.0.0/10` (Tailscale CGNAT).
/// - IPv6 inside `fd7a:115c:a1e0::/48` (Tailscale ULA). Zone ids are
///   rejected; tailnet addresses never need a scope id.
/// - MagicDNS hostnames ending in `.ts.net` (current) or
///   `.tailscale.net` (legacy), with a non-empty label to the left.
///
/// Rejected: every other DNS name, every other IP, URL syntax,
/// whitespace, non-ASCII, and bare suffixes (`ts.net` alone).
///
/// Validation is strict because the transport feeds the host string
/// directly into `NWEndpoint.Host(...)`. Rejecting malformed input at
/// construction moves connect-time failures into config-build failures,
/// which is easier to diagnose and prevents a bad write to persistent
/// storage from recurring on every app launch. The server enforces the
/// same allowlist in `isPlausibleTailscaleHost`; either side catching
/// drift is a test failure on the round-trip suite.
public struct DeviceEndpoint: Sendable, Equatable, Hashable, Codable {
    /// Maximum DNS name length per RFC 1035. Also caps IP literal length
    /// (longest plausible IPv6 with zone is ~45 chars; 253 is conservative).
    public static let maxHostLength = 253

    /// Default TCP port for the app-to-device API server (see
    /// `python/catlaser_brain/network/server.py`).
    public static let defaultPort: UInt16 = 9820

    /// MagicDNS suffixes the validator accepts. Must mirror the server's
    /// `TAILSCALE_MAGIC_DNS_SUFFIXES` byte-for-byte; a drift in either
    /// direction means a host that survived issuance fails construction
    /// client-side (or vice versa), which is what the round-trip tests
    /// catch.
    public static let magicDNSSuffixes: [String] = [".ts.net", ".tailscale.net"]

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

    /// Tailnet-only host predicate. See the type-level doc for the exact
    /// set of accepted shapes.
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

        if inner.contains(":") {
            return isTailscaleCGNAT6(inner)
        }
        if isIPv4DottedQuad(inner) {
            return isTailscaleCGNAT4(inner)
        }
        return isTailscaleMagicDNS(inner)
    }

    // MARK: - Tailscale range checks

    /// True iff `candidate` is a syntactically well-formed IPv4 dotted
    /// quad. Each octet must be 1..3 decimal digits without leading zeros
    /// (which would be interpreted as octal by some parsers), and in the
    /// range 0..255.
    private static func isIPv4DottedQuad(_ candidate: String) -> Bool {
        let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard !part.isEmpty, part.count <= 3 else { return false }
            if part.count > 1, part.first == "0" { return false }
            for scalar in part.unicodeScalars {
                guard scalar.value >= 0x30, scalar.value <= 0x39 else { return false }
            }
            guard let value = Int(part), value >= 0, value <= 255 else { return false }
        }
        return true
    }

    /// True iff `candidate` is a dotted-quad inside `100.64.0.0/10`.
    private static func isTailscaleCGNAT4(_ candidate: String) -> Bool {
        let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let first = parts.first.map(String.init).flatMap(Int.init),
              parts.indices.contains(1)
        else { return false }
        guard let second = Int(parts[1]) else { return false }
        return first == 100 && second >= 64 && second <= 127
    }

    /// True iff `candidate` is a well-formed IPv6 literal inside
    /// `fd7a:115c:a1e0::/48`. Zone identifiers (`%eth0`) are rejected —
    /// tailnet addresses are globally routable within the tailnet and
    /// never require a scope id.
    private static func isTailscaleCGNAT6(_ candidate: String) -> Bool {
        if candidate.contains("%") { return false }
        guard let prefix = ipv6Prefix48(candidate) else { return false }
        return prefix == "fd7a:115c:a1e0"
    }

    /// Return the fully-expanded first three groups of a well-formed
    /// IPv6 literal, or nil on parse failure. Handles RFC 5952 `::`
    /// compression.
    private static func ipv6Prefix48(_ candidate: String) -> String? {
        let lower = candidate.lowercased()
        // Reject anything that is not hex + colon.
        for scalar in lower.unicodeScalars {
            let v = scalar.value
            let ok = (v >= 0x30 && v <= 0x39)
                || (v >= 0x61 && v <= 0x66)
                || scalar == ":"
            guard ok else { return nil }
        }
        let halves = lower.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        let head: [String]
        let tail: [String]
        switch halves.count {
        case 1:
            let first = halves[0]
            guard !first.isEmpty else { return nil }
            head = first.components(separatedBy: ":")
            tail = []
        case 2:
            let left = halves[0]
            let right = halves[1]
            head = left.isEmpty ? [] : left.components(separatedBy: ":")
            tail = right.isEmpty ? [] : right.components(separatedBy: ":")
        default:
            return nil
        }
        // Without `::`, full form must have exactly 8 groups.
        if halves.count == 1, head.count != 8 { return nil }
        let zerosNeeded = halves.count == 2 ? 8 - head.count - tail.count : 0
        if zerosNeeded < 0 { return nil }
        var groups = head
        groups.append(contentsOf: Array(repeating: "0", count: zerosNeeded))
        groups.append(contentsOf: tail)
        guard groups.count == 8 else { return nil }
        let prefix = Array(groups.prefix(3))
        for group in prefix {
            guard !group.isEmpty, group.count <= 4 else { return nil }
        }
        return prefix
            .map { String(repeating: "0", count: 4 - $0.count) + $0 }
            .joined(separator: ":")
    }

    /// True iff `candidate` is a DNS name ending in one of the accepted
    /// Tailscale MagicDNS suffixes with at least one non-empty label to
    /// the left.
    private static func isTailscaleMagicDNS(_ candidate: String) -> Bool {
        let lower = candidate.lowercased()
        for suffix in magicDNSSuffixes {
            guard lower.hasSuffix(suffix) else { continue }
            let head = String(lower.dropLast(suffix.count))
            guard !head.isEmpty else { return false }
            return isDnsName(head)
        }
        return false
    }

    /// DNS-name validator used only for the label to the left of a
    /// MagicDNS suffix. Each label must be 1..63 alphanumeric + hyphen
    /// characters, not starting/ending with a hyphen.
    private static func isDnsName(_ candidate: String) -> Bool {
        let labels = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, !labels.contains(where: \.isEmpty) else { return false }
        for label in labels {
            guard label.count <= 63 else { return false }
            guard label.first != "-", label.last != "-" else { return false }
            for scalar in label.unicodeScalars {
                let v = scalar.value
                let ok = (v >= 0x30 && v <= 0x39)
                    || (v >= 0x41 && v <= 0x5A)
                    || (v >= 0x61 && v <= 0x7A)
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
