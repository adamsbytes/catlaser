#if canImport(Security) && canImport(Darwin)
import Foundation
import Security
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Production `DeviceIdentityStoring` backed by the Secure Enclave.
///
/// The private key is generated with `kSecAttrTokenID` =
/// `kSecAttrTokenIDSecureEnclave` — the raw scalar never exists outside SE
/// hardware. Even an attacker with root on a jailbroken device cannot
/// extract the scalar; at worst they can ask SE to sign arbitrary messages
/// while the device is unlocked, which requires maintained privileged
/// access to the victim's physical device. This is a substantially higher
/// bar than the previous "read the install-ID UUID from keychain" model.
///
/// Accessibility is pinned to
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — the key is
/// unavailable before first unlock after boot, does not sync via iCloud
/// Keychain, and is destroyed if the device is erased. No `.userPresence`
/// is required on signing: the attestation is emitted on every auth
/// request, and prompting for biometrics per-request would be ruinous UX.
/// The non-extractability property of the SE is the primary defence; ACL
/// gating is orthogonal and used only for the bearer token.
///
/// **Race handling.** First-use key creation follows an add-only pattern:
///
/// 1. Lookup existing key by tag.
/// 2. If not found, generate (permanent = true, tag = our tag).
/// 3. If generation fails with `errSecDuplicateItem`, another process
///    won the race — look up and return that key.
///
/// Combined with actor isolation this is correct under concurrent readers
/// both within a process (actor serialises them) and across processes
/// (Keychain is the arbiter; add-only yields a unique survivor).
public actor SecureEnclaveIdentityStore: DeviceIdentityStoring {
    public let applicationTag: Data

    /// In-memory cache so repeated calls within a process don't hit the
    /// keychain. Populated by `resolveKey()`; invalidated by `reset()`.
    private var cachedKey: SecKey?
    private var cachedSPKI: Data?
    private var cachedInstallID: String?

    public init(applicationTag: String = "com.catlaser.app.auth.device-identity.v2") {
        self.applicationTag = Data(applicationTag.utf8)
    }

    public func installID() async throws -> String {
        if let cachedInstallID { return cachedInstallID }
        let spki = try await publicKeySPKI()
        let id = DeviceIdentity.installID(fromSPKI: spki)
        cachedInstallID = id
        return id
    }

    public func publicKeySPKI() async throws -> Data {
        if let cachedSPKI { return cachedSPKI }
        let privateKey = try resolveKey()
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw AuthError.attestationFailed("SecKeyCopyPublicKey returned nil")
        }
        var cfError: Unmanaged<CFError>?
        guard let raw = SecKeyCopyExternalRepresentation(publicKey, &cfError) as Data? else {
            let message = cfError.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "unknown"
            throw AuthError.attestationFailed("SecKeyCopyExternalRepresentation: \(message)")
        }
        let spki = try DeviceIdentity.spki(fromX963: raw)
        cachedSPKI = spki
        return spki
    }

    public func sign(_ message: Data) async throws -> Data {
        let privateKey = try resolveKey()
        var cfError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            message as CFData,
            &cfError,
        ) as Data? else {
            let message = cfError.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "unknown"
            throw AuthError.attestationFailed("SecKeyCreateSignature: \(message)")
        }
        return signature
    }

    public func reset() async throws {
        cachedKey = nil
        cachedSPKI = nil
        cachedInstallID = nil
        let status = SecItemDelete(lookupQuery() as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw AuthError.keychain(OSStatusCode(status))
        }
    }

    private func resolveKey() throws -> SecKey {
        if let cachedKey { return cachedKey }
        if let existing = try lookupKey() {
            cachedKey = existing
            return existing
        }
        do {
            let generated = try generateKey()
            cachedKey = generated
            return generated
        } catch AuthError.keychain(let status) where status.rawValue == errSecDuplicateItem {
            guard let existing = try lookupKey() else {
                throw AuthError.attestationFailed(
                    "SE key generation reported duplicate but lookup failed",
                )
            }
            cachedKey = existing
            return existing
        }
    }

    private func lookupKey() throws -> SecKey? {
        var query = lookupQuery()
        query[kSecReturnRef as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            // CFTypeRef → SecKey. The force cast is load-bearing: a
            // non-SecKey value here would mean the keychain returned data
            // for a non-ref query, which is an OS-level invariant break.
            return (item as! SecKey) // swiftlint:disable:this force_cast
        case errSecItemNotFound:
            return nil
        default:
            throw AuthError.keychain(OSStatusCode(status))
        }
    }

    private func generateKey() throws -> SecKey {
        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            .privateKeyUsage,
            &accessError,
        ) else {
            let message = accessError.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "unknown"
            throw AuthError.secureEnclaveUnavailable("SecAccessControlCreateWithFlags: \(message)")
        }
        var privateAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: applicationTag,
            kSecAttrAccessControl as String: accessControl,
        ]
        // Passing synchronizable explicitly guards against keychain default
        // drift across iOS versions.
        privateAttrs[kSecAttrSynchronizable as String] = kCFBooleanFalse
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: privateAttrs,
        ]
        var cfError: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &cfError) else {
            guard let err = cfError?.takeRetainedValue() else {
                throw AuthError.secureEnclaveUnavailable("SecKeyCreateRandomKey returned nil without error")
            }
            let status = OSStatus(CFErrorGetCode(err))
            if status == errSecDuplicateItem {
                throw AuthError.keychain(OSStatusCode(errSecDuplicateItem))
            }
            let description = CFErrorCopyDescription(err) as String
            // Any non-duplicate error indicates the SE refused the
            // request — almost always "SE not available" (simulator
            // pre-iOS 16) or "policy rejection".
            throw AuthError.secureEnclaveUnavailable("SecKeyCreateRandomKey: \(description) [OSStatus \(status)]")
        }
        return key
    }

    private func lookupQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: applicationTag,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}
#endif
