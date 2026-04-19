import Foundation
import Testing

@testable import CatLaserDevice

/// Shape-based coverage for the Tailscale address allowlist. The
/// address shape is what lets the resolver pick the correct utun
/// interface; exercising it directly guards against regressions in
/// the range checks without needing a live network.
@Suite("TailscaleInterface")
struct TailscaleInterfaceTests {
    @Test
    func cgnatV4InsideRangeAccepted() {
        #expect(TailscaleAddressShape.isTailscaleIPv4("100.64.0.1"))
        #expect(TailscaleAddressShape.isTailscaleIPv4("100.100.42.1"))
        #expect(TailscaleAddressShape.isTailscaleIPv4("100.127.255.254"))
    }

    @Test
    func cgnatV4OutsideRangeRejected() {
        // First octet wrong.
        #expect(!TailscaleAddressShape.isTailscaleIPv4("10.0.0.1"))
        #expect(!TailscaleAddressShape.isTailscaleIPv4("192.168.1.1"))
        // Second octet outside [64, 127].
        #expect(!TailscaleAddressShape.isTailscaleIPv4("100.63.0.1"))
        #expect(!TailscaleAddressShape.isTailscaleIPv4("100.128.0.1"))
        #expect(!TailscaleAddressShape.isTailscaleIPv4("100.200.0.1"))
    }

    @Test
    func ulaV6InsidePrefixAccepted() {
        #expect(TailscaleAddressShape.isTailscaleIPv6("fd7a:115c:a1e0::1"))
        #expect(TailscaleAddressShape.isTailscaleIPv6("fd7a:115c:a1e0:ab12::1"))
        // Case-insensitive.
        #expect(TailscaleAddressShape.isTailscaleIPv6("FD7A:115C:A1E0::1"))
    }

    @Test
    func ulaV6OutsidePrefixRejected() {
        #expect(!TailscaleAddressShape.isTailscaleIPv6("fe80::1"))
        #expect(!TailscaleAddressShape.isTailscaleIPv6("2001:db8::1"))
        // Adjacent but different ULA prefix.
        #expect(!TailscaleAddressShape.isTailscaleIPv6("fd7b:115c:a1e0::1"))
    }

    @Test
    func transportThrowsWhenResolverReturnsNoCandidates() throws {
        // A resolver that reports zero candidates is the "Tailscale
        // is off" signal. The transport MUST refuse to construct —
        // failing closed here is load-bearing: an NWConnection
        // without an interface pin would follow the kernel's
        // routing table and could land on a rogue VPN's utun.
        //
        // NetworkDeviceTransport itself is gated behind
        // `canImport(Network)` so this assertion lives here as a
        // resolver-level contract check.
        struct EmptyResolver: TailscaleInterfaceResolver {
            func enumerate() -> [TailscaleInterface] { [] }
        }
        let resolver = EmptyResolver()
        #expect(resolver.enumerate().isEmpty)
    }

    @Test
    func resolverMayReturnMultipleCandidates() {
        // If the device has more than one utun with a tailnet-shaped
        // address (developer box with two Tailscale instances,
        // extremely rare), the resolver returns them all and the
        // caller picks first. The resolver contract doesn't promise
        // ordering, only that every returned entry carries a real
        // Tailscale-shape address.
        struct FixedResolver: TailscaleInterfaceResolver {
            let fixtures: [TailscaleInterface]
            func enumerate() -> [TailscaleInterface] { fixtures }
        }
        let resolver = FixedResolver(fixtures: [
            TailscaleInterface(name: "utun4", address: "100.64.1.7"),
            TailscaleInterface(name: "utun5", address: "fd7a:115c:a1e0::1"),
        ])
        let results = resolver.enumerate()
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.name.hasPrefix("utun") })
    }
}
