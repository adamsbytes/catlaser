import Foundation
import Testing

@testable import CatLaserDevice

@Suite("DeviceEndpoint")
struct DeviceEndpointTests {
    // MARK: - Accepted tailnet shapes

    @Test
    func acceptsCGNAT4() throws {
        let ep = try DeviceEndpoint(host: "100.64.1.23", port: 9820)
        #expect(ep.host == "100.64.1.23")
        #expect(ep.port == 9820)
    }

    @Test
    func acceptsCGNAT4AtRangeBoundary() throws {
        _ = try DeviceEndpoint(host: "100.64.0.1")
        _ = try DeviceEndpoint(host: "100.127.255.254")
    }

    @Test
    func acceptsMagicDNSUnderTsNet() throws {
        let ep = try DeviceEndpoint(host: "catlaser-01.my-tailnet.ts.net")
        #expect(ep.host == "catlaser-01.my-tailnet.ts.net")
        #expect(ep.port == DeviceEndpoint.defaultPort)
    }

    @Test
    func acceptsLegacyTailscaleNetSuffix() throws {
        let ep = try DeviceEndpoint(host: "catlaser-01.tailscale.net")
        #expect(ep.host == "catlaser-01.tailscale.net")
    }

    @Test
    func acceptsTailscaleIPv6() throws {
        let ep = try DeviceEndpoint(host: "fd7a:115c:a1e0:ab12::1")
        #expect(ep.host == "fd7a:115c:a1e0:ab12::1")
    }

    @Test
    func acceptsBracketedTailscaleIPv6() throws {
        let ep = try DeviceEndpoint(host: "[fd7a:115c:a1e0::1]")
        #expect(ep.host == "[fd7a:115c:a1e0::1]")
    }

    @Test
    func trimsWhitespace() throws {
        let ep = try DeviceEndpoint(host: "   100.64.1.23  ")
        #expect(ep.host == "100.64.1.23")
    }

    // MARK: - Non-tailnet rejection (the core of fix #3)

    @Test
    func rejectsPublicIPv4() {
        // `8.8.8.8` is on the public internet and the app would dial it
        // plaintext. A compromised issuance pipeline must not be able to
        // redirect an app to an attacker-controlled box.
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "8.8.8.8")
        }
    }

    @Test
    func rejectsRFC1918Private() {
        // RFC 1918 ranges are reachable on the local network but not
        // through the Tailscale tunnel. Accepting them would be a
        // silently-different trust domain and is explicitly out of scope.
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "192.168.1.10")
        }
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "10.0.0.5")
        }
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "172.16.0.1")
        }
    }

    @Test
    func rejectsLoopbackIPv4() {
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "127.0.0.1")
        }
    }

    @Test
    func rejectsNonTailscaleCGNAT() {
        // 100.63.x.x is right below the Tailscale block; 100.128.x.x is
        // right above. Neither is routable via Tailscale, both must be
        // rejected as crisp boundary tests.
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "100.63.255.254")
        }
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "100.128.0.1")
        }
    }

    @Test
    func rejectsNonTailscaleIPv6() {
        // Global unicast and documentation ranges. The `fd7a::1` case
        // (fd7a::/16 but NOT fd7a:115c:a1e0::/48) is the particularly
        // sneaky one — it looks Tailscale-adjacent but is outside the
        // allocated block.
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "fd7a::1")
        }
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "2001:db8::1")
        }
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "::1")
        }
    }

    @Test
    func rejectsIPv6WithZoneIdentifier() {
        // Zone ids (`%eth0`) are link-local scope markers. A tailnet
        // address never legitimately needs one, and accepting it would
        // let a caller smuggle a link-local fallback destination past
        // the Tailscale-only gate.
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "fd7a:115c:a1e0::1%eth0")
        }
    }

    @Test
    func rejectsPublicDNSName() {
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "example.com")
        }
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "catlaser-01.example.com")
        }
    }

    @Test
    func rejectsBareMagicDNSSuffix() {
        // The suffix alone isn't a hostname; there must be a non-empty
        // label to the left.
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "ts.net")
        }
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: ".ts.net")
        }
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "tailscale.net")
        }
    }

    @Test
    func rejectsMagicDNSWithInvalidLabel() {
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "-bad.my-tailnet.ts.net")
        }
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "bad-.my-tailnet.ts.net")
        }
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "foo..bar.ts.net")
        }
    }

    // MARK: - Structural rejections

    @Test
    func rejectsEmptyHost() {
        #expect(throws: DeviceEndpointError.emptyHost) {
            _ = try DeviceEndpoint(host: "")
        }
        #expect(throws: DeviceEndpointError.emptyHost) {
            _ = try DeviceEndpoint(host: "   \t  ")
        }
    }

    @Test
    func rejectsOversizedHost() {
        let huge = String(repeating: "a", count: DeviceEndpoint.maxHostLength + 1)
        #expect(throws: DeviceEndpointError.hostTooLong) {
            _ = try DeviceEndpoint(host: huge)
        }
    }

    @Test
    func rejectsZeroPort() {
        #expect(throws: DeviceEndpointError.invalidPort) {
            _ = try DeviceEndpoint(host: "100.64.1.23", port: 0)
        }
    }

    @Test
    func rejectsHostWithSchemeOrPath() {
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "https://foo.ts.net")
        }
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "foo.ts.net/status")
        }
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "user@100.64.1.23")
        }
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "100.64 .1.23")
        }
    }

    @Test
    func rejectsIPv4WithLeadingZeros() {
        // Leading-zero octets can be interpreted as octal by some
        // parsers (`0100` == 64 in C). Reject them to avoid an ambiguity
        // between the canonical form the server stored and what the
        // client dials.
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "100.064.1.23")
        }
    }

    @Test
    func rejectsIPv4OutsideOctetRange() {
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "100.64.1.256")
        }
    }

    @Test
    func rejectsNonASCII() {
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "例え.ts.net")
        }
    }

    // MARK: - Codable

    @Test
    func codableRoundTrip() throws {
        let original = try DeviceEndpoint(host: "100.64.1.23", port: 12345)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DeviceEndpoint.self, from: encoded)
        #expect(decoded == original)
    }
}
