import CatLaserDevice
import Foundation
import Testing

@testable import CatLaserPairing

@Suite("PairedDevice")
struct PairedDeviceTests {
    private static let samplePublicKey = Data(repeating: 0x42, count: 32)

    private func makeDevice() throws -> PairedDevice {
        let endpoint = try DeviceEndpoint(host: "100.64.1.7", port: 9820)
        return PairedDevice(
            id: "cat-001",
            name: "Kitchen",
            endpoint: endpoint,
            pairedAt: Date(timeIntervalSince1970: 1_712_345_678),
            devicePublicKey: Self.samplePublicKey,
        )
    }

    @Test
    func codableRoundTripPreservesEveryField() throws {
        let original = try makeDevice()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PairedDevice.self, from: encoded)
        #expect(decoded == original)
        #expect(decoded.id == "cat-001")
        #expect(decoded.name == "Kitchen")
        #expect(decoded.endpoint.host == "100.64.1.7")
        #expect(decoded.endpoint.port == 9820)
        #expect(decoded.devicePublicKey == Self.samplePublicKey)
    }

    @Test
    func decodesMissingNameAsEmptyString() throws {
        // Minimal row: `name` may be absent (older server payloads
        // did not populate it). Every other field remains mandatory.
        let pubkeyBase64 = Self.samplePublicKey.base64EncodedString()
        let json = """
        {
            "id": "cat-001",
            "endpoint": {"host": "100.64.1.7", "port": 9820},
            "pairedAt": 1712345678.0,
            "devicePublicKey": "\(pubkeyBase64)"
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(PairedDevice.self, from: data)
        #expect(decoded.name == "")
        #expect(decoded.id == "cat-001")
    }

    @Test
    func rejectsWrongLengthPublicKey() throws {
        // A 31-byte key would bypass verifier-level checks later if
        // we didn't catch it at decode time. Enforce at the boundary
        // so a corrupt/older Keychain row fails loudly on first read.
        let shortPubkey = Data(repeating: 0x42, count: 31).base64EncodedString()
        let json = """
        {
            "id": "cat-001",
            "name": "Kitchen",
            "endpoint": {"host": "100.64.1.7", "port": 9820},
            "pairedAt": 1712345678.0,
            "devicePublicKey": "\(shortPubkey)"
        }
        """
        let data = Data(json.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PairedDevice.self, from: data)
        }
    }

    @Test
    func equalityIsByAllFields() throws {
        let a = try makeDevice()
        let differentName = PairedDevice(
            id: a.id,
            name: "Living Room",
            endpoint: a.endpoint,
            pairedAt: a.pairedAt,
            devicePublicKey: a.devicePublicKey,
        )
        #expect(a != differentName)

        let differentKey = PairedDevice(
            id: a.id,
            name: a.name,
            endpoint: a.endpoint,
            pairedAt: a.pairedAt,
            devicePublicKey: Data(repeating: 0xAB, count: 32),
        )
        #expect(a != differentKey)
    }
}
