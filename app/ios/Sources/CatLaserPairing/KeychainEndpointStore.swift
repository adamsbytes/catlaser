#if canImport(Security) && canImport(Darwin)
import CatLaserAuth
import Foundation
import Security

/// Keychain-backed `EndpointStore` for the Tailscale endpoint of the
/// currently paired device.
///
/// The endpoint row is stored as a `kSecClassGenericPassword` item
/// with:
///
/// * `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
///   — readable after first unlock post-boot, never synced to iCloud
///   Keychain. Auto-reconnect after an app launch (e.g. app resumed
///   from the background) must be headless, so this store
///   deliberately does NOT wrap the item in a `.userPresence`
///   `SecAccessControl`. That would trigger a biometric prompt on
///   every reconnect, which is the wrong UX for a reconnect supervisor
///   that fires every Wi-Fi hop.
/// * `kSecAttrSynchronizable = false` on every query, not just add
///   — an accidental synced row on another device would otherwise
///   shadow a legitimate local row.
///
/// The stored payload is small (~200 bytes of JSON) and **not**
/// sensitive in the cryptographic sense — it is the Tailscale address
/// of the paired device. Reaching that address still requires the
/// device being online, the app carrying the session bearer, AND a
/// fresh SE-signed `api:` attestation for any protected operation on
/// the path. Threat model: a stolen device's unlocked keychain could
/// still not drive the device because the bearer is in a separately-
/// protected item (`KeychainBearerTokenStore`) wrapped in
/// `.userPresence`, and sign-out wipes this endpoint row via
/// `SessionLifecycleObserver`.
///
/// Also conforms to `SessionLifecycleObserver` (from `CatLaserAuth`)
/// so the auth coordinator can wipe the endpoint on sign-out without
/// knowing the pairing module exists.
public struct KeychainEndpointStore: EndpointStore, SessionLifecycleObserver {
    public let service: String
    public let account: String
    public let accessGroup: String?

    public init(
        service: String = "com.catlaser.app.pairing",
        account: String = "endpoint",
        accessGroup: String? = nil,
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func save(_ device: PairedDevice) async throws(PairingError) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(device)
        } catch {
            throw .storage("endpoint encode: \(error.localizedDescription)")
        }

        // Always delete-then-add: setting `kSecAttrAccessible` via
        // `SecItemUpdate` is unreliable across OS versions, and a row
        // left over from a previous install (on a restored device)
        // may have an accessibility that silently refuses reads.
        // Rebuilding the row guarantees the flag we want.
        let deleteStatus = SecItemDelete(baseQuery() as CFDictionary)
        switch deleteStatus {
        case errSecSuccess, errSecItemNotFound:
            break
        default:
            throw .storage("keychain delete OSStatus \(deleteStatus)")
        }

        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw .storage("keychain add OSStatus \(addStatus)")
        }
    }

    public func load() async throws(PairingError) -> PairedDevice? {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw .storage("keychain decode: unexpected payload shape")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                return try decoder.decode(PairedDevice.self, from: data)
            } catch {
                // A corrupted row is non-recoverable — wipe and
                // return nil so the app prompts a re-pair instead of
                // getting stuck in a load-fail loop. Ignore the
                // delete outcome; even on failure we've surfaced the
                // corruption to the caller.
                _ = SecItemDelete(baseQuery() as CFDictionary)
                throw .storage("endpoint decode: \(error.localizedDescription)")
            }
        case errSecItemNotFound:
            return nil
        default:
            throw .storage("keychain read OSStatus \(status)")
        }
    }

    public func delete() async throws(PairingError) {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw .storage("keychain delete OSStatus \(status)")
        }
    }

    // MARK: - SessionLifecycleObserver

    /// Wipes the stored endpoint on sign-out. Swallows storage errors
    /// — a sign-out that fails to clear the endpoint must still
    /// complete; the endpoint is not security-sensitive by itself,
    /// the bearer ACL already gates all wire access.
    public func sessionDidSignOut() async {
        try? await delete()
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

#endif
