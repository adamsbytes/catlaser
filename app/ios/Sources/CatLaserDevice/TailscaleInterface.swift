import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One interface-name candidate the app found carrying a Tailscale
/// address. Kept as a plain ``String`` so the transport can match it
/// against ``NWPathMonitor``'s ``NWInterface.name`` on Apple
/// platforms without dragging a heavier dependency onto the
/// cross-platform build.
public struct TailscaleInterface: Sendable, Equatable {
    /// Kernel interface name (e.g. `"utun3"`). Stable within a
    /// single Tailscale session; may change across Tailscale
    /// restarts (the daemon rebinds to whichever utun slot is free).
    public let name: String

    /// The Tailscale-shaped address the interface carries that let
    /// the resolver identify it. Surfaced for diagnostics only — the
    /// transport pins on the interface *name*, which is what
    /// ``NWPathMonitor`` exposes.
    public let address: String

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }
}

/// Resolves the Tailscale utun interface the device TCP transport
/// must pin to.
///
/// Without interface pinning, an iOS ``NWConnection`` to a
/// ``100.64.0.0/10`` address follows the kernel's routing table —
/// which, under a compromised profile-installed VPN or a MagicDNS
/// hijack with Tailscale paused, can steer the socket onto a
/// non-Tailscale interface. The attacker then accepts the TCP
/// connection, replies to the app's ``AuthRequest`` with whatever
/// bytes they like, and (absent the Ed25519 verifier we wire in
/// alongside this) impersonates the device.
///
/// Pinning the ``NWConnection`` to the specific ``utunN`` interface
/// Tailscale advertises closes that gap at the socket layer:
/// packets leave via that interface or not at all. Combined with
/// the device-signed ``AuthResponse`` verification (separate file),
/// the app has both transport-level and application-level defence
/// against an impostor at the Tailscale endpoint.
public protocol TailscaleInterfaceResolver: Sendable {
    /// Enumerate live interfaces and return every candidate carrying
    /// a Tailscale-shaped address. In production the list is almost
    /// always zero (Tailscale off) or one (normal case); on test
    /// boxes with multiple overlapping VPNs it may be larger, in
    /// which case the caller picks the first match or fails closed.
    func enumerate() -> [TailscaleInterface]
}

/// Tailscale IPv4 CGNAT block (``100.64.0.0/10``) and IPv6 ULA
/// prefix (``fd7a:115c:a1e0::/48``). Matched by first-octet / first-
/// three-groups comparison rather than a full subnet parser — the
/// numbers are stable (Tailscale has used these since v1) and a
/// heavyweight CIDR implementation would be dead weight.
enum TailscaleAddressShape {
    static func isTailscaleIPv4(_ address: String) -> Bool {
        // 100.64.0.0/10: first octet 100, second octet 64..127.
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return false }
        guard let first = Int(parts[0]), let second = Int(parts[1]) else { return false }
        return first == 100 && (64 ... 127).contains(second)
    }

    static func isTailscaleIPv6(_ address: String) -> Bool {
        // fd7a:115c:a1e0::/48 — compare the first three 16-bit
        // groups, lowercased. Zone suffixes ("fe80::1%en0") are
        // stripped first; Tailscale addresses are globally routable
        // within the tailnet and never need a scope id, but the
        // resolver tolerates the syntax so a parser quirk in
        // getifaddrs output doesn't reject a legitimate interface.
        let bare = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        let lowered = bare.lowercased()
        // Fast path: startsWith the canonical prefix.
        if lowered.hasPrefix("fd7a:115c:a1e0:") || lowered.hasPrefix("fd7a:115c:a1e0::") {
            return true
        }
        return false
    }
}

#if canImport(Darwin)

/// Production resolver backed by ``getifaddrs(3)``. Walks the
/// ``ifaddrs`` linked list, collects every ``utunN`` interface
/// bearing a Tailscale-shaped IPv4 or IPv6 address, and returns the
/// deduplicated result. Safe to call frequently — each call costs
/// one syscall and a small fixed amount of parsing.
///
/// The resolver is intentionally stateless so a caller can
/// re-resolve on every reconnect attempt. Tailscale sometimes
/// rebinds its utun slot (``utun0`` → ``utun1``) when the daemon
/// restarts or when another packet tunnel starts first; pinning to a
/// cached name across that boundary would break the connection
/// silently.
public struct GetifaddrsTailscaleResolver: TailscaleInterfaceResolver {
    public init() {}

    public func enumerate() -> [TailscaleInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            return []
        }
        defer { freeifaddrs(head) }
        var results: [TailscaleInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let namePointer = entry.pointee.ifa_name else { continue }
            let name = String(cString: namePointer)
            // Production Tailscale on iOS runs as a packet tunnel
            // whose kernel-facing interface is always `utun*`. Any
            // other name is a different VPN or a physical NIC and
            // is not a valid pin target even if it happens to carry
            // a CGNAT-shaped address.
            guard name.hasPrefix("utun") else { continue }
            guard let addrPointer = entry.pointee.ifa_addr else { continue }
            let family = Int32(addrPointer.pointee.sa_family)
            guard let address = Self.formatAddress(addrPointer, family: family) else {
                continue
            }
            let matches: Bool = switch family {
            case AF_INET: TailscaleAddressShape.isTailscaleIPv4(address)
            case AF_INET6: TailscaleAddressShape.isTailscaleIPv6(address)
            default: false
            }
            guard matches else { continue }
            results.append(TailscaleInterface(name: name, address: address))
        }
        return results
    }

    private static func formatAddress(
        _ addrPointer: UnsafePointer<sockaddr>,
        family: Int32,
    ) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch family {
        case AF_INET:
            let size = MemoryLayout<sockaddr_in>.size
            return addrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                var addr = sin.pointee.sin_addr
                let result = inet_ntop(AF_INET, &addr, &buffer, socklen_t(size))
                return result.map { String(cString: $0) }
            }
        case AF_INET6:
            let size = MemoryLayout<sockaddr_in6>.size
            return addrPointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                var addr = sin6.pointee.sin6_addr
                let result = inet_ntop(AF_INET6, &addr, &buffer, socklen_t(size))
                return result.map { String(cString: $0) }
            }
        default:
            _ = size_t(INET6_ADDRSTRLEN)
            return nil
        }
    }
}

#endif

/// Errors emitted by the transport's interface-pin step. Kept in
/// its own enum (rather than folded into ``DeviceClientError``) so
/// the supervisor can pattern-match on it without importing the
/// Network-framework-only transport file into every caller.
public enum TailscaleInterfaceError: Error, Equatable, Sendable {
    /// No ``utunN`` interface currently carries a Tailscale-shaped
    /// address. Treat as transient: Tailscale is off or still
    /// booting. The supervisor retries with backoff.
    case noTailscaleInterfaceAvailable
}
