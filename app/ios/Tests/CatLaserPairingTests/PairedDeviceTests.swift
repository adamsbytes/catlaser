import CatLaserDevice
import Foundation
import Testing

@testable import CatLaserPairing

@Suite("PairedDevice")
struct PairedDeviceTests {
    private func makeDevice() throws -> PairedDevice {
        let endpoint = try DeviceEndpoint(host: "100.64.1.7", port: 9820)
        return PairedDevice(
            id: "cat-001",
            name: "Kitchen",
            endpoint: endpoint,
            pairedAt: Date(timeIntervalSince1970: 1_712_345_678),
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
    }

    @Test
    func decodesMissingNameAsEmptyString() throws {
        let json = """
        {
            "id": "cat-001",
            "endpoint": {"host": "100.64.1.7", "port": 9820},
            "pairedAt": 1712345678.0
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(PairedDevice.self, from: data)
        #expect(decoded.name == "")
        #expect(decoded.id == "cat-001")
    }

    @Test
    func equalityIsByAllFields() throws {
        let a = try makeDevice()
        let differentName = PairedDevice(
            id: a.id,
            name: "Living Room",
            endpoint: a.endpoint,
            pairedAt: a.pairedAt,
        )
        #expect(a != differentName)
    }
}
