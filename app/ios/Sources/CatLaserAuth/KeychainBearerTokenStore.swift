#if canImport(Security) && canImport(Darwin)
import Foundation
import Security

public struct KeychainBearerTokenStore: BearerTokenStore {
    public let service: String
    public let account: String
    public let accessGroup: String?

    public init(
        service: String = "com.catlaser.app.auth",
        account: String = "session",
        accessGroup: String? = nil,
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func save(_ session: AuthSession) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(session)
        } catch {
            throw AuthError.malformedResponse("session encode: \(error.localizedDescription)")
        }

        var query = baseQuery()
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrSynchronizable as String] = kCFBooleanFalse
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AuthError.keychain(OSStatusCode(addStatus))
            }
        default:
            throw AuthError.keychain(OSStatusCode(updateStatus))
        }
    }

    public func load() async throws -> AuthSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw AuthError.keychain(OSStatusCode(errSecDecode))
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                return try decoder.decode(AuthSession.self, from: data)
            } catch {
                throw AuthError.malformedResponse("session decode: \(error.localizedDescription)")
            }
        case errSecItemNotFound:
            return nil
        default:
            throw AuthError.keychain(OSStatusCode(status))
        }
    }

    public func delete() async throws {
        let query = baseQuery()
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw AuthError.keychain(OSStatusCode(status))
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
