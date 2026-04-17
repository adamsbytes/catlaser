#if canImport(Security) && canImport(Darwin)
import Foundation
import Security
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Bearer-token store that accepts a pre-authenticated `LAContext` on
/// read. `GatedBearerTokenStore` wraps any implementation of this
/// protocol; production uses `KeychainBearerTokenStore`, tests use a
/// `MockAuthenticatingBearerTokenStore` to exercise cache/gate interaction
/// without a real keychain.
public protocol AuthenticatingBearerTokenStore: Sendable {
    func save(_ session: AuthSession) async throws
    func load(authenticatedWith context: LAContext?) async throws -> AuthSession?
    func delete() async throws
}

/// Keychain-backed bearer token store.
///
/// Two defences stack on every persisted session:
///
/// 1. **Accessibility** is pinned to
///    `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — the token is
///    inaccessible before first unlock after boot, and never leaves the
///    device via iCloud Keychain (`kSecAttrSynchronizable = false`, enforced
///    on every query, not just the add path).
///
/// 2. **Access control** can wrap the item with `.userPresence`, meaning
///    every read requires biometric *or* device-passcode authentication at
///    the OS layer. This is a hardware-enforced backstop: even an attacker
///    who dumps the keychain from an unlocked phone cannot exfiltrate the
///    bearer token without the user's biometrics or passcode.
///
/// Callers that need to avoid spamming biometric prompts on every HTTP
/// request should wrap this store with `GatedBearerTokenStore`, which adds
/// an in-memory token cache and an idle-timeout window above the keychain
/// layer.
public struct KeychainBearerTokenStore: BearerTokenStore, AuthenticatingBearerTokenStore {
    /// How the keychain item is protected against unauthorized reads.
    /// **Package-private** — the public initializer always installs
    /// `.userPresence`. The test-only `.accessibilityOnly` variant is
    /// reachable only from within the module so it cannot be wired into
    /// production by downstream code. A production build that silently
    /// fell back to `.accessibilityOnly` would strip the hardware ACL
    /// that protects the bearer token on a stolen unlocked phone — the
    /// reason it is unreachable from public API.
    enum AccessPolicy: Sendable, Equatable {
        /// Accessibility attribute only. Reads succeed whenever the device
        /// is unlocked. Used exclusively by integration tests that need
        /// to exercise the keychain code path without biometric prompts.
        case accessibilityOnly
        /// Item is wrapped with `SecAccessControl(.userPresence)`. Reads
        /// require biometric or device-passcode authentication at the OS
        /// layer. The only policy reachable from production code.
        case userPresence
    }

    public let service: String
    public let account: String
    public let accessGroup: String?
    let policy: AccessPolicy

    public init(
        service: String = "com.catlaser.app.auth",
        account: String = "session",
        accessGroup: String? = nil,
    ) {
        self.init(
            service: service,
            account: account,
            accessGroup: accessGroup,
            policy: .userPresence,
        )
    }

    /// Package-private initializer used by tests to construct a store
    /// with `.accessibilityOnly` so they can exercise the keychain
    /// without triggering biometric prompts. Not reachable from outside
    /// the module; production code always uses the public initializer
    /// which pins the policy to `.userPresence`.
    init(
        service: String,
        account: String,
        accessGroup: String?,
        policy: AccessPolicy,
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.policy = policy
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

        // Always delete-then-add: SecAccessControl on an existing item
        // cannot be changed via SecItemUpdate, so updating the value of a
        // protected item either fails or silently keeps the old ACL. The
        // only reliable write path is remove-then-insert.
        let deleteStatus = SecItemDelete(baseQuery() as CFDictionary)
        switch deleteStatus {
        case errSecSuccess, errSecItemNotFound:
            break
        default:
            throw AuthError.keychain(OSStatusCode(deleteStatus))
        }

        var add = baseQuery()
        add[kSecValueData as String] = data
        try applyAccessControl(to: &add)

        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AuthError.keychain(OSStatusCode(addStatus))
        }
    }

    public func load() async throws -> AuthSession? {
        try await load(authenticatedWith: nil)
    }

    /// Read the session, optionally supplying a pre-authenticated
    /// `LAContext`. When `context` is nil and the stored item is protected
    /// by `.userPresence`, the OS will prompt with its own default UI; when
    /// `context` is non-nil, it must already have evaluated
    /// `.deviceOwnerAuthentication` — the caller (normally
    /// `GatedBearerTokenStore`) is responsible for that prompt, and passes
    /// the authenticated context here.
    public func load(authenticatedWith context: LAContext?) async throws -> AuthSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }

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
        case errSecUserCanceled, errSecAuthFailed:
            throw AuthError.biometricFailed(status: Int32(status))
        default:
            throw AuthError.keychain(OSStatusCode(status))
        }
    }

    public func delete() async throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw AuthError.keychain(OSStatusCode(status))
        }
    }

    /// Base query used by every read/update/add/delete. Explicitly pinned to
    /// non-synchronizing items so an accidental synced item cannot satisfy
    /// this query and leak the bearer token across iCloud-Keychain-paired
    /// devices.
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

    /// Apply accessibility and (optionally) access-control flags to an add
    /// dictionary. When the `.userPresence` policy is active, the item is
    /// wrapped in a `SecAccessControl` that demands biometric or passcode
    /// authentication on every read; in that case we must *not* also set
    /// `kSecAttrAccessible`, because the access control supersedes it.
    private func applyAccessControl(to query: inout [String: Any]) throws {
        switch policy {
        case .accessibilityOnly:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .userPresence:
            var cfError: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                .userPresence,
                &cfError,
            ) else {
                if let cfError {
                    let error = cfError.takeRetainedValue()
                    throw AuthError.biometricUnavailable("SecAccessControlCreateWithFlags: \(CFErrorCopyDescription(error) as String)")
                }
                throw AuthError.biometricUnavailable("SecAccessControlCreateWithFlags returned nil")
            }
            query[kSecAttrAccessControl as String] = accessControl
        }
    }
}
#endif
