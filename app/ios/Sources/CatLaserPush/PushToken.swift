import Foundation

/// Typed wrapper around an APNs device token.
///
/// APNs hands the app raw bytes; every server-side sender (FCM, the
/// device daemon's SQLite `push_tokens` table) expects a lowercase-hex
/// ASCII string. Centralising the encoding in a single typed wrapper
/// means no call site repeats the `map { String(format: "%02x", $0) }`
/// dance — a surprisingly common place to introduce casing bugs (the
/// device's `register_push_token` CRUD is case-sensitive and so is the
/// server-side dedupe).
///
/// Construction is fail-closed: a token whose length is outside the
/// plausible APNs range is rejected at the boundary so a garbage-in
/// scenario (malicious push extension, NSUserDefaults tampering, a
/// zero-length `Data` from an error path) never reaches the wire and
/// burns an attestation-signed round-trip. The minimum matches the
/// historical APNs token size (32 bytes / 64 hex chars) and the
/// maximum is the APNs-documented ceiling (100 bytes / 200 hex chars)
/// that also bounds the `bytes token` proto field the device side
/// stores.
public struct PushToken: Sendable, Equatable, Hashable {
    /// Canonical lowercase-hex form, as expected by every downstream
    /// sender (FCM ``token`` field, device-side SQLite row, the
    /// ``RegisterPushTokenRequest.token`` string).
    public let hex: String

    /// Minimum plausible APNs token length in bytes (i.e. 32 bytes →
    /// 64 hex chars). APNs has historically emitted exactly 32-byte
    /// tokens; accepting shorter would open the door to empty or
    /// truncated values sneaking onto the wire.
    public static let minimumLength: Int = 32

    /// APNs-documented upper bound on device-token length (100 bytes
    /// / 200 hex chars). Apple reserves the right to extend up to
    /// this size; beyond it is a client bug or hostile input.
    public static let maximumLength: Int = 100

    /// Build from raw APNs bytes (e.g. the ``Data`` passed to
    /// ``application(_:didRegisterForRemoteNotificationsWithDeviceToken:)``).
    ///
    /// Throws ``PushError/invalidToken(reason:)`` for empty, too-short,
    /// or oversized inputs.
    public init(rawBytes: Data) throws(PushError) {
        guard rawBytes.count >= Self.minimumLength else {
            throw .invalidToken(
                reason: "apns device token too short: \(rawBytes.count) bytes (minimum \(Self.minimumLength))",
            )
        }
        guard rawBytes.count <= Self.maximumLength else {
            throw .invalidToken(
                reason: "apns device token too long: \(rawBytes.count) bytes (maximum \(Self.maximumLength))",
            )
        }
        // Inlined hex encoder — avoids pulling in a crypto or
        // formatting dependency for what is a dozen lines of code.
        // Emitting lowercase matches the `%02x` convention used
        // everywhere else in the stack; casing is load-bearing for
        // the server-side dedupe.
        let digits: [UInt8] = [
            0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
            0x38, 0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66,
        ]
        var buffer = [UInt8]()
        buffer.reserveCapacity(rawBytes.count * 2)
        for byte in rawBytes {
            buffer.append(digits[Int(byte >> 4)])
            buffer.append(digits[Int(byte & 0x0F)])
        }
        // ``String(bytes:encoding:)`` cannot fail here — every byte
        // in ``buffer`` is one of the hex-digit ASCII codes above,
        // which are all valid UTF-8. Force-unwrap is the right
        // contract at the boundary: a non-nil return is a compile-
        // time invariant we want to preserve, not a runtime
        // uncertainty.
        guard let hex = String(bytes: buffer, encoding: .utf8) else {
            throw .internalFailure("failed to utf8-encode hex buffer")
        }
        self.hex = hex
    }

    /// Build from a pre-computed hex string. Validates shape — must
    /// be lowercase hex (0-9 + a-f), even length, and within
    /// ``minimumLength * 2`` … ``maximumLength * 2`` characters.
    ///
    /// Used by tests and by the in-process re-registration path where
    /// the byte decode has already happened; the validation keeps the
    /// invariant intact regardless of which construction path runs.
    public init(hex: String) throws(PushError) {
        guard !hex.isEmpty else {
            throw .invalidToken(reason: "apns token hex is empty")
        }
        let byteCount = hex.count / 2
        guard hex.count % 2 == 0 else {
            throw .invalidToken(
                reason: "apns token hex has odd length (\(hex.count) chars)",
            )
        }
        guard byteCount >= Self.minimumLength else {
            throw .invalidToken(
                reason: "apns token hex too short: \(byteCount) bytes (minimum \(Self.minimumLength))",
            )
        }
        guard byteCount <= Self.maximumLength else {
            throw .invalidToken(
                reason: "apns token hex too long: \(byteCount) bytes (maximum \(Self.maximumLength))",
            )
        }
        for scalar in hex.unicodeScalars {
            switch scalar.value {
            case 0x30 ... 0x39, 0x61 ... 0x66:
                continue
            default:
                throw .invalidToken(
                    reason: "apns token hex contains non-[0-9a-f] character",
                )
            }
        }
        self.hex = hex
    }
}
