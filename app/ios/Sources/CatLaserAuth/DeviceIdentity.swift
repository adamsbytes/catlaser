import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Per-install device identity backed by a hardware-protected P-256 key.
///
/// Implementations hold a non-extractable ECDSA private key (Secure Enclave
/// in production, software fallback for tests and non-Darwin CI). The store
/// publishes:
///
/// * `installID`: a stable, URL-safe base64 of SHA-256 over the DER-encoded
///   `SubjectPublicKeyInfo` of the public key. Deterministic for the life
///   of the key.
/// * `publicKeySPKI`: the 91-byte DER-encoded `SubjectPublicKeyInfo` that
///   the server uses to verify signatures.
/// * `sign(_:)`: ECDSA-P256-SHA256 signature over the given message bytes.
///   Non-deterministic by design — every call produces a fresh signature.
///
/// All operations are atomic across concurrent callers. The underlying key
/// is generated lazily on first use with add-only semantics: if two
/// processes race, the first to commit wins and both observers return the
/// same public key.
public protocol DeviceIdentityStoring: Sendable {
    /// Stable per-install identifier derived from the public key. URL-safe
    /// base64, no padding. Identical to the server-recomputable value
    /// `base64url(sha256(publicKeySPKI))`.
    func installID() async throws -> String

    /// DER-encoded `SubjectPublicKeyInfo` for the identity's public key.
    /// 91 bytes for P-256 (26-byte SPKI prefix + 65-byte X9.63 point).
    func publicKeySPKI() async throws -> Data

    /// ECDSA-P256-SHA256 signature over `message`. Returned in DER format,
    /// matching `SecKeyCreateSignature(..., .ecdsaSignatureMessageX962SHA256, ...)`
    /// and `P256.Signing.ECDSASignature.derRepresentation`.
    func sign(_ message: Data) async throws -> Data

    /// Discard the persisted key. Next access regenerates. Intended for
    /// hard-reset flows (e.g. "forget this device"); do NOT call on
    /// ordinary sign-out — the identity outlives sessions by design.
    func reset() async throws
}

public enum DeviceIdentity {
    /// Compute the install ID from an SPKI. Public so the server plugin's
    /// Swift port can reuse it.
    public static func installID(fromSPKI spki: Data) -> String {
        let digest = Data(SHA256.hash(data: spki))
        return base64URLNoPad(digest)
    }

    /// DER-encoded `SubjectPublicKeyInfo` prefix for an EC P-256 public
    /// key. 26 bytes. Concatenate with the 65-byte X9.63 public-point
    /// representation (`0x04 || X || Y`) to form the full 91-byte SPKI.
    ///
    /// Identical bytes to what `openssl ec -pubout -outform DER` emits for
    /// a P-256 key. Matched against RFC 5480 §2.1.1.1.
    public static let ecP256SPKIPrefix: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86,
        0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
        0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
        0x42, 0x00,
    ]

    /// Construct the 91-byte DER SPKI from a 65-byte uncompressed X9.63
    /// point (`0x04 || X || Y`). Throws if the point is the wrong length.
    public static func spki(fromX963 point: Data) throws(AuthError) -> Data {
        guard point.count == 65, point.first == 0x04 else {
            throw .attestationFailed("expected 65-byte uncompressed X9.63 point, got \(point.count) bytes")
        }
        var spki = Data(capacity: ecP256SPKIPrefix.count + point.count)
        spki.append(contentsOf: ecP256SPKIPrefix)
        spki.append(point)
        return spki
    }

    static func base64URLNoPad(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
