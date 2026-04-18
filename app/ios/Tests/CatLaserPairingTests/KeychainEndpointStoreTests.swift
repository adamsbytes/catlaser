#if canImport(Security) && canImport(Darwin)
import CatLaserAuth
import CatLaserDevice
import CatLaserPairing
import Foundation
import Testing

@Suite("KeychainEndpointStore")
struct KeychainEndpointStoreTests {
    /// Every test instance uses a unique service identifier so the
    /// suite can run in parallel without cross-contamination of
    /// keychain rows.
    private func makeStore() -> KeychainEndpointStore {
        KeychainEndpointStore(
            service: "com.catlaser.tests.pairing.\(UUID().uuidString)",
            account: "endpoint",
        )
    }

    private func makeDevice() throws -> PairedDevice {
        PairedDevice(
            id: "cat-001",
            name: "Kitchen",
            endpoint: try DeviceEndpoint(host: "100.64.1.7", port: 9820),
            pairedAt: Date(timeIntervalSince1970: 1_712_345_678),
        )
    }

    @Test
    func loadReturnsNilWhenEmpty() async throws {
        let store = makeStore()
        let loaded = try await store.load()
        #expect(loaded == nil)
    }

    @Test
    func saveThenLoadRoundTrips() async throws {
        let store = makeStore()
        let device = try makeDevice()
        try await store.save(device)
        let loaded = try await store.load()
        #expect(loaded == device)
        try? await store.delete()
    }

    @Test
    func saveOverwritesExistingRow() async throws {
        let store = makeStore()
        let first = try makeDevice()
        try await store.save(first)

        let second = PairedDevice(
            id: "cat-002",
            name: "Office",
            endpoint: try DeviceEndpoint(host: "100.64.2.3", port: 9821),
            pairedAt: Date(timeIntervalSince1970: 1_712_345_900),
        )
        try await store.save(second)

        let loaded = try await store.load()
        #expect(loaded?.id == "cat-002")
        #expect(loaded?.endpoint.port == 9821)
        try? await store.delete()
    }

    @Test
    func deleteRemovesRow() async throws {
        let store = makeStore()
        try await store.save(try makeDevice())
        try await store.delete()
        let loaded = try await store.load()
        #expect(loaded == nil)
    }

    @Test
    func deleteIsIdempotent() async throws {
        let store = makeStore()
        try await store.delete()
        try await store.delete()
        let loaded = try await store.load()
        #expect(loaded == nil)
    }

    @Test
    func sessionDidSignOutWipesRow() async throws {
        let store = makeStore()
        try await store.save(try makeDevice())

        await store.sessionDidSignOut()

        let loaded = try await store.load()
        #expect(loaded == nil)
    }

    @Test
    func sessionDidSignOutSwallowsStorageErrors() async throws {
        // A store that's never had a row wiped is a legitimate
        // state for sign-out to encounter (user signs out before
        // pairing). `sessionDidSignOut` must not leak errors up.
        let store = makeStore()
        await store.sessionDidSignOut()
        // If we got here, no throw — which is the contract.
    }
}
#endif
