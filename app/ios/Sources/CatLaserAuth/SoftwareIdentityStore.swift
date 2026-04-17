import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Software-backed `DeviceIdentityStoring` for tests and non-Darwin CI.
///
/// Generates a P-256 key in-process using CryptoKit / swift-crypto. The
/// key material lives in memory for the lifetime of the actor; there is
/// no persistence. Production code MUST use `SecureEnclaveIdentityStore`
/// instead — the software store exists only so tests that cannot call
/// into SE (SPM test runners, Linux CI) can still exercise the signing
/// path and assert wire format byte-for-byte.
///
/// Seeded variant: pass a deterministic `rawPrivateKey` so tests can
/// assert the exact public key / install ID / signature inputs, not
/// merely their shape.
public actor SoftwareIdentityStore: DeviceIdentityStoring {
    private var privateKey: P256.Signing.PrivateKey
    private var cachedSPKI: Data?
    private var cachedInstallID: String?

    public init() {
        self.privateKey = P256.Signing.PrivateKey()
    }

    /// Load a key from a raw 32-byte scalar. Used by tests that need a
    /// deterministic public key. Throws if `rawPrivateKey` is not a
    /// valid P-256 scalar.
    public init(rawPrivateKey: Data) throws(AuthError) {
        do {
            self.privateKey = try P256.Signing.PrivateKey(rawRepresentation: rawPrivateKey)
        } catch {
            throw AuthError.attestationFailed("invalid P-256 raw key: \(error.localizedDescription)")
        }
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
        // CryptoKit's `.derRepresentation` on a P-256 public key returns
        // the full DER-encoded SubjectPublicKeyInfo (91 bytes for P-256).
        // That matches exactly what SecureEnclaveIdentityStore assembles
        // from the 26-byte SPKI prefix + 65-byte X9.63 point, so both
        // stores produce byte-identical SPKI for a given key.
        let spki = privateKey.publicKey.derRepresentation
        cachedSPKI = spki
        return spki
    }

    public func sign(_ message: Data) async throws -> Data {
        let signature: P256.Signing.ECDSASignature
        do {
            signature = try privateKey.signature(for: message)
        } catch {
            throw AuthError.attestationFailed("ECDSA signing failed: \(error.localizedDescription)")
        }
        return signature.derRepresentation
    }

    public func reset() async throws {
        privateKey = P256.Signing.PrivateKey()
        cachedSPKI = nil
        cachedInstallID = nil
    }
}
