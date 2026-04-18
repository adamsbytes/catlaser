import CatLaserPairing
import Foundation

/// Public in-memory `EndpointStore` usable by tests in the pairing
/// and app test targets.
///
/// The library's internal `InMemoryEndpointStore` is `internal` so it
/// cannot leak into production wiring. Tests that exercise code
/// against a real `EndpointStore` go through this wrapper instead.
/// The wrapper mirrors the in-memory behaviour (save/load/delete with
/// no persistence side effects) and adds a non-`EndpointStore` probe
/// (`snapshot`) tests use to assert the internal state directly.
public actor PublicInMemoryEndpointStore: EndpointStore {
    private var device: PairedDevice?
    private var saveCount: Int = 0
    private var deleteCount: Int = 0
    private var saveFailure: PairingError?
    private var loadFailure: PairingError?
    private var deleteFailure: PairingError?

    public init(initial: PairedDevice? = nil) {
        self.device = initial
    }

    public func save(_ device: PairedDevice) async throws(PairingError) {
        if let saveFailure { throw saveFailure }
        self.device = device
        saveCount += 1
    }

    public func load() async throws(PairingError) -> PairedDevice? {
        if let loadFailure { throw loadFailure }
        return device
    }

    public func delete() async throws(PairingError) {
        if let deleteFailure { throw deleteFailure }
        device = nil
        deleteCount += 1
    }

    // MARK: - Test hooks

    /// Current stored value without entering the throwing API.
    public func snapshot() -> PairedDevice? { device }

    public func saveCallCount() -> Int { saveCount }
    public func deleteCallCount() -> Int { deleteCount }

    public func queueSaveFailure(_ error: PairingError) {
        saveFailure = error
    }

    public func queueLoadFailure(_ error: PairingError) {
        loadFailure = error
    }

    public func queueDeleteFailure(_ error: PairingError) {
        deleteFailure = error
    }

    public func clearInjectedFailures() {
        saveFailure = nil
        loadFailure = nil
        deleteFailure = nil
    }
}
