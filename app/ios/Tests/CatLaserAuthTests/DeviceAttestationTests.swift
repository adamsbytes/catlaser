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

@Suite("AttestationBinding")
struct AttestationBindingTests {
    @Test
    func requestRendersTaggedUnixSeconds() {
        #expect(AttestationBinding.request(timestamp: 1_700_000_000).wireValue == "req:1700000000")
        #expect(AttestationBinding.request(timestamp: 1).wireValue == "req:1")
    }

    @Test
    func verifyRendersTaggedToken() {
        #expect(AttestationBinding.verify(token: "abc.def").wireValue == "ver:abc.def")
    }

    @Test
    func socialRendersTaggedRawNonce() {
        #expect(AttestationBinding.social(rawNonce: "raw-nonce-abc").wireValue == "sis:raw-nonce-abc")
    }

    @Test
    func wireBytesIsUtf8OfWireValue() {
        let binding = AttestationBinding.verify(token: "abc")
        #expect(binding.wireBytes == Data("ver:abc".utf8))
        let social = AttestationBinding.social(rawNonce: "xyz")
        #expect(social.wireBytes == Data("sis:xyz".utf8))
    }

    @Test
    func decodeRoundTripsRequest() throws {
        let decoded = try AttestationBinding.decode(wireValue: "req:1700000000")
        #expect(decoded == .request(timestamp: 1_700_000_000))
    }

    @Test
    func decodeRoundTripsVerify() throws {
        let decoded = try AttestationBinding.decode(wireValue: "ver:abc.def")
        #expect(decoded == .verify(token: "abc.def"))
    }

    @Test
    func decodeRoundTripsSocial() throws {
        let decoded = try AttestationBinding.decode(wireValue: "sis:raw-nonce-abc")
        #expect(decoded == .social(rawNonce: "raw-nonce-abc"))
    }

    @Test
    func decodeRejectsUnknownTag() {
        expectDecodeFailure("xyz:anything", matching: "tag")
    }

    @Test
    func decodeRejectsMissingTag() {
        expectDecodeFailure("1700000000", matching: "tag")
    }

    @Test
    func decodeRejectsEmptyInput() {
        expectDecodeFailure("", matching: "tag")
    }

    @Test
    func decodeRejectsNonNumericTimestamp() {
        expectDecodeFailure("req:notanumber", matching: "timestamp")
        expectDecodeFailure("req:", matching: "timestamp")
        expectDecodeFailure("req:-5", matching: "timestamp")
        expectDecodeFailure("req:012345", matching: "timestamp") // leading zero
        expectDecodeFailure("req:1.5", matching: "timestamp")
    }

    @Test
    func decodeRejectsZeroTimestamp() {
        // Zero implies a broken / unset clock; treat as invalid.
        expectDecodeFailure("req:0", matching: "timestamp")
    }

    @Test
    func decodeRejectsEmptyVerifyToken() {
        expectDecodeFailure("ver:", matching: "empty")
    }

    @Test
    func decodeRejectsControlCharsInVerifyToken() {
        expectDecodeFailure("ver:abc\ndef", matching: "control")
        expectDecodeFailure("ver:abc def", matching: "control")
    }

    @Test
    func decodeRejectsEmptySocialNonce() {
        expectDecodeFailure("sis:", matching: "empty")
    }

    @Test
    func decodeRejectsControlCharsInSocialNonce() {
        expectDecodeFailure("sis:abc\ndef", matching: "control")
        expectDecodeFailure("sis:abc def", matching: "control")
    }

    @Test
    func decodeRejectsOversizedInput() {
        let big = String(repeating: "a", count: AttestationBinding.maxWireBytes + 1)
        expectDecodeFailure("ver:\(big)", matching: "exceeds")
        expectDecodeFailure("sis:\(big)", matching: "exceeds")
    }

    @Test
    func signedBytesDifferAcrossBindings() async throws {
        // Attestations built from the same fingerprint + SE key but
        // with different bindings must produce different signed bytes.
        // This is the crux of the replay defence — for every pair of
        // distinct binding tags, a signature for one must NOT verify
        // against the other's signed bytes.
        let identity = SoftwareIdentityStore()
        let fingerprint = makeFingerprint(installID: try await identity.installID())
        let reqAttestation = try await DeviceAttestationBuilder.build(
            fingerprint: fingerprint,
            identity: identity,
            binding: .request(timestamp: 1_700_000_000),
        )
        let verAttestation = try await DeviceAttestationBuilder.build(
            fingerprint: fingerprint,
            identity: identity,
            binding: .verify(token: "t"),
        )
        let sisAttestation = try await DeviceAttestationBuilder.build(
            fingerprint: fingerprint,
            identity: identity,
            binding: .social(rawNonce: "n"),
        )
        let reqSigned = reqAttestation.fingerprintHash + reqAttestation.binding.wireBytes
        let verSigned = verAttestation.fingerprintHash + verAttestation.binding.wireBytes
        let sisSigned = sisAttestation.fingerprintHash + sisAttestation.binding.wireBytes
        #expect(reqSigned != verSigned, "request and verify bindings must produce distinct signed bytes")
        #expect(reqSigned != sisSigned, "request and social bindings must produce distinct signed bytes")
        #expect(verSigned != sisSigned, "verify and social bindings must produce distinct signed bytes")

        // Every pair of distinct-context signatures must fail to
        // verify against another context's signed bytes.
        let key = try P256.Signing.PublicKey(derRepresentation: reqAttestation.publicKeySPKI)
        let reqSig = try P256.Signing.ECDSASignature(derRepresentation: reqAttestation.signature)
        let verSig = try P256.Signing.ECDSASignature(derRepresentation: verAttestation.signature)
        let sisSig = try P256.Signing.ECDSASignature(derRepresentation: sisAttestation.signature)
        #expect(!key.isValidSignature(reqSig, for: verSigned),
                "request-time signature must not verify against verify-time signed bytes")
        #expect(!key.isValidSignature(reqSig, for: sisSigned),
                "request-time signature must not verify against social-signed bytes")
        #expect(!key.isValidSignature(verSig, for: reqSigned),
                "verify-time signature must not verify against request-time signed bytes")
        #expect(!key.isValidSignature(verSig, for: sisSigned),
                "verify-time signature must not verify against social-signed bytes")
        #expect(!key.isValidSignature(sisSig, for: reqSigned),
                "social signature must not verify against request-time signed bytes")
        #expect(!key.isValidSignature(sisSig, for: verSigned),
                "social signature must not verify against verify-time signed bytes")
    }

    private func expectDecodeFailure(
        _ wire: String,
        matching contains: String,
        sourceLocation: SourceLocation = #_sourceLocation,
    ) {
        do {
            _ = try AttestationBinding.decode(wireValue: wire)
            Issue.record("expected attestationFailed for '\(wire)'", sourceLocation: sourceLocation)
        } catch let AuthError.attestationFailed(message) {
            #expect(
                message.lowercased().contains(contains.lowercased()),
                "message '\(message)' did not contain '\(contains)'",
                sourceLocation: sourceLocation,
            )
        } catch {
            Issue.record("unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }
}

@Suite("DeviceAttestationEncoder")
struct DeviceAttestationEncoderTests {
    private func sample(
        binding: AttestationBinding = .request(timestamp: 1_700_000_000),
    ) -> DeviceAttestation {
        let spki = Data(DeviceIdentity.ecP256SPKIPrefix + [UInt8](repeating: 0xCD, count: 65))
        return DeviceAttestation(
            fingerprintHash: Data(repeating: 0xAB, count: 32),
            publicKeySPKI: spki,
            binding: binding,
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
    func roundTripsVerifyBinding() throws {
        let attestation = sample(binding: .verify(token: "single-use-token"))
        let encoded = try DeviceAttestationEncoder.encodeHeaderValue(attestation)
        let decoded = try DeviceAttestationEncoder.decodeHeaderValue(encoded)
        #expect(decoded == attestation)
        #expect(decoded.binding == .verify(token: "single-use-token"))
    }

    @Test
    func roundTripsSocialBinding() throws {
        let attestation = sample(binding: .social(rawNonce: "raw-nonce-xyz"))
        let encoded = try DeviceAttestationEncoder.encodeHeaderValue(attestation)
        let decoded = try DeviceAttestationEncoder.decodeHeaderValue(encoded)
        #expect(decoded == attestation)
        #expect(decoded.binding == .social(rawNonce: "raw-nonce-xyz"))
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
    func encodedJSONContainsExactlyTheExpectedKeys() throws {
        // Keys-sorted output must carry exactly {bnd, fph, pk, sig, v}.
        // An extra key would be a silent protocol break with the server.
        let attestation = sample(binding: .request(timestamp: 1_700_000_000))
        let encoded = try DeviceAttestationEncoder.encodeHeaderValue(attestation)
        let outer = try #require(Data(base64Encoded: encoded))
        let object = try #require(try JSONSerialization.jsonObject(with: outer) as? [String: Any])
        #expect(Set(object.keys) == ["bnd", "fph", "pk", "sig", "v"])
        #expect(object["bnd"] as? String == "req:1700000000")
        #expect(object["v"] as? Int == 3)
    }

    @Test
    func decoderRecoversTaggedBinding() throws {
        let attestation = sample(binding: .verify(token: "tok-42"))
        let encoded = try DeviceAttestationEncoder.encodeHeaderValue(attestation)
        let decoded = try DeviceAttestationEncoder.decodeHeaderValue(encoded)
        #expect(decoded.binding == .verify(token: "tok-42"))
    }

    @Test
    func decoderRejectsUnknownTagInBnd() throws {
        // Build a payload that looks otherwise valid but has an unknown
        // bnd tag. The decoder must reject — server-port compatibility
        // depends on the tag vocabulary staying frozen.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload: [String: Any] = [
            "bnd": "xyz:weird",
            "fph": DeviceIdentity.base64URLNoPad(Data(repeating: 0xAB, count: 32)),
            "pk": Data(DeviceIdentity.ecP256SPKIPrefix + [UInt8](repeating: 0, count: 65)).base64EncodedString(),
            "sig": Data(repeating: 0x12, count: 70).base64EncodedString(),
            "v": 3,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys],
        )
        let header = data.base64EncodedString()
        do {
            _ = try DeviceAttestationEncoder.decodeHeaderValue(header)
            Issue.record("expected attestationFailed")
        } catch let AuthError.attestationFailed(message) {
            #expect(message.lowercased().contains("tag"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
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
            binding: .request(timestamp: 1),
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
            binding: .request(timestamp: 1),
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
            binding: .request(timestamp: 1),
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
    func rejectsOversizedBinding() {
        let big = String(repeating: "a", count: AttestationBinding.maxWireBytes + 1)
        let spki = Data(DeviceIdentity.ecP256SPKIPrefix + [UInt8](repeating: 0, count: 65))
        let bad = DeviceAttestation(
            fingerprintHash: Data(repeating: 0, count: 32),
            publicKeySPKI: spki,
            binding: .verify(token: big),
            signature: Data(repeating: 0x12, count: 70),
        )
        do {
            _ = try DeviceAttestationEncoder.encodeHeaderValue(bad)
            Issue.record("expected attestationFailed")
        } catch let AuthError.attestationFailed(msg) {
            #expect(msg.contains("bnd"))
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
        // wire must verify against the pk on the wire, over the
        // (fph_raw || bnd_utf8) message, under a standard P-256 ECDSA
        // implementation. If this doesn't hold, no server can
        // authenticate the client.
        let identity = SoftwareIdentityStore()
        let fingerprint = makeFingerprint(installID: try await identity.installID())
        let binding = AttestationBinding.request(timestamp: 1_700_000_000)
        let attestation = try await DeviceAttestationBuilder.build(
            fingerprint: fingerprint,
            identity: identity,
            binding: binding,
        )

        let expectedMessage = attestation.fingerprintHash + binding.wireBytes
        let key = try P256.Signing.PublicKey(derRepresentation: attestation.publicKeySPKI)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: attestation.signature)
        #expect(key.isValidSignature(signature, for: expectedMessage))
    }

    @Test
    func verifyBindingFlowsIntoSignedMessage() async throws {
        let identity = SoftwareIdentityStore()
        let fingerprint = makeFingerprint(installID: try await identity.installID())
        let binding = AttestationBinding.verify(token: "single-use-token")
        let attestation = try await DeviceAttestationBuilder.build(
            fingerprint: fingerprint,
            identity: identity,
            binding: binding,
        )
        let expectedMessage = attestation.fingerprintHash + binding.wireBytes
        let key = try P256.Signing.PublicKey(derRepresentation: attestation.publicKeySPKI)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: attestation.signature)
        #expect(key.isValidSignature(signature, for: expectedMessage))

        // Verifying against fph ALONE (the v2 format) must fail — this
        // is the property that prevents a v2-captured signature from
        // being submitted to a v3 endpoint.
        #expect(!key.isValidSignature(signature, for: attestation.fingerprintHash))
    }

    @Test
    func fphIsSha256OfCanonicalJSON() async throws {
        let identity = SoftwareIdentityStore()
        let fingerprint = makeFingerprint(installID: try await identity.installID())
        let attestation = try await DeviceAttestationBuilder.build(
            fingerprint: fingerprint,
            identity: identity,
            binding: .request(timestamp: 1),
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
            binding: .request(timestamp: 1),
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
        let b = try await DeviceAttestationBuilder.build(
            fingerprint: modified,
            identity: identity,
            binding: .request(timestamp: 1),
        )
        #expect(a.fingerprintHash != b.fingerprintHash, "changing the model byte must change fph")
    }

    @Test
    func signaturesFreshPerCallButPublicKeyStable() async throws {
        let identity = SoftwareIdentityStore()
        let fingerprint = makeFingerprint(installID: try await identity.installID())
        let binding = AttestationBinding.request(timestamp: 1_700_000_000)
        let a = try await DeviceAttestationBuilder.build(
            fingerprint: fingerprint,
            identity: identity,
            binding: binding,
        )
        let b = try await DeviceAttestationBuilder.build(
            fingerprint: fingerprint,
            identity: identity,
            binding: binding,
        )
        #expect(a.fingerprintHash == b.fingerprintHash)
        #expect(a.publicKeySPKI == b.publicKeySPKI)
        #expect(a.signature != b.signature, "ECDSA is non-deterministic by design")
        // Both signatures must still verify against the same public key
        // over the same signed message.
        let key = try P256.Signing.PublicKey(derRepresentation: a.publicKeySPKI)
        let expectedMessage = a.fingerprintHash + binding.wireBytes
        let sigA = try P256.Signing.ECDSASignature(derRepresentation: a.signature)
        let sigB = try P256.Signing.ECDSASignature(derRepresentation: b.signature)
        #expect(key.isValidSignature(sigA, for: expectedMessage))
        #expect(key.isValidSignature(sigB, for: expectedMessage))
    }

    @Test
    func changingOnlyTimestampStillChangesSignedMessage() async throws {
        // Two requests moments apart on the same device share fph and pk
        // but their signed messages differ, so server cannot tell one
        // capture from the next is a replay.
        let identity = SoftwareIdentityStore()
        let fingerprint = makeFingerprint(installID: try await identity.installID())
        let a = try await DeviceAttestationBuilder.build(
            fingerprint: fingerprint,
            identity: identity,
            binding: .request(timestamp: 1_700_000_000),
        )
        let b = try await DeviceAttestationBuilder.build(
            fingerprint: fingerprint,
            identity: identity,
            binding: .request(timestamp: 1_700_000_001),
        )
        #expect(a.fingerprintHash == b.fingerprintHash)
        #expect(a.publicKeySPKI == b.publicKeySPKI)
        #expect(a.binding != b.binding)

        let key = try P256.Signing.PublicKey(derRepresentation: a.publicKeySPKI)
        let sigA = try P256.Signing.ECDSASignature(derRepresentation: a.signature)
        let messageForB = b.fingerprintHash + b.binding.wireBytes
        #expect(!key.isValidSignature(sigA, for: messageForB),
                "a's signature must not verify against b's signed bytes — this is the replay defence")
    }

    @Test
    func rejectsOversizedBindingFromBuilder() async throws {
        let identity = SoftwareIdentityStore()
        let fingerprint = makeFingerprint(installID: try await identity.installID())
        let big = String(repeating: "a", count: AttestationBinding.maxWireBytes + 1)
        do {
            _ = try await DeviceAttestationBuilder.build(
                fingerprint: fingerprint,
                identity: identity,
                binding: .verify(token: big),
            )
            Issue.record("expected attestationFailed")
        } catch let AuthError.attestationFailed(msg) {
            #expect(msg.contains("bnd"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
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
        let binding = AttestationBinding.request(timestamp: 1_700_000_000)
        let header = try await provider.currentAttestationHeader(binding: binding)
        let decoded = try DeviceAttestationEncoder.decodeHeaderValue(header)
        // The header's fph must equal sha256(canonical fingerprint) for the
        // same fingerprint the provider returned.
        let fingerprint = try await provider.currentFingerprint()
        let expectedHash = Data(SHA256.hash(data: try fingerprint.canonicalJSONBytes()))
        #expect(decoded.fingerprintHash == expectedHash)
        // And the pk must match the identity store's published pk.
        #expect(decoded.publicKeySPKI == (try await identity.publicKeySPKI()))
        // And the binding round-trips byte-for-byte.
        #expect(decoded.binding == binding)
    }
}
