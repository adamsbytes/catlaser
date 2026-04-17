import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Security)
import Security
#endif

public struct NonceGenerator: Sendable {
    private let randomBytes: @Sendable (Int) throws -> [UInt8]

    public init() {
        self.init(randomBytes: NonceGenerator.systemRandomBytes)
    }

    init(randomBytes: @escaping @Sendable (Int) throws -> [UInt8]) {
        self.randomBytes = randomBytes
    }

    public static let rawLength = 32

    public func make() throws -> Nonce {
        let bytes = try randomBytes(Self.rawLength)
        let raw = encodeURLSafeBase64(bytes)
        let hashed = sha256Hex(raw)
        return Nonce(raw: raw, hashed: hashed)
    }

    /// Fill `count` bytes from a cryptographically-secure source. Darwin uses
    /// `SecRandomCopyBytes` (kernel CSPRNG); other platforms read `/dev/urandom`
    /// directly. Any failure throws — the caller must never receive a partial
    /// buffer or a buffer seeded from a weaker source.
    @Sendable
    static func systemRandomBytes(_ count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        #if canImport(Security)
        let status = bytes.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else {
                return errSecAllocate
            }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw AuthError.providerInternal("SecRandomCopyBytes failed: OSStatus \(status)")
        }
        #else
        let url = URL(fileURLWithPath: "/dev/urandom")
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw AuthError.providerInternal("open /dev/urandom failed: \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        var filled = 0
        while filled < count {
            let remaining = count - filled
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: remaining) ?? Data()
            } catch {
                throw AuthError.providerInternal("read /dev/urandom failed: \(error.localizedDescription)")
            }
            if chunk.isEmpty {
                throw AuthError.providerInternal("/dev/urandom returned EOF after \(filled) of \(count) bytes")
            }
            for byte in chunk {
                bytes[filled] = byte
                filled += 1
            }
        }
        #endif
        return bytes
    }

    func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func encodeURLSafeBase64(_ bytes: [UInt8]) -> String {
        let standard = Data(bytes).base64EncodedString()
        return standard
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct Nonce: Sendable, Equatable {
    public let raw: String
    public let hashed: String
}
