import CatLaserDevice
import Foundation

/// Result of a successful pairing exchange.
///
/// Persisted to the Keychain after the coordination server resolves a
/// QR-scanned `code` into a reachable Tailscale endpoint. Re-loaded on
/// every app launch so the app can reconnect without re-running the
/// pairing flow.
///
/// Invariants:
///
/// * `id` matches the `device` parameter from the QR that produced
///   this row. It is NOT a secret — surfaced to the user, shown on
///   the paired-devices list.
/// * `name` is a user-facing label returned by the server. May be
///   empty if the device has not been renamed; the UI substitutes
///   `id` in that case.
/// * `endpoint` is the Tailscale-reachable host/port the app opens
///   its TCP channel to. Host format is validated by
///   `DeviceEndpoint.init`; a malformed server response would have
///   been rejected at `PairingClient.exchange` time.
/// * `pairedAt` is the clock reading at successful pairing, not at
///   persistence. Restored verbatim on reload so stats-level UI can
///   show "paired 3 days ago".
/// * `devicePublicKey` is the device's Ed25519 public key — exactly
///   32 raw bytes, the same material the device registered at
///   provisioning and the coordination server republished in the
///   pair-exchange response. The app uses this key to verify every
///   `AuthResponse` signature during TCP handshake, closing the
///   "impostor at the Tailscale endpoint" gap that a one-way
///   (app-attests-to-device) handshake leaves open. A missing or
///   malformed key aborts persistence at `PairingClient.exchange`
///   time; the app never stores a pairing row it cannot verify with.
public struct PairedDevice: Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let endpoint: DeviceEndpoint
    public let pairedAt: Date
    public let devicePublicKey: Data

    public init(
        id: String,
        name: String,
        endpoint: DeviceEndpoint,
        pairedAt: Date,
        devicePublicKey: Data,
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.pairedAt = pairedAt
        self.devicePublicKey = devicePublicKey
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case endpoint
        case pairedAt
        case devicePublicKey
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        endpoint = try c.decode(DeviceEndpoint.self, forKey: .endpoint)
        pairedAt = try c.decode(Date.self, forKey: .pairedAt)
        // Decoded as Data so the Codable round-trip (JSON) emits
        // base64-standard; stored in Keychain as a base64-encoded
        // string in the JSON blob. Length is re-validated on every
        // decode so a row written by an older build (missing the
        // key) surfaces as a clean decode failure rather than
        // silently producing a PairedDevice the verifier cannot
        // use.
        let raw = try c.decode(Data.self, forKey: .devicePublicKey)
        guard raw.count == PairedDevice.devicePublicKeyLength else {
            throw DecodingError.dataCorruptedError(
                forKey: .devicePublicKey,
                in: c,
                debugDescription: "device_public_key must be \(PairedDevice.devicePublicKeyLength) bytes, got \(raw.count)",
            )
        }
        devicePublicKey = raw
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(endpoint, forKey: .endpoint)
        try c.encode(pairedAt, forKey: .pairedAt)
        try c.encode(devicePublicKey, forKey: .devicePublicKey)
    }

    /// Exact byte count of a raw Ed25519 public key. Anything else
    /// coming off the wire or out of Keychain is rejected at the
    /// decode boundary — Curve25519's `PublicKey(rawRepresentation:)`
    /// would itself throw, but catching the wrong length earlier
    /// keeps the error message precise.
    public static let devicePublicKeyLength = 32
}
