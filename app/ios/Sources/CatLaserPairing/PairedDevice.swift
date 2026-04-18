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
public struct PairedDevice: Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let endpoint: DeviceEndpoint
    public let pairedAt: Date

    public init(
        id: String,
        name: String,
        endpoint: DeviceEndpoint,
        pairedAt: Date,
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.pairedAt = pairedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case endpoint
        case pairedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        endpoint = try c.decode(DeviceEndpoint.self, forKey: .endpoint)
        pairedAt = try c.decode(Date.self, forKey: .pairedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(endpoint, forKey: .endpoint)
        try c.encode(pairedAt, forKey: .pairedAt)
    }
}
