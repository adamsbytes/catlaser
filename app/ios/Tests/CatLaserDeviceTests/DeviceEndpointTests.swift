import Foundation
import Testing

@testable import CatLaserDevice

@Suite("DeviceEndpoint")
struct DeviceEndpointTests {
    @Test
    func acceptsIPv4() throws {
        let ep = try DeviceEndpoint(host: "100.64.1.23", port: 9820)
        #expect(ep.host == "100.64.1.23")
        #expect(ep.port == 9820)
    }

    @Test
    func acceptsDNSName() throws {
        let ep = try DeviceEndpoint(host: "catlaser-01.tailscale.net")
        #expect(ep.host == "catlaser-01.tailscale.net")
        #expect(ep.port == DeviceEndpoint.defaultPort)
    }

    @Test
    func acceptsIPv6() throws {
        let ep = try DeviceEndpoint(host: "fd7a:115c:a1e0:ab12::1")
        #expect(ep.host == "fd7a:115c:a1e0:ab12::1")
    }

    @Test
    func acceptsBracketedIPv6ByStrippingBrackets() throws {
        let ep = try DeviceEndpoint(host: "[fd7a::1]")
        #expect(ep.host == "[fd7a::1]")
    }

    @Test
    func trimsWhitespace() throws {
        let ep = try DeviceEndpoint(host: "   example.lan  ")
        #expect(ep.host == "example.lan")
    }

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
            _ = try DeviceEndpoint(host: "example.com", port: 0)
        }
    }

    @Test
    func rejectsHostWithSchemeOrPath() {
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "https://example.com")
        }
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "example.com/status")
        }
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "user@host")
        }
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "ho st")
        }
    }

    @Test
    func rejectsEmptyLabels() {
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "foo..bar")
        }
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: ".example.com")
        }
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "example.com.")
        }
    }

    @Test
    func rejectsLeadingOrTrailingHyphenInLabels() {
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "-example.com")
        }
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "example-.com")
        }
    }

    @Test
    func rejectsNonASCII() {
        #expect(throws: DeviceEndpointError.invalidHost) {
            _ = try DeviceEndpoint(host: "例え.jp")
        }
    }

    @Test
    func codableRoundTrip() throws {
        let original = try DeviceEndpoint(host: "example.lan", port: 12345)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DeviceEndpoint.self, from: encoded)
        #expect(decoded == original)
    }
}
