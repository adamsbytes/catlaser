import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
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

    @Sendable
    private static func systemRandomBytes(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min ... UInt8.max)
        }
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
