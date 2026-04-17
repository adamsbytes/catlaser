#if canImport(Security) && canImport(Darwin)
import Foundation
import Security

/// Keychain-backed install ID. Stored with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and
/// `kSecAttrSynchronizable = false` — the ID stays on this device, never
/// syncs via iCloud Keychain, and survives app reinstall (by Apple's default
/// behaviour) which is the correct trade-off for a fingerprint seed.
public struct KeychainInstallIDStore: InstallIDStoring {
    public let service: String
    public let account: String
    public let accessGroup: String?
    private let generator: @Sendable () -> String

    public init(
        service: String = "com.catlaser.app.auth",
        account: String = "install-id",
        accessGroup: String? = nil,
    ) {
        self.init(
            service: service,
            account: account,
            accessGroup: accessGroup,
            generator: { UUID().uuidString },
        )
    }

    init(
        service: String,
        account: String,
        accessGroup: String?,
        generator: @escaping @Sendable () -> String,
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.generator = generator
    }

    public func currentID() async throws -> String {
        if let existing = try readValue() {
            return existing
        }
        let generated = generator()
        guard !generated.isEmpty else {
            throw AuthError.fingerprintCaptureFailed("install ID generator returned empty value")
        }
        try writeValue(generated)
        // Read back to defend against the rare case where another instance
        // wrote concurrently between our read and write — keep the first
        // persisted value, not ours.
        if let persisted = try readValue() {
            return persisted
        }
        throw AuthError.fingerprintCaptureFailed("install ID persisted but not readable")
    }

    public func reset() async throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw AuthError.keychain(OSStatusCode(status))
        }
    }

    private func readValue() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8),
                  !value.isEmpty
            else {
                throw AuthError.keychain(OSStatusCode(errSecDecode))
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw AuthError.keychain(OSStatusCode(status))
        }
    }

    private func writeValue(_ value: String) throws {
        let data = Data(value.utf8)
        var attributes = baseQuery()
        let payload: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(attributes as CFDictionary, payload as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            for (key, value) in payload {
                attributes[key] = value
            }
            attributes[kSecAttrSynchronizable as String] = kCFBooleanFalse
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            switch addStatus {
            case errSecSuccess, errSecDuplicateItem:
                return
            default:
                throw AuthError.keychain(OSStatusCode(addStatus))
            }
        default:
            throw AuthError.keychain(OSStatusCode(updateStatus))
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
#endif
