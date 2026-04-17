import Foundation
import Testing

@testable import CatLaserAuth

@Suite("Nonce")
struct NonceTests {
    @Test
    func rawIsURLSafeBase64WithoutPadding() throws {
        let generator = NonceGenerator()
        let nonce = try generator.make()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(nonce.raw.unicodeScalars.allSatisfy { allowed.contains($0) })
        #expect(!nonce.raw.contains("="))
        #expect(!nonce.raw.contains("+"))
        #expect(!nonce.raw.contains("/"))
        #expect(nonce.raw.isEmpty == false)
    }

    @Test
    func rawEncodesExpectedByteCount() throws {
        let fixed = [UInt8](repeating: 0xAB, count: NonceGenerator.rawLength)
        let generator = NonceGenerator(randomBytes: { count in
            #expect(count == NonceGenerator.rawLength)
            return fixed
        })
        let nonce = try generator.make()
        // 32 bytes base64 without padding = ceil(32*4/3) = 43 chars (last '=' stripped)
        #expect(nonce.raw.count == 43)
    }

    @Test
    func hashedIsLowercaseHex64Chars() throws {
        let generator = NonceGenerator()
        let nonce = try generator.make()
        #expect(nonce.hashed.count == 64)
        let hexSet = CharacterSet(charactersIn: "0123456789abcdef")
        #expect(nonce.hashed.unicodeScalars.allSatisfy { hexSet.contains($0) })
    }

    @Test
    func hashedIsSHA256OfRawBytes() throws {
        // "abc" -> SHA256 = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        let generator = NonceGenerator()
        let hex = generator.sha256Hex("abc")
        #expect(hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test
    func emptyStringSHA256() {
        let generator = NonceGenerator()
        let hex = generator.sha256Hex("")
        #expect(hex == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test
    func nonceIsDifferentEachInvocation() throws {
        let generator = NonceGenerator()
        var seen = Set<String>()
        for _ in 0 ..< 64 {
            let nonce = try generator.make()
            #expect(seen.insert(nonce.raw).inserted)
        }
    }

    @Test
    func urlSafeBase64FromBytes() {
        let generator = NonceGenerator()
        let bytes: [UInt8] = [0xFB, 0xFF, 0xBF, 0x00]
        // standard base64: "+/+/AA==", URL-safe: "-_-_AA"
        let encoded = generator.encodeURLSafeBase64(bytes)
        #expect(encoded == "-_-_AA")
    }

    @Test
    func urlSafeBase64Empty() {
        let generator = NonceGenerator()
        #expect(generator.encodeURLSafeBase64([]) == "")
    }

    @Test
    func randomBytesErrorPropagates() {
        struct RNGError: Error, Equatable {}
        let generator = NonceGenerator(randomBytes: { _ in throw RNGError() })
        #expect(throws: RNGError.self) {
            _ = try generator.make()
        }
    }

    @Test
    func fixedSeedProducesStableNonce() throws {
        let fixed = [UInt8](0 ..< 32)
        let generator = NonceGenerator(randomBytes: { _ in fixed })
        let nonce = try generator.make()
        #expect(nonce.raw == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        #expect(nonce.hashed.count == 64)
    }

    // MARK: - Platform CSPRNG (M2)

    @Test
    func systemRandomBytesReturnsRequestedLength() throws {
        let bytes = try NonceGenerator.systemRandomBytes(32)
        #expect(bytes.count == 32)
    }

    @Test
    func systemRandomBytesReturnsEmptyForZero() throws {
        let bytes = try NonceGenerator.systemRandomBytes(0)
        #expect(bytes.isEmpty)
    }

    @Test
    func systemRandomBytesDoesNotReturnAllZeros() throws {
        // 32 zero bytes has ~2^-256 probability from a CSPRNG. If this test
        // fails deterministically, the RNG is unseeded or broken, not unlucky.
        let bytes = try NonceGenerator.systemRandomBytes(32)
        #expect(bytes.contains { $0 != 0 }, "CSPRNG returned 32 zero bytes — RNG is broken")
    }

    @Test
    func systemRandomBytesDiffersAcrossCalls() throws {
        let a = try NonceGenerator.systemRandomBytes(32)
        let b = try NonceGenerator.systemRandomBytes(32)
        #expect(a != b, "two consecutive 32-byte draws from a CSPRNG collided — RNG is broken")
    }

    @Test
    func systemRandomBytesHasReasonableEntropy() throws {
        // A single 4096-byte draw from a CSPRNG should cover a large fraction
        // of the byte value space. Not a rigorous test — a real entropy test
        // would use dieharder — but catches an RNG that's stuck on a small
        // cycle or returning repeated patterns.
        let bytes = try NonceGenerator.systemRandomBytes(4096)
        let unique = Set(bytes)
        #expect(unique.count >= 200, "only \(unique.count) distinct byte values in 4096 draws — RNG is degenerate")
    }

    @Test
    func defaultInitUsesSystemRandomBytes() throws {
        // Two sequential `make()` calls on a default-initialized generator
        // must use the system CSPRNG, so they must not collide.
        let generator = NonceGenerator()
        let a = try generator.make()
        let b = try generator.make()
        #expect(a.raw != b.raw)
    }
}
