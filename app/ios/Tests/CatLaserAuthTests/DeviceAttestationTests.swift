import Foundation
import Testing

@testable import CatLaserAuth

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

private func makeFingerprint(installID: String = "01234567-89AB-CDEF-0123-456789ABCDEF") -> DeviceFingerprint {
    DeviceFingerprint(
        platform: "ios",
        model: "iPhone15,4",
        systemName: "iOS",
        osVersion: "17.4.1",
        locale: "en_US",
        timezone: "America/Denver",
        appVersion: "1.0.0",
        appBuild: "42",
        bundleID: "com.catlaser.app",
        installID: installID,
    )
}

@Suite("DeviceFingerprint canonical JSON")
struct DeviceFingerprintCanonicalJSONTests {
    @Test
    func keysAreSortedAndValuesRenderExactly() throws {
        let fingerprint = makeFingerprint()
        let bytes = try fingerprint.canonicalJSONBytes()
        let json = try #require(String(data: bytes, encoding: .utf8))
        #expect(json == """
        {"appBuild":"42","appVersion":"1.0.0","bundleID":"com.catlaser.app","installID":"01234567-89AB-CDEF-0123-456789ABCDEF","locale":"en_US","model":"iPhone15,4","osVersion":"17.4.1","platform":"ios","systemName":"iOS","timezone":"America/Denver"}
        """)
    }

    @Test
    func identicalInputsYieldIdenticalBytes() throws {
        let a = try makeFingerprint().canonicalJSONBytes()
        let b = try makeFingerprint().canonicalJSONBytes()
        #expect(a == b)
    }

    @Test
    func differentInstallIDYieldsDifferentBytes() throws {
        let a = try makeFingerprint(installID: "a").canonicalJSONBytes()
        let b = try makeFingerprint(installID: "b").canonicalJSONBytes()
        #expect(a != b)
    }
}

@Suite("DeviceAttestationEncoder")
struct DeviceAttestationEncoderTests {
    private func sample() -> DeviceAttestation {
        let spki = Data(DeviceIdentity.ecP256SPKIPrefix + [UInt8](repeating: 0xCD, count: 65))
        return DeviceAttestation(
            fingerprintHash: Data(repeating: 0xAB, count: 32),
            publicKeySPKI: spki,
            signature: Data(repeating: 0x12, count: 70),
        )
    }

    @Test
    func roundTripsThroughDecoder() throws {
        let attestation = sample()
        let encoded = try DeviceAttestationEncoder.encodeHeaderValue(attestation)
        let decoded = try DeviceAttestationEncoder.decodeHeaderValue(encoded)
        #expect(decoded == attestation)
    }

    @Test
    func headerIsPlainBase64() throws {
        let encoded = try DeviceAttestationEncoder.encodeHeaderValue(sample())
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        #expect(encoded.unicodeScalars.allSatisfy(allowed.contains))
    }

    @Test
    func identicalInputsProduceIdenticalHeaders() throws {
        let attestation = sample()
        let a = try DeviceAttestationEncoder.encodeHeaderValue(attestation)
        let b = try DeviceAttestationEncoder.encodeHeaderValue(attestation)
        #expect(a == b, "encoder must be deterministic for server-side byte comparison of fph/pk")
    }

    @Test
    func decodedFphMatchesRawHash() throws {
        let encoded = try DeviceAttestationEncoder.encodeHeaderValue(sample())
        let decoded = try DeviceAttestationEncoder.decodeHeaderValue(encoded)
        #expect(decoded.fingerprintHash.count == 32)
        #expect(decoded.fingerprintHash == Data(repeating: 0xAB, count: 32))
    }

    @Test
    func rejectsWrongHashLength() {
        let spki = Data(DeviceIdentity.ecP256SPKIPrefix + [UInt8](repeating: 0xCD, count: 65))
        let bad = DeviceAttestation(
            fingerprintHash: Data(repeating: 0, count: 31),
            publicKeySPKI: spki,
            signature: Data(repeating: 0, count: 70),
        )
        do {
            _ = try DeviceAttestationEncoder.encodeHeaderValue(bad)
            Issue.record("expected attestationFailed")
        } catch let AuthError.attestationFailed(msg) {
            #expect(msg.contains("32"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func rejectsNonP256SPKI() {
        // Flip one byte of the prefix so it no longer matches the P-256
        // SPKI prefix the server expects. Encoder must refuse.
        var prefix = DeviceIdentity.ecP256SPKIPrefix
        prefix[0] ^= 0xFF
        let bogusSPKI = Data(prefix + [UInt8](repeating: 0, count: 65))
        let bad = DeviceAttestation(
            fingerprintHash: Data(repeating: 0, count: 32),
            publicKeySPKI: bogusSPKI,
            signature: Data(repeating: 0, count: 70),
        )
        do {
            _ = try DeviceAttestationEncoder.encodeHeaderValue(bad)
            Issue.record("expected attestationFailed")
        } catch let AuthError.attestationFailed(msg) {
            #expect(msg.contains("SPKI"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func rejectsEmptySignature() {
        let spki = Data(DeviceIdentity.ecP256SPKIPrefix + [UInt8](repeating: 0, count: 65))
        let bad = DeviceAttestation(
            fingerprintHash: Data(repeating: 0, count: 32),
            publicKeySPKI: spki,
            signature: Data(),
        )
        do {
            _ = try DeviceAttestationEncoder.encodeHeaderValue(bad)
            Issue.record("expected attestationFailed")
        } catch let AuthError.attestationFailed(msg) {
            #expect(msg.contains("signature"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func decoderRejectsInvalidOuterBase64() {
        do {
            _ = try DeviceAttestationEncoder.decodeHeaderValue("not$$base64!!")
            Issue.record("expected decode failure")
        } catch let AuthError.attestationFailed(msg) {
            #expect(msg.contains("base64"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func headerStaysWellBelowHeaderLimit() throws {
        let encoded = try DeviceAttestationEncoder.encodeHeaderValue(sample())
        #expect(encoded.utf8.count < 1024, "expected < 1 KiB, got \(encoded.utf8.count) bytes")
        #expect(encoded.utf8.count <= DeviceAttestationEncoder.maxHeaderValueBytes)
    }
}

@Suite("DeviceAttestationBuilder end-to-end")
struct DeviceAttestationBuilderTests {
    @Test
    func signaturesVerifyUnderThePublishedPublicKey() async throws {
        // This is the load-bearing server-port assertion: the sig on the
        // wire must verify against the pk on the wire, over the fph on the
        // wire, under a standard P-256 ECDSA implementation. If this
        // doesn't hold, no server can authenticate the client.
        let identity = SoftwareIdentityStore()
        let fingerprint = makeFingerprint(installID: try await identity.installID())
        let attestation = try await DeviceAttestationBuilder.build(
            fingerprint: fingerprint,
            identity: identity,
        )

        let key = try P256.Signing.PublicKey(derRepresentation: attestation.publicKeySPKI)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: attestation.signature)
        #expect(key.isValidSignature(signature, for: attestation.fingerprintHash))
    }

    @Test
    func fphIsSha256OfCanonicalJSON() async throws {
        let identity = SoftwareIdentityStore()
        let fingerprint = makeFingerprint(installID: try await identity.installID())
        let attestation = try await DeviceAttestationBuilder.build(
            fingerprint: fingerprint,
            identity: identity,
        )
        let expected = Data(SHA256.hash(data: try fingerprint.canonicalJSONBytes()))
        #expect(attestation.fingerprintHash == expected)
    }

    @Test
    func fphDiffersWhenAnyFingerprintFieldChanges() async throws {
        let identity = SoftwareIdentityStore()
        let id = try await identity.installID()
        let a = try await DeviceAttestationBuilder.build(
            fingerprint: makeFingerprint(installID: id),
            identity: identity,
        )
        var modified = makeFingerprint(installID: id)
        modified = DeviceFingerprint(
            platform: modified.platform,
            model: "iPhone1,1",
            systemName: modified.systemName,
            osVersion: modified.osVersion,
            locale: modified.locale,
            timezone: modified.timezone,
            appVersion: modified.appVersion,
            appBuild: modified.appBuild,
            bundleID: modified.bundleID,
            installID: modified.installID,
        )
        let b = try await DeviceAttestationBuilder.build(fingerprint: modified, identity: identity)
        #expect(a.fingerprintHash != b.fingerprintHash, "changing the model byte must change fph")
    }

    @Test
    func signaturesFreshPerCallButPublicKeyStable() async throws {
        let identity = SoftwareIdentityStore()
        let fingerprint = makeFingerprint(installID: try await identity.installID())
        let a = try await DeviceAttestationBuilder.build(fingerprint: fingerprint, identity: identity)
        let b = try await DeviceAttestationBuilder.build(fingerprint: fingerprint, identity: identity)
        #expect(a.fingerprintHash == b.fingerprintHash)
        #expect(a.publicKeySPKI == b.publicKeySPKI)
        #expect(a.signature != b.signature, "ECDSA is non-deterministic by design")
        // Both signatures must still verify against the same public key.
        let key = try P256.Signing.PublicKey(derRepresentation: a.publicKeySPKI)
        let sigA = try P256.Signing.ECDSASignature(derRepresentation: a.signature)
        let sigB = try P256.Signing.ECDSASignature(derRepresentation: b.signature)
        #expect(key.isValidSignature(sigA, for: a.fingerprintHash))
        #expect(key.isValidSignature(sigB, for: b.fingerprintHash))
    }
}

@Suite("SystemDeviceAttestationProvider")
struct SystemDeviceAttestationProviderTests {
    @Test
    func assemblesFullFingerprint() async throws {
        let deviceInfo = DeviceInfo(
            platform: "ios",
            model: "iPhone15,4",
            systemName: "iOS",
            osVersion: "17.4.1",
        )
        let identity = SoftwareIdentityStore()
        let provider = SystemDeviceAttestationProvider(
            identity: identity,
            bundle: Bundle.main,
            localeProvider: { Locale(identifier: "en_US") },
            timezoneProvider: { TimeZone(identifier: "America/Denver")! },
            deviceInfo: deviceInfo,
        )
        let fingerprint = try await provider.currentFingerprint()
        #expect(fingerprint.platform == "ios")
        #expect(fingerprint.model == "iPhone15,4")
        #expect(fingerprint.systemName == "iOS")
        #expect(fingerprint.osVersion == "17.4.1")
        #expect(fingerprint.locale == "en_US")
        #expect(fingerprint.timezone == "America/Denver")
        #expect(fingerprint.installID == (try await identity.installID()))
    }

    @Test
    func twoCallsReturnSameInstallID() async throws {
        let deviceInfo = DeviceInfo(platform: "ios", model: "m", systemName: "s", osVersion: "v")
        let identity = SoftwareIdentityStore()
        let provider = SystemDeviceAttestationProvider(
            identity: identity,
            bundle: Bundle.main,
            localeProvider: { Locale(identifier: "en_US") },
            timezoneProvider: { TimeZone(identifier: "UTC")! },
            deviceInfo: deviceInfo,
        )
        let first = try await provider.currentFingerprint()
        let second = try await provider.currentFingerprint()
        #expect(first.installID == second.installID)
        #expect(!first.installID.isEmpty)
    }

    @Test
    func attestationHeaderMatchesDirectEncode() async throws {
        let deviceInfo = DeviceInfo(platform: "ios", model: "m", systemName: "s", osVersion: "v")
        let identity = SoftwareIdentityStore()
        let provider = SystemDeviceAttestationProvider(
            identity: identity,
            bundle: Bundle.main,
            localeProvider: { Locale(identifier: "en_US") },
            timezoneProvider: { TimeZone(identifier: "UTC")! },
            deviceInfo: deviceInfo,
        )
        let header = try await provider.currentAttestationHeader()
        let decoded = try DeviceAttestationEncoder.decodeHeaderValue(header)
        // The header's fph must equal sha256(canonical fingerprint) for the
        // same fingerprint the provider returned.
        let fingerprint = try await provider.currentFingerprint()
        let expectedHash = Data(SHA256.hash(data: try fingerprint.canonicalJSONBytes()))
        #expect(decoded.fingerprintHash == expectedHash)
        // And the pk must match the identity store's published pk.
        #expect(decoded.publicKeySPKI == (try await identity.publicKeySPKI()))
    }
}
