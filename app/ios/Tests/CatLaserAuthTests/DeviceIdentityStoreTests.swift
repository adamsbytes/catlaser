import Foundation
import Testing

@testable import CatLaserAuth

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

@Suite("DeviceIdentity helpers")
struct DeviceIdentityHelpersTests {
    @Test
    func installIDIsDeterministicFromSPKI() {
        let spki = Data(DeviceIdentity.ecP256SPKIPrefix + [UInt8](repeating: 0x11, count: 65))
        let a = DeviceIdentity.installID(fromSPKI: spki)
        let b = DeviceIdentity.installID(fromSPKI: spki)
        #expect(a == b)
        #expect(!a.isEmpty)
    }

    @Test
    func installIDDiffersForDifferentSPKI() {
        let first = Data(DeviceIdentity.ecP256SPKIPrefix + [UInt8](repeating: 0x11, count: 65))
        let second = Data(DeviceIdentity.ecP256SPKIPrefix + [UInt8](repeating: 0x22, count: 65))
        #expect(DeviceIdentity.installID(fromSPKI: first)
            != DeviceIdentity.installID(fromSPKI: second))
    }

    @Test
    func installIDIsBase64URLWithoutPadding() {
        let spki = Data(DeviceIdentity.ecP256SPKIPrefix + [UInt8](repeating: 0x11, count: 65))
        let id = DeviceIdentity.installID(fromSPKI: spki)
        #expect(!id.contains("="), "base64url-no-pad must not contain '='")
        #expect(!id.contains("+"), "base64url must not contain '+'")
        #expect(!id.contains("/"), "base64url must not contain '/'")
    }

    @Test
    func spkiBuilderRejectsWrongLength() {
        do {
            _ = try DeviceIdentity.spki(fromX963: Data(repeating: 0x04, count: 64))
            Issue.record("expected failure")
        } catch AuthError.attestationFailed {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func spkiBuilderRejectsCompressedPoint() {
        // Uncompressed points start with 0x04; 0x02 / 0x03 are compressed
        // forms and not accepted.
        do {
            _ = try DeviceIdentity.spki(fromX963: Data([UInt8](repeating: 0x03, count: 65)))
            Issue.record("expected failure")
        } catch AuthError.attestationFailed {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func spkiBuilderProducesStandardSPKI() throws {
        let x963 = Data([0x04] + [UInt8](repeating: 0xAA, count: 64))
        let spki = try DeviceIdentity.spki(fromX963: x963)
        #expect(spki.count == 91)
        #expect(spki.prefix(26) == Data(DeviceIdentity.ecP256SPKIPrefix))
        #expect(spki.suffix(65) == x963)
    }
}

@Suite("SoftwareIdentityStore")
struct SoftwareIdentityStoreTests {
    @Test
    func installIDStableAcrossCalls() async throws {
        let store = SoftwareIdentityStore()
        let a = try await store.installID()
        let b = try await store.installID()
        #expect(a == b)
        #expect(!a.isEmpty)
    }

    @Test
    func publicKeySPKIIsValidDER() async throws {
        let store = SoftwareIdentityStore()
        let spki = try await store.publicKeySPKI()
        #expect(spki.count == 91)
        #expect(spki.prefix(26) == Data(DeviceIdentity.ecP256SPKIPrefix))
        // Round-trip through swift-crypto: the SPKI must parse back to a
        // usable P-256 public key.
        _ = try P256.Signing.PublicKey(derRepresentation: spki)
    }

    @Test
    func signaturesAreVerifiableAgainstPublishedKey() async throws {
        let store = SoftwareIdentityStore()
        let message = Data("hello".utf8)
        let sigData = try await store.sign(message)
        let sig = try P256.Signing.ECDSASignature(derRepresentation: sigData)
        let key = try P256.Signing.PublicKey(derRepresentation: try await store.publicKeySPKI())
        #expect(key.isValidSignature(sig, for: message))
    }

    @Test
    func differentMessagesProduceDifferentSignatures() async throws {
        let store = SoftwareIdentityStore()
        let sigA = try await store.sign(Data("a".utf8))
        let sigB = try await store.sign(Data("b".utf8))
        #expect(sigA != sigB)
    }

    @Test
    func sameMessageSignatureFreshPerCall() async throws {
        // ECDSA is non-deterministic by design — fresh sig per call, but
        // both verify.
        let store = SoftwareIdentityStore()
        let message = Data("repeat".utf8)
        let sigA = try await store.sign(message)
        let sigB = try await store.sign(message)
        #expect(sigA != sigB)
        let key = try P256.Signing.PublicKey(derRepresentation: try await store.publicKeySPKI())
        #expect(key.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: sigA), for: message))
        #expect(key.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: sigB), for: message))
    }

    @Test
    func resetRegeneratesKey() async throws {
        let store = SoftwareIdentityStore()
        let idBefore = try await store.installID()
        try await store.reset()
        let idAfter = try await store.installID()
        #expect(idBefore != idAfter, "reset must produce a new SPKI/install ID")
    }

    @Test
    func seededStoreIsReproducible() async throws {
        // Load the same scalar twice; both stores must publish identical
        // SPKI and install IDs. Used to give tests stable wire-format
        // assertions without depending on random generation.
        let raw = Data([UInt8](repeating: 0x01, count: 32))
        let a = try SoftwareIdentityStore(rawPrivateKey: raw)
        let b = try SoftwareIdentityStore(rawPrivateKey: raw)
        #expect(try await a.installID() == (try await b.installID()))
        #expect(try await a.publicKeySPKI() == (try await b.publicKeySPKI()))
    }

    @Test
    func seededStoreRejectsInvalidScalar() async throws {
        // An all-zero 32-byte scalar is not a valid P-256 private key.
        do {
            _ = try SoftwareIdentityStore(rawPrivateKey: Data(repeating: 0, count: 32))
            Issue.record("expected failure")
        } catch AuthError.attestationFailed {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func concurrentReadsConverge() async throws {
        let store = SoftwareIdentityStore()
        let ids = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    (try? await store.installID()) ?? ""
                }
            }
            var collected: [String] = []
            for await id in group {
                collected.append(id)
            }
            return collected
        }
        let unique = Set(ids)
        #expect(unique.count == 1, "32 concurrent readers must see the same ID; saw \(unique.count)")
    }
}

#if canImport(Security) && canImport(Darwin)
import Security

@Suite("SecureEnclaveIdentityStore")
struct SecureEnclaveIdentityStoreTests {
    /// Some build environments (Linux CI, old-simulator test hosts) do
    /// not offer a usable Secure Enclave. Those skip the SE suite and
    /// rely on the software store for coverage; the SE tests run only
    /// where the hardware is present.
    private func skipIfSEUnavailable(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let tag = "com.catlaser.tests.se.probe.\(UUID().uuidString)".data(using: .utf8)!
        let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            .privateKeyUsage,
            nil,
        )
        guard accessControl != nil else {
            throw TestSkipped.noSecureEnclave
        }
        let privateAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: false,
            kSecAttrApplicationTag as String: tag,
            kSecAttrAccessControl as String: accessControl!,
        ]
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: privateAttrs,
        ]
        var cfError: Unmanaged<CFError>?
        guard SecKeyCreateRandomKey(attributes as CFDictionary, &cfError) != nil else {
            throw TestSkipped.noSecureEnclave
        }
    }

    enum TestSkipped: Error {
        case noSecureEnclave
    }

    private func uniqueStore() -> SecureEnclaveIdentityStore {
        SecureEnclaveIdentityStore(
            applicationTag: "com.catlaser.tests.se.\(UUID().uuidString)",
        )
    }

    @Test
    func installIDStableAcrossCalls() async throws {
        do {
            try await skipIfSEUnavailable()
        } catch TestSkipped.noSecureEnclave {
            return
        }
        let store = uniqueStore()
        defer { Task { try? await store.reset() } }
        let a = try await store.installID()
        let b = try await store.installID()
        #expect(a == b)
    }

    @Test
    func publicKeyIsValidDERP256SPKI() async throws {
        do {
            try await skipIfSEUnavailable()
        } catch TestSkipped.noSecureEnclave {
            return
        }
        let store = uniqueStore()
        defer { Task { try? await store.reset() } }
        let spki = try await store.publicKeySPKI()
        #expect(spki.count == 91)
        #expect(spki.prefix(26) == Data(DeviceIdentity.ecP256SPKIPrefix))
        _ = try P256.Signing.PublicKey(derRepresentation: spki)
    }

    @Test
    func signaturesVerifyAgainstPublishedPublicKey() async throws {
        do {
            try await skipIfSEUnavailable()
        } catch TestSkipped.noSecureEnclave {
            return
        }
        let store = uniqueStore()
        defer { Task { try? await store.reset() } }
        let message = Data(repeating: 0xAB, count: 32)
        let sigData = try await store.sign(message)
        let sig = try P256.Signing.ECDSASignature(derRepresentation: sigData)
        let key = try P256.Signing.PublicKey(derRepresentation: try await store.publicKeySPKI())
        #expect(key.isValidSignature(sig, for: message))
    }

    @Test
    func resetThenReadRegeneratesKey() async throws {
        do {
            try await skipIfSEUnavailable()
        } catch TestSkipped.noSecureEnclave {
            return
        }
        let store = uniqueStore()
        defer { Task { try? await store.reset() } }
        let idBefore = try await store.installID()
        try await store.reset()
        let idAfter = try await store.installID()
        #expect(idBefore != idAfter)
    }

    @Test
    func concurrentFirstUseConvergesOnOneKey() async throws {
        // The core of H3: if multiple tasks first-read the identity in
        // the same process at the same time, they must all observe the
        // same install ID. Race either resolves within the actor or is
        // arbitrated by the keychain's add-only semantics.
        do {
            try await skipIfSEUnavailable()
        } catch TestSkipped.noSecureEnclave {
            return
        }
        let store = uniqueStore()
        defer { Task { try? await store.reset() } }
        let ids = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for _ in 0 ..< 16 {
                group.addTask {
                    try? await store.installID()
                }
            }
            var collected: [String] = []
            for await id in group {
                if let id { collected.append(id) }
            }
            return collected
        }
        #expect(ids.count == 16)
        #expect(Set(ids).count == 1, "16 concurrent readers must converge on one install ID")
    }
}

#endif
