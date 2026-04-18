import Foundation

/// Persistent store for the current `PairedDevice`.
///
/// Exactly one paired device is supported per app install. Re-pairing
/// overwrites the stored row. Sign-out wipes it (see
/// `SessionLifecycleObserver` conformance on
/// `KeychainEndpointStore`).
///
/// The store is a protocol, not a concrete type, so tests can
/// substitute an in-memory implementation — `KeychainEndpointStore`
/// on Darwin, `InMemoryEndpointStore` everywhere else.
///
/// Reads never prompt the user. The stored endpoint is not a secret
/// (a Tailscale endpoint is useless without the device being online
/// AND the app being signed in AND carrying the session's SE key); it
/// is protected only by `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// so that auto-reconnect after an app launch does not require an
/// interactive unlock.
public protocol EndpointStore: Sendable {
    /// Persist `device`. Overwrites any previously stored row. A
    /// prior row MAY have been deleted behind the store's back
    /// (manual keychain wipe, device restore); implementations must
    /// succeed on the first save after that.
    func save(_ device: PairedDevice) async throws(PairingError)

    /// Load the current paired device. Returns `nil` when no row
    /// exists. Throws on any keychain error other than
    /// `errSecItemNotFound`.
    func load() async throws(PairingError) -> PairedDevice?

    /// Remove the stored row. Idempotent — a missing row is success.
    func delete() async throws(PairingError)
}

/// Test-only in-memory implementation. Package-visible; the
/// `CatLaserPairingTestSupport` target re-exports it under a public
/// name via wrapper, so downstream product code cannot reach this
/// directly.
actor InMemoryEndpointStore: EndpointStore {
    private var device: PairedDevice?

    init(initial: PairedDevice? = nil) {
        self.device = initial
    }

    func save(_ device: PairedDevice) async throws(PairingError) {
        self.device = device
    }

    func load() async throws(PairingError) -> PairedDevice? {
        device
    }

    func delete() async throws(PairingError) {
        device = nil
    }
}
