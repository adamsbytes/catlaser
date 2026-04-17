import Foundation
import Testing

@testable import CatLaserAuth

@Suite("TLSPin")
struct TLSPinTests {
    @Test
    func rejectsDigestOfWrongLength() throws {
        let tooShort = Data(repeating: 0xAB, count: 31)
        let tooLong = Data(repeating: 0xAB, count: 33)
        #expect(throws: TLSPin.InitError.wrongDigestLength(31)) {
            _ = try TLSPin(spkiSHA256: tooShort, label: "bad-short")
        }
        #expect(throws: TLSPin.InitError.wrongDigestLength(33)) {
            _ = try TLSPin(spkiSHA256: tooLong, label: "bad-long")
        }
    }

    @Test
    func rejectsEmptyLabel() throws {
        let digest = Data(repeating: 0xAB, count: 32)
        #expect(throws: TLSPin.InitError.emptyLabel) {
            _ = try TLSPin(spkiSHA256: digest, label: "")
        }
        #expect(throws: TLSPin.InitError.emptyLabel) {
            _ = try TLSPin(spkiSHA256: digest, label: "   ")
        }
    }

    @Test
    func acceptsValidInputs() throws {
        let digest = Data(repeating: 0xCD, count: 32)
        let pin = try TLSPin(spkiSHA256: digest, label: "prod-intermediate-2026")
        #expect(pin.spkiSHA256 == digest)
        #expect(pin.label == "prod-intermediate-2026")
    }
}

@Suite("TLSPinning")
struct TLSPinningTests {
    private func makePin(byte: UInt8, label: String) throws -> TLSPin {
        try TLSPin(spkiSHA256: Data(repeating: byte, count: 32), label: label)
    }

    @Test
    func rejectsEmptyPinList() throws {
        #expect(throws: TLSPinning.InitError.noPins) {
            _ = try TLSPinning(pins: [])
        }
    }

    @Test
    func matchesExactHashInSingletonPinSet() throws {
        let pin = try makePin(byte: 0x11, label: "p")
        let pinning = try TLSPinning(pins: [pin])
        #expect(pinning.matches(spkiHash: Data(repeating: 0x11, count: 32)))
    }

    @Test
    func matchesAnyPinInMultiPinSet() throws {
        let a = try makePin(byte: 0x01, label: "primary")
        let b = try makePin(byte: 0x02, label: "backup")
        let pinning = try TLSPinning(pins: [a, b])
        #expect(pinning.matches(spkiHash: Data(repeating: 0x01, count: 32)))
        #expect(pinning.matches(spkiHash: Data(repeating: 0x02, count: 32)))
    }

    @Test
    func rejectsNonMatchingHash() throws {
        let pin = try makePin(byte: 0xAA, label: "only")
        let pinning = try TLSPinning(pins: [pin])
        #expect(pinning.matches(spkiHash: Data(repeating: 0xBB, count: 32)) == false)
    }

    @Test
    func rejectsHashOfWrongLength() throws {
        let pin = try makePin(byte: 0xAA, label: "only")
        let pinning = try TLSPinning(pins: [pin])
        #expect(pinning.matches(spkiHash: Data(repeating: 0xAA, count: 31)) == false)
        #expect(pinning.matches(spkiHash: Data(repeating: 0xAA, count: 33)) == false)
        #expect(pinning.matches(spkiHash: Data()) == false)
    }

    @Test
    func matchesHashAtDifferentDataStartIndex() throws {
        // `Data` slices retain the parent's buffer and present a non-zero
        // startIndex. The constant-time comparison must index correctly
        // against that.
        let pin = try makePin(byte: 0x42, label: "p")
        let pinning = try TLSPinning(pins: [pin])
        var buffer = Data(repeating: 0x00, count: 64)
        for index in 32 ..< 64 {
            buffer[index] = 0x42
        }
        let suffix = buffer.suffix(from: 32)
        #expect(suffix.count == 32)
        #expect(suffix.startIndex != 0, "test precondition: expected a non-zero-start slice")
        #expect(pinning.matches(spkiHash: suffix))
    }

    @Test
    func differentHashesWithSingleByteDeltaStillRejected() throws {
        // Single-byte difference must reject — no silent "close enough" logic.
        var a = Data(repeating: 0xAA, count: 32)
        let pin = try TLSPin(spkiSHA256: a, label: "exact")
        let pinning = try TLSPinning(pins: [pin])
        a[31] = 0xAB
        #expect(pinning.matches(spkiHash: a) == false)
        a[31] = 0xAA
        a[0] = 0xAB
        #expect(pinning.matches(spkiHash: a) == false)
    }
}

#if canImport(Security) && canImport(Darwin)
import Security

/// Reference certificates generated offline with `openssl`. Each `der` is
/// the DER-encoded X.509 certificate bytes; each `expectedSPKISHA256` is
/// the SHA-256 of the DER-encoded `SubjectPublicKeyInfo`, computed via
///
///     openssl x509 -in cert.pem -pubkey -noout \
///       | openssl pkey -pubin -outform DER \
///       | openssl dgst -sha256 -binary | xxd -p
///
/// These values form the ground truth for `SPKIHasher`: if the hasher does
/// not produce exactly `expectedSPKISHA256`, a real production pin
/// computed with openssl (the documented procedure) will never match and
/// every TLS handshake will be rejected.
enum ReferenceCerts {
    static let ecP256Der: Data = Data(hex: """
        3082019130820137a00302010202141ac3fb61c384df5b15b25453ba1f4f756e\
        95b9e1300a06082a8648ce3d040302301e311c301a06035504030c136361746c\
        617365722d746573742d6563323536301e170d3236303431373035313434375a\
        170d3336303431343035313434375a301e311c301a06035504030c136361746c\
        617365722d746573742d65633235363059301306072a8648ce3d020106082a86\
        48ce3d0301070342000405c39771143931248f6471fd02fc8f77dc5dbdcd75ab\
        078b5ab70bca3c77ca9163bcc330288d97e2d3fe7774c732854345422e062cac\
        3c4b81fbbb36cc3f1c7da3533051301d0603551d0e041604142d44547781e8b0\
        9efbd3067231e77845dab5258c301f0603551d230418301680142d44547781e8\
        b09efbd3067231e77845dab5258c300f0603551d130101ff040530030101ff30\
        0a06082a8648ce3d040302034800304502210088ed7f5049021715f1aa63f9fc\
        88e780a55ee5f29f236d83ae89a21fa6f5d0f3022061dc213a84b8938cb482ef\
        8071bf3b1c5ed5f1132dba12dceacd22444e7539d9
        """)

    static let ecP256SPKISHA256: Data = Data(hex: """
        2e8b8c333da466353a98b5a18aa6014c8d74c849c91b73275d389be04ced83c3
        """)

    static let rsa2048Der: Data = Data(hex: """
        3082032130820209a003020102021471bea067d0c2971000224c3b8470992e08\
        1c155f300d06092a864886f70d01010b05003020311e301c06035504030c1563\
        61746c617365722d746573742d72736132303438301e170d3236303431373035\
        313530355a170d3336303431343035313530355a3020311e301c06035504030c\
        156361746c617365722d746573742d7273613230343830820122300d06092a86\
        4886f70d01010105000382010f003082010a0282010100f23e1435adc4199cd0\
        2e3f6d321e220cc99d3bd2356f6d1e02b13ce3a492494e9c5473e76f24186ec2\
        9247fe393e8d24ab5bf6da43062558d736c5484f2254dd8c51ac91b24b5f6a52\
        57cc70e7d4afcdd44e1ac2988c0db182140b54ffb1c036aae6106ab2be3e61c5\
        0be15f519ee876752d8dd8378d0f47dabc7ffb9354bb4f0bfa57cd6bcb4a6aef\
        0a2c19f598edb6ae049d018a37f2e26fe30cab8df39f8b54091c425c5d7f7458\
        978cb85fecd2e6c0f8a64f5b61a8c15a88e42a6bc83891072861e4f7dff94e04\
        fdda8e65beea9afd824d6f4459fcbdccb6e37691ca607a020bab5881c58d5122\
        fea7b9767cac2a800af059926146a98e7489aa3b3e509d0203010001a3533051\
        301d0603551d0e04160414934d71a675ab1bb9b400db369cc8732e28a673fa30\
        1f0603551d23041830168014934d71a675ab1bb9b400db369cc8732e28a673fa\
        300f0603551d130101ff040530030101ff300d06092a864886f70d01010b0500\
        03820101006118149654e536000988316fec1d2a54318339be24c9b09d2efcf6\
        d410c932a487a4f557f05e18ef5f1fe0b4ecaa6050dc8d7579b246bce5208e14\
        f6f213d5021cd28448650ccb7c4da0c2b942b91d4750c39e962fe02a5df5edd0\
        6572ee40cd90b835033a66f2da0369ec592ebd4057e49dcb821a612bfe4e17fc\
        e1c2d9dce11075ee763348fd1fdb65b78ca2f84ed16bdc1bd008b2037bb4d497\
        a4cc2bf65001e73bc97514daf265185abdeb348a8890a5c03bf5131bc864a16b\
        f24a38ade7975c33a29774263e985d95c99e360df3a56cc33e373ffaeaabc2b4\
        015b403925eef50d7386793a56ae9d20295246af8ac3f3a2abf83460db043571\
        f0ca4ad4f5
        """)

    static let rsa2048SPKISHA256: Data = Data(hex: """
        5a6a4df16f0d5b502f20d70d0d05ab27ed40539bbd214e1e072ed7a755f08752
        """)
}

@Suite("SPKIHasher")
struct SPKIHasherTests {
    @Test
    func computesKnownHashForECP256Certificate() throws {
        let cert = try #require(SecCertificateCreateWithData(nil, ReferenceCerts.ecP256Der as CFData))
        let computed = try SPKIHasher.sha256(of: cert)
        #expect(computed == ReferenceCerts.ecP256SPKISHA256, """
        SPKIHasher output does not match openssl's SPKI SHA-256 for the \
        reference EC P-256 certificate. Operators compute pins via openssl; \
        divergence here means no production pin will ever match.
        """)
    }

    @Test
    func computesKnownHashForRSA2048Certificate() throws {
        let cert = try #require(SecCertificateCreateWithData(nil, ReferenceCerts.rsa2048Der as CFData))
        let computed = try SPKIHasher.sha256(of: cert)
        #expect(computed == ReferenceCerts.rsa2048SPKISHA256, """
        SPKIHasher output does not match openssl's SPKI SHA-256 for the \
        reference RSA 2048 certificate. Operators compute pins via openssl; \
        divergence here means no production pin will ever match.
        """)
    }

    @Test
    func hashIsStableAcrossCalls() throws {
        let cert = try #require(SecCertificateCreateWithData(nil, ReferenceCerts.ecP256Der as CFData))
        let a = try SPKIHasher.sha256(of: cert)
        let b = try SPKIHasher.sha256(of: cert)
        #expect(a == b)
    }

    @Test
    func hashIsExactly32Bytes() throws {
        let cert = try #require(SecCertificateCreateWithData(nil, ReferenceCerts.ecP256Der as CFData))
        let hash = try SPKIHasher.sha256(of: cert)
        #expect(hash.count == 32)
    }

    @Test
    func differentCertsProduceDifferentHashes() throws {
        let ec = try #require(SecCertificateCreateWithData(nil, ReferenceCerts.ecP256Der as CFData))
        let rsa = try #require(SecCertificateCreateWithData(nil, ReferenceCerts.rsa2048Der as CFData))
        let ecHash = try SPKIHasher.sha256(of: ec)
        let rsaHash = try SPKIHasher.sha256(of: rsa)
        #expect(ecHash != rsaHash)
    }
}

@Suite("PinnedSessionDelegate")
struct PinnedSessionDelegateTests {
    /// Construct a SecTrust that anchors the given self-signed test certs.
    /// Uses the basic X.509 policy (no hostname matching) so tests don't
    /// depend on SAN presence in the reference certs — the pinning branch
    /// is what we're exercising, not SSL hostname policy.
    private func makeTrust(certificates: [SecCertificate]) throws -> SecTrust {
        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust)
        guard status == errSecSuccess, let trust else {
            struct TrustCreationFailed: Error {}
            throw TrustCreationFailed()
        }
        SecTrustSetAnchorCertificates(trust, certificates as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return trust
    }

    @Test
    func acceptsWhenAnyCertMatchesPin() throws {
        let cert = try #require(SecCertificateCreateWithData(nil, ReferenceCerts.ecP256Der as CFData))
        let pin = try TLSPin(spkiSHA256: ReferenceCerts.ecP256SPKISHA256, label: "ec-leaf")
        let pinning = try TLSPinning(pins: [pin])
        let delegate = PinnedSessionDelegate(pinning: pinning)
        let trust = try makeTrust(certificates: [cert])
        let decision = delegate.evaluate(trust: trust, host: "host.example")
        #expect(decision == .accept)
    }

    @Test
    func rejectsWhenNoCertMatchesPin() throws {
        let ec = try #require(SecCertificateCreateWithData(nil, ReferenceCerts.ecP256Der as CFData))
        let otherPin = try TLSPin(
            spkiSHA256: Data(repeating: 0xFF, count: 32),
            label: "unrelated",
        )
        let pinning = try TLSPinning(pins: [otherPin])
        let delegate = PinnedSessionDelegate(pinning: pinning)
        let trust = try makeTrust(certificates: [ec])
        let decision = delegate.evaluate(trust: trust, host: "host.example")
        guard case let .reject(reason) = decision else {
            Issue.record("expected .reject")
            return
        }
        #expect(reason.contains("host.example"))
        #expect(reason.lowercased().contains("no pinned"))
    }

    @Test
    func acceptsWhenAnyOfMultiplePinsMatches() throws {
        let ec = try #require(SecCertificateCreateWithData(nil, ReferenceCerts.ecP256Der as CFData))
        let backup = try TLSPin(
            spkiSHA256: Data(repeating: 0xAA, count: 32),
            label: "offline-backup",
        )
        let primary = try TLSPin(
            spkiSHA256: ReferenceCerts.ecP256SPKISHA256,
            label: "primary",
        )
        let pinning = try TLSPinning(pins: [primary, backup])
        let delegate = PinnedSessionDelegate(pinning: pinning)
        let trust = try makeTrust(certificates: [ec])
        #expect(delegate.evaluate(trust: trust, host: "h") == .accept)
    }

    @Test
    func rejectsWhenSystemTrustEvaluationFails() throws {
        // System trust must be evaluated before pinning — pinning never
        // loosens trust. Construct a SecTrust with NO anchors: the
        // self-signed cert is not in the system CA store, so trust
        // evaluation fails. The delegate must reject before even
        // consulting the pins.
        let ec = try #require(SecCertificateCreateWithData(nil, ReferenceCerts.ecP256Der as CFData))
        let pin = try TLSPin(spkiSHA256: ReferenceCerts.ecP256SPKISHA256, label: "ec")
        let pinning = try TLSPinning(pins: [pin])
        let delegate = PinnedSessionDelegate(pinning: pinning)

        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates([ec] as CFArray, policy, &trust)
        try #require(status == errSecSuccess)
        // Explicitly empty anchor set: allow nothing from the system store either.
        SecTrustSetAnchorCertificates(trust!, [] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust!, true)

        let decision = delegate.evaluate(trust: trust!, host: "h")
        guard case let .reject(reason) = decision else {
            Issue.record("expected .reject, even though the pin would have matched")
            return
        }
        #expect(reason.lowercased().contains("system trust rejection"))
    }

    @Test
    func acceptsWhenChainHasMultipleCertsAndNonLeafMatches() throws {
        // Pin targets the RSA cert (as if it were the intermediate);
        // the EC cert is the leaf that was anchored for system trust.
        // Pinning iterates every cert offered by the chain looking for a
        // match, so the chain is accepted even though the leaf itself
        // doesn't match a pin.
        let ec = try #require(SecCertificateCreateWithData(nil, ReferenceCerts.ecP256Der as CFData))
        let rsa = try #require(SecCertificateCreateWithData(nil, ReferenceCerts.rsa2048Der as CFData))
        let pinOnRSA = try TLSPin(spkiSHA256: ReferenceCerts.rsa2048SPKISHA256, label: "rsa-middle")
        let pinning = try TLSPinning(pins: [pinOnRSA])
        let delegate = PinnedSessionDelegate(pinning: pinning)

        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates([ec, rsa] as CFArray, policy, &trust)
        try #require(status == errSecSuccess)
        // Anchor both so system trust passes; pinning then decides.
        SecTrustSetAnchorCertificates(trust!, [ec, rsa] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust!, true)

        let decision = delegate.evaluate(trust: trust!, host: "h")
        #expect(decision == .accept)
    }
}

#endif

// MARK: - Helpers

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var high: UInt8?
        for scalar in hex.unicodeScalars {
            let nibble: UInt8?
            switch scalar {
            case "0" ... "9": nibble = UInt8(scalar.value - 0x30)
            case "a" ... "f": nibble = UInt8(scalar.value - 0x61 + 10)
            case "A" ... "F": nibble = UInt8(scalar.value - 0x41 + 10)
            case " ", "\n", "\r", "\t": nibble = nil
            default: nibble = nil
            }
            guard let nibble else { continue }
            if let h = high {
                bytes.append((h << 4) | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        self = Data(bytes)
    }
}
