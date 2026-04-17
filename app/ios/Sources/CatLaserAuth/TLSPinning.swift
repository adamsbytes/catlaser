import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Security)
import Security
#endif

/// A single SPKI-SHA256 pin.
///
/// `spkiSHA256` is the SHA-256 digest of the DER-encoded
/// `SubjectPublicKeyInfo` structure (RFC 7469 "Public Key Pinning for HTTP").
/// Operators compute pins from a PEM cert with:
///
///     openssl x509 -in cert.pem -pubkey -noout \
///       | openssl pkey -pubin -outform der \
///       | openssl dgst -sha256 -binary \
///       | xxd -p -c 64
///
/// The 32-byte digest is what gets pinned. `label` is a human tag (e.g.
/// `"intermediate-2026"`) used in diagnostics when a connection is
/// rejected.
public struct TLSPin: Sendable, Equatable {
    public let spkiSHA256: Data
    public let label: String

    public enum InitError: Error, Equatable, Sendable {
        case wrongDigestLength(Int)
        case emptyLabel
    }

    public init(spkiSHA256: Data, label: String) throws(InitError) {
        guard spkiSHA256.count == 32 else {
            throw .wrongDigestLength(spkiSHA256.count)
        }
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .emptyLabel
        }
        self.spkiSHA256 = spkiSHA256
        self.label = label
    }
}

/// A non-empty set of pins that any presented certificate chain must match.
///
/// Verification rule: a chain is accepted if *at least one* certificate in
/// the chain has a SubjectPublicKeyInfo whose SHA-256 appears in `pins`. In
/// practice pins target an intermediate CA (to survive leaf rotation) with
/// one or more backup pins that you keep offline for disaster recovery.
public struct TLSPinning: Sendable, Equatable {
    public let pins: [TLSPin]

    public enum InitError: Error, Equatable, Sendable {
        case noPins
    }

    public init(pins: [TLSPin]) throws(InitError) {
        guard !pins.isEmpty else {
            throw .noPins
        }
        self.pins = pins
    }

    /// True if `hash` (a 32-byte SHA-256 digest) matches any pin.
    public func matches(spkiHash hash: Data) -> Bool {
        guard hash.count == 32 else { return false }
        return pins.contains { Self.constantTimeEquals($0.spkiSHA256, hash) }
    }

    /// Constant-time equality — protects against adversaries that can time
    /// pin comparisons through (e.g.) induced TLS handshake delays.
    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for index in 0 ..< lhs.count {
            diff |= lhs[lhs.startIndex + index] ^ rhs[rhs.startIndex + index]
        }
        return diff == 0
    }
}

#if canImport(Security)

/// Extract the SHA-256 of the DER-encoded `SubjectPublicKeyInfo` from a
/// certificate.
///
/// Apple's `SecKeyCopyExternalRepresentation` returns raw key material
/// (RSA `SEQUENCE { modulus, exponent }`, or EC `0x04 || X || Y`), not the
/// wrapping `SubjectPublicKeyInfo` that RFC 7469 hashes over. We prepend
/// the ASN.1 header that describes the key algorithm + size, which gives
/// us the same byte sequence that `openssl pkey -pubin -outform der`
/// emits, and hash that.
public enum SPKIHasher {
    public enum Failure: Error, Equatable, Sendable {
        case copyPublicKey
        case externalRepresentation(String)
        case missingAttributes
        case unsupportedKeyType(String)
        case unsupportedKeySize(type: String, bits: Int)
    }

    public static func sha256(of certificate: SecCertificate) throws(Failure) -> Data {
        guard let publicKey = SecCertificateCopyKey(certificate) else {
            throw .copyPublicKey
        }
        var cfError: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(publicKey, &cfError) as Data? else {
            let message = cfError.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "unknown"
            throw .externalRepresentation(message)
        }
        guard let attrs = SecKeyCopyAttributes(publicKey) as? [String: Any],
              let keyType = attrs[kSecAttrKeyType as String] as? String
        else {
            throw .missingAttributes
        }
        let keySize = (attrs[kSecAttrKeySizeInBits as String] as? Int) ?? 0
        let prefix = try prefixFor(keyType: keyType, keySize: keySize)

        var spki = Data(capacity: prefix.count + keyData.count)
        spki.append(contentsOf: prefix)
        spki.append(keyData)
        return Data(SHA256.hash(data: spki))
    }

    /// DER-encoded `SubjectPublicKeyInfo` prefix for the supported (key
    /// type, key size) combinations. These prefixes are the standard,
    /// algorithm-identifier-plus-BIT-STRING-header bytes defined by
    /// RFC 5480 (EC) and PKCS#1 / RFC 8017 (RSA). They are fixed for a
    /// given (type, size) — there is no variation to capture from the
    /// specific certificate.
    static func prefixFor(keyType: String, keySize: Int) throws(Failure) -> [UInt8] {
        if keyType == (kSecAttrKeyTypeRSA as String) {
            switch keySize {
            case 2048: return rsa2048Prefix
            case 3072: return rsa3072Prefix
            case 4096: return rsa4096Prefix
            default: throw .unsupportedKeySize(type: "RSA", bits: keySize)
            }
        }
        if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            switch keySize {
            case 256: return ecP256Prefix
            case 384: return ecP384Prefix
            case 521: return ecP521Prefix
            default: throw .unsupportedKeySize(type: "EC", bits: keySize)
            }
        }
        throw .unsupportedKeyType(keyType)
    }

    // MARK: - ASN.1 SubjectPublicKeyInfo prefixes
    //
    // Each prefix ends with the BIT STRING header (`03 ... 00`) that
    // immediately precedes the raw key material returned by
    // `SecKeyCopyExternalRepresentation`. Concatenating the prefix with
    // that raw material reconstructs a byte-for-byte match of the DER
    // `SubjectPublicKeyInfo` emitted by `openssl pkey -pubin -outform der`.

    private static let rsa2048Prefix: [UInt8] = [
        0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09,
        0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01,
        0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00,
    ]
    private static let rsa3072Prefix: [UInt8] = [
        0x30, 0x82, 0x01, 0xa2, 0x30, 0x0d, 0x06, 0x09,
        0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01,
        0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x8f, 0x00,
    ]
    private static let rsa4096Prefix: [UInt8] = [
        0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09,
        0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01,
        0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0f, 0x00,
    ]
    private static let ecP256Prefix: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86,
        0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
        0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
        0x42, 0x00,
    ]
    private static let ecP384Prefix: [UInt8] = [
        0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86,
        0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x05, 0x2b,
        0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00,
    ]
    private static let ecP521Prefix: [UInt8] = [
        0x30, 0x81, 0x9b, 0x30, 0x10, 0x06, 0x07, 0x2a,
        0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x05,
        0x2b, 0x81, 0x04, 0x00, 0x23, 0x03, 0x81, 0x86,
        0x00,
    ]
}

#endif
