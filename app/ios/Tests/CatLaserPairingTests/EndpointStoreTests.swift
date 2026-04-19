import CatLaserDevice
import CatLaserPairing
import CatLaserPairingTestSupport
import Foundation
import Testing

@Suite("EndpointStore (in-memory)")
struct EndpointStoreTests {
    private func makeDevice(id: String = "cat-001") throws -> PairedDevice {
        PairedDevice(
            id: id,
            name: "Kitchen",
            endpoint: try DeviceEndpoint(host: "100.64.1.7", port: 9820),
            pairedAt: Date(timeIntervalSince1970: 1_712_345_678),
            devicePublicKey: Data(repeating: 0x42, count: 32),
        )
    }

    @Test
    func loadReturnsNilWhenEmpty() async throws {
        let store = PublicInMemoryEndpointStore()
        let loaded = try await store.load()
        #expect(loaded == nil)
    }

    @Test
    func saveThenLoadReturnsExactDevice() async throws {
        let store = PublicInMemoryEndpointStore()
        let device = try makeDevice()
        try await store.save(device)
        let loaded = try await store.load()
        #expect(loaded == device)
    }

    @Test
    func saveOverwritesPriorDevice() async throws {
        let store = PublicInMemoryEndpointStore()
        try await store.save(try makeDevice(id: "cat-001"))
        try await store.save(try makeDevice(id: "cat-002"))
        let loaded = try await store.load()
        #expect(loaded?.id == "cat-002")
    }

    @Test
    func deleteRemovesDevice() async throws {
        let store = PublicInMemoryEndpointStore()
        try await store.save(try makeDevice())
        try await store.delete()
        let loaded = try await store.load()
        #expect(loaded == nil)
    }

    @Test
    func deleteIsIdempotent() async throws {
        let store = PublicInMemoryEndpointStore()
        try await store.delete()
        try await store.delete()
        let loaded = try await store.load()
        #expect(loaded == nil)
    }

    @Test
    func counterHooksExposeCallCounts() async throws {
        let store = PublicInMemoryEndpointStore()
        try await store.save(try makeDevice())
        try await store.save(try makeDevice(id: "cat-002"))
        try await store.delete()
        #expect(await store.saveCallCount() == 2)
        #expect(await store.deleteCallCount() == 1)
    }

    @Test
    func queuedLoadFailureSurfaces() async throws {
        let store = PublicInMemoryEndpointStore()
        await store.queueLoadFailure(.storage("simulated"))
        do {
            _ = try await store.load()
            Issue.record("expected throw")
        } catch let error as PairingError {
            if case .storage = error {
                // good
            } else {
                Issue.record("wrong error: \(error)")
            }
        }
    }
}
