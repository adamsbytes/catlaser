import CatLaserAuthTestSupport
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
        {"bundleID":"com.catlaser.app","installID":"01234567-89AB-CDEF-0123-456789ABCDEF","model":"iPhone15,4","platform":"ios","systemName":"iOS"}
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

    @Test
    func canonicalJSONExcludesVolatileFields() throws {
        // Regression guard: keep `osVersion`, `appVersion`, `appBuild`,
        // `locale`, and `timezone` OUT of the canonical bytes. These
        // drift on OS updates, TestFlight promotions, region changes,
        // and time-zone crossings; hashing them in would produce
        // spurious DEVICE_MISMATCH rejects for legitimate users whose
        // device metadata shifted during the 5-minute magic-link window.
        let bytes = try makeFingerprint().canonicalJSONBytes()
        let json = try #require(String(data: bytes, encoding: .utf8))
        for forbidden in ["osVersion", "appVersion", "appBuild", "locale", "timezone"] {
            #expect(
                !json.contains("\"\(forbidden)\":"),
                "canonical JSON must not carry '\(forbidden)' — it is volatile and would trigger false DEVICE_MISMATCH. Got: \(json)",
            )
        }
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
    func socialRendersTaggedTimestampAndRawNonce() {
        #expect(
            AttestationBinding.social(timestamp: 1_700_000_000, rawNonce: "raw-nonce-abc").wireValue
                == "sis:1700000000:raw-nonce-abc",
        )
        #expect(
            AttestationBinding.social(timestamp: 1, rawNonce: "n").wireValue == "sis:1:n",
        )
    }

    @Test
    func signOutRendersTaggedUnixSeconds() {
        #expect(AttestationBinding.signOut(timestamp: 1_700_000_000).wireValue == "out:1700000000")
        #expect(AttestationBinding.signOut(timestamp: 1).wireValue == "out:1")
    }

    @Test
    func apiRendersTaggedUnixSeconds() {
        #expect(AttestationBinding.api(timestamp: 1_700_000_000).wireValue == "api:1700000000")
        #expect(AttestationBinding.api(timestamp: 1).wireValue == "api:1")
    }

    @Test
    func wireBytesIsUtf8OfWireValue() {
        let binding = AttestationBinding.verify(token: "abc")
        #expect(binding.wireBytes == Data("ver:abc".utf8))
        let social = AttestationBinding.social(timestamp: 42, rawNonce: "xyz")
        #expect(social.wireBytes == Data("sis:42:xyz".utf8))
        let signOut = AttestationBinding.signOut(timestamp: 42)
        #expect(signOut.wireBytes == Data("out:42".utf8))
        let api = AttestationBinding.api(timestamp: 42)
        #expect(api.wireBytes == Data("api:42".utf8))
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
        let decoded = try AttestationBinding.decode(wireValue: "sis:1700000000:raw-nonce-abc")
        #expect(decoded == .social(timestamp: 1_700_000_000, rawNonce: "raw-nonce-abc"))
    }

    @Test
    func decodeRoundTripsSignOut() throws {
        let decoded = try AttestationBinding.decode(wireValue: "out:1700000000")
        #expect(decoded == .signOut(timestamp: 1_700_000_000))
    }

    @Test
    func decodeRoundTripsApi() throws {
        let decoded = try AttestationBinding.decode(wireValue: "api:1700000000")
        #expect(decoded == .api(timestamp: 1_700_000_000))
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
    func decodeRejectsNonNumericSignOutTimestamp() {
        expectDecodeFailure("out:notanumber", matching: "timestamp")
        expectDecodeFailure("out:", matching: "timestamp")
        expectDecodeFailure("out:-5", matching: "timestamp")
        expectDecodeFailure("out:012345", matching: "timestamp")
        expectDecodeFailure("out:1.5", matching: "timestamp")
        expectDecodeFailure("out:0", matching: "timestamp")
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
        // Timestamp present, nonce empty.
        expectDecodeFailure("sis:1700000000:", matching: "empty")
    }

    @Test
    func decodeRejectsSocialWithoutTimestampSuffix() {
        // A client that omits the `:<rawNonce>` half leaves no separator
        // after the tag payload. The decoder must surface this as a
        // timestamp-shape failure so a forgotten-timestamp client bug
        // doesn't silently fall through.
        expectDecodeFailure("sis:raw-nonce-abc", matching: "sis:")
    }

    @Test
    func decodeRejectsSocialWithEmptyTimestamp() {
        expectDecodeFailure("sis::raw-nonce-abc", matching: "timestamp")
    }

    @Test
    func decodeRejectsSocialWithLeadingZeroTimestamp() {
        expectDecodeFailure("sis:01:raw-nonce-abc", matching: "timestamp")
    }

    @Test
    func decodeRejectsSocialWithNonNumericTimestamp() {
        expectDecodeFailure("sis:notanumber:raw-nonce-abc", matching: "timestamp")
    }

    @Test
    func decodeRejectsSocialWithZeroTimestamp() {
        expectDecodeFailure("sis:0:raw-nonce-abc", matching: "timestamp")
    }

    @Test
    func decodeRejectsSocialWithNegativeTimestamp() {
        expectDecodeFailure("sis:-1:raw-nonce-abc", matching: "timestamp")
    }

    @Test
    func decodeRejectsControlCharsInSocialNonce() {
        expectDecodeFailure("sis:1700000000:abc\ndef", matching: "control")
        expectDecodeFailure("sis:1700000000:abc def", matching: "control")
    }

    @Test
    func decodeRejectsNonNumericApiTimestamp() {
        expectDecodeFailure("api:notanumber", matching: "timestamp")
        expectDecodeFailure("api:", matching: "timestamp")
        expectDecodeFailure("api:-5", matching: "timestamp")
        expectDecodeFailure("api:012345", matching: "timestamp")
        expectDecodeFailure("api:1.5", matching: "timestamp")
        expectDecodeFailure("api:0", matching: "timestamp")
    }

    @Test
    func decodeRejectsOversizedInput() {
        let big = String(repeating: "a", count: AttestationBinding.maxWireBytes + 1)
        expectDecodeFailure("ver:\(big)", matching: "exceeds")
        // Shape is `sis:<ts>:<nonce>` — overflow the nonce half so the
        // total wire value exceeds the cap.
        expectDecodeFailure("sis:1:\(big)", matching: "exceeds")
    }

    @Test
    func signedBytesDifferAcrossBindings() async throws {
        // Attestations built from the same fingerprint + SE key but
        // with different bindings must produce different signed bytes.
        // This is the crux of the replay defence — for every pair of
        // distinct binding tags, a signature for one must NOT verify
        // against the other's signed bytes. Critically, `req:<ts>`,
        // `sis:<ts>:<nonce>`, `out:<ts>`, and `api:<ts>` all carry a
        // timestamp in their wire value — the tag alone must separate
        // them, so a captured magic-link-request header cannot be
        // replayed against the sign-out endpoint / api route, and a
        // captured social header cannot be replayed against the
        // protected route (and vice versa for every pair).
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
            // Same numeric timestamp as `reqAttestation` — the tag +
            // nonce field must separate the signed bytes.
            binding: .social(timestamp: 1_700_000_000, rawNonce: "n"),
        )
        let outAttestation = try await DeviceAttestationBuilder.build(
            fingerprint: fingerprint,
            identity: identity,
            // Same numeric timestamp as `reqAttestation` — the tag alone
            // must separate the signed bytes.
            binding: .signOut(timestamp: 1_700_000_000),
        )
        let apiAttestation = try await DeviceAttestationBuilder.build(
            fingerprint: fingerprint,
            identity: identity,
            binding: .api(timestamp: 1_700_000_000),
        )
        let reqSigned = reqAttestation.fingerprintHash + reqAttestation.binding.wireBytes
        let verSigned = verAttestation.fingerprintHash + verAttestation.binding.wireBytes
        let sisSigned = sisAttestation.fingerprintHash + sisAttestation.binding.wireBytes
        let outSigned = outAttestation.fingerprintHash + outAttestation.binding.wireBytes
        let apiSigned = apiAttestation.fingerprintHash + apiAttestation.binding.wireBytes
        let allSigned: [(String, Data)] = [
            ("request", reqSigned),
            ("verify", verSigned),
            ("social", sisSigned),
            ("signOut", outSigned),
            ("api", apiSigned),
        ]
        for outer in allSigned.indices {
            for inner in allSigned.indices where inner != outer {
                let lhs = allSigned[outer]
                let rhs = allSigned[inner]
                #expect(
                    lhs.1 != rhs.1,
                    "\(lhs.0) and \(rhs.0) bindings must produce distinct signed bytes even at identical timestamps",
                )
            }
        }

        // Every pair of distinct-context signatures must fail to
        // verify against another context's signed bytes.
        let key = try P256.Signing.PublicKey(derRepresentation: reqAttestation.publicKeySPKI)
        let signaturesByContext: [(String, P256.Signing.ECDSASignature)] = [
            ("request", try P256.Signing.ECDSASignature(derRepresentation: reqAttestation.signature)),
            ("verify", try P256.Signing.ECDSASignature(derRepresentation: verAttestation.signature)),
            ("social", try P256.Signing.ECDSASignature(derRepresentation: sisAttestation.signature)),
            ("signOut", try P256.Signing.ECDSASignature(derRepresentation: outAttestation.signature)),
            ("api", try P256.Signing.ECDSASignature(derRepresentation: apiAttestation.signature)),
        ]
        for sigEntry in signaturesByContext {
            for msgEntry in allSigned where msgEntry.0 != sigEntry.0 {
                #expect(
                    !key.isValidSignature(sigEntry.1, for: msgEntry.1),
                    "\(sigEntry.0) signature must not verify against \(msgEntry.0) signed bytes",
                )
            }
        }
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
        let attestation = sample(
            binding: .social(timestamp: 1_700_000_000, rawNonce: "raw-nonce-xyz"),
        )
        let encoded = try DeviceAttestationEncoder.encodeHeaderValue(attestation)
        let decoded = try DeviceAttestationEncoder.decodeHeaderValue(encoded)
        #expect(decoded == attestation)
        #expect(decoded.binding == .social(timestamp: 1_700_000_000, rawNonce: "raw-nonce-xyz"))
    }

    @Test
    func roundTripsSignOutBinding() throws {
        let attestation = sample(binding: .signOut(timestamp: 1_700_000_000))
        let encoded = try DeviceAttestationEncoder.encodeHeaderValue(attestation)
        let decoded = try DeviceAttestationEncoder.decodeHeaderValue(encoded)
        #expect(decoded == attestation)
        #expect(decoded.binding == .signOut(timestamp: 1_700_000_000))
    }

    @Test
    func roundTripsApiBinding() throws {
        let attestation = sample(binding: .api(timestamp: 1_700_000_000))
        let encoded = try DeviceAttestationEncoder.encodeHeaderValue(attestation)
        let decoded = try DeviceAttestationEncoder.decodeHeaderValue(encoded)
        #expect(decoded == attestation)
        #expect(decoded.binding == .api(timestamp: 1_700_000_000))
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
        #expect(object["v"] as? Int == DeviceAttestation.currentVersion)
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
        let modified = DeviceFingerprint(
            platform: "ios",
            model: "iPhone1,1",
            systemName: "iOS",
            bundleID: "com.catlaser.app",
            installID: id,
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
    func assemblesStableFingerprint() async throws {
        let deviceInfo = DeviceInfo(
            platform: "ios",
            model: "iPhone15,4",
            systemName: "iOS",
        )
        let identity = SoftwareIdentityStore()
        let provider = SystemDeviceAttestationProvider(
            identity: identity,
            bundle: Bundle.main,
            deviceInfo: deviceInfo,
        )
        let fingerprint = try await provider.currentFingerprint()
        #expect(fingerprint.platform == "ios")
        #expect(fingerprint.model == "iPhone15,4")
        #expect(fingerprint.systemName == "iOS")
        #expect(fingerprint.installID == (try await identity.installID()))
    }

    @Test
    func twoCallsReturnSameInstallID() async throws {
        let deviceInfo = DeviceInfo(platform: "ios", model: "m", systemName: "s")
        let identity = SoftwareIdentityStore()
        let provider = SystemDeviceAttestationProvider(
            identity: identity,
            bundle: Bundle.main,
            deviceInfo: deviceInfo,
        )
        let first = try await provider.currentFingerprint()
        let second = try await provider.currentFingerprint()
        #expect(first.installID == second.installID)
        #expect(!first.installID.isEmpty)
    }

    @Test
    func attestationHeaderMatchesDirectEncode() async throws {
        let deviceInfo = DeviceInfo(platform: "ios", model: "m", systemName: "s")
        let identity = SoftwareIdentityStore()
        let provider = SystemDeviceAttestationProvider(
            identity: identity,
            bundle: Bundle.main,
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
