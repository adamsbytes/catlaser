import CatLaserAuth
import CatLaserDevice
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP client for the ownership re-verification endpoint,
/// `GET /api/v1/devices/paired`.
///
/// ## Purpose
///
/// After a user pairs a device, the app stores `(device_id, host,
/// port)` in the Keychain and reconnects forever without ever asking
/// the coordination server whether that pairing is still authoritative.
/// If the device is later re-paired to a different user, or the
/// current user loses ownership for any other reason, the stored row
/// is stale — but the app has no independent signal to detect that,
/// so it keeps opening a TCP channel to the device on every launch.
///
/// `PairedDevicesClient` closes that gap. On launch (and at a daily
/// cadence while foregrounded) the app asks the coordination server
/// for its current active claims; if the Keychain's `device_id` is not
/// in the response, the app invokes `unpair()` and routes the user
/// back through the pairing flow. The server's `exchangePairingCode`
/// atomically revokes prior claims for the same `device_id`, so the
/// absence of a `device_id` in the response is an authoritative
/// signal, not a hint.
///
/// ## Wire contract
///
/// ```
/// GET /api/v1/devices/paired
/// Authorization: Bearer <session bearer>
/// x-device-attestation: <api:<ts> signed payload>
///
/// 200 OK, application/json:
/// { "ok": true,
///   "data": {
///     "devices": [
///       { "device_id": "<slug>", "device_name": "<display>|null",
///         "host": "<tailscale host>", "port": <uint16>,
///         "paired_at": "<ISO-8601>" },
///       ...
///     ]
///   }
/// }
/// ```
///
/// The `Authorization` and `x-device-attestation` headers are attached
/// by `SignedHTTPClient`; the caller here constructs the `URLRequest`
/// without them. No idempotency key — this is a read.
///
/// ## Failure mapping
///
/// * 401 — `PairingError.missingSession`. The signed wrapper normally
///   catches this, but a session revoked between bearer read and wire
///   send can surface here.
/// * 429 — `PairingError.rateLimited` with the server's advisory
///   message.
/// * 5xx — `PairingError.serverError`.
/// * Other non-2xx — `PairingError.invalidServerResponse` with the
///   status code captured.
public struct PairedDevicesClient: Sendable {
    public static let pairedPath = "api/v1/devices/paired"

    private let baseURL: URL
    private let http: any HTTPClient
    private let decoder: JSONDecoder

    /// - Parameters:
    ///   - baseURL: coordination server root. Must match
    ///     `AuthConfig.baseURL` byte-for-byte.
    ///   - http: `SignedHTTPClient` wrapping a pinned
    ///     `URLSessionHTTPClient`. Must be the signed variant; calling
    ///     the coordination server with an unsigned client produces
    ///     401 because the `api:` attestation middleware rejects it.
    public init(baseURL: URL, http: any HTTPClient) {
        self.baseURL = baseURL
        self.http = http
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Fetch the current list of non-revoked active claims owned by
    /// the signed-in user.
    public func list() async throws(PairingError) -> [PairedDevice] {
        let request = URLRequest(url: baseURL.appendingPathComponent(Self.pairedPath))
        var mutableRequest = request
        mutableRequest.httpMethod = "GET"
        mutableRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: HTTPResponse
        do {
            response = try await http.send(mutableRequest)
        } catch let error as AuthError {
            throw PairingError.from(error)
        } catch {
            throw .network(error.localizedDescription)
        }

        switch response.statusCode {
        case 200 ..< 300:
            return try parseSuccess(response)
        case 401:
            throw .missingSession
        case 429:
            throw .rateLimited(message: extractMessage(from: response))
        case 500 ..< 600:
            throw .serverError(status: response.statusCode, message: extractMessage(from: response))
        default:
            throw .invalidServerResponse(
                "unexpected status \(response.statusCode): \(extractMessage(from: response) ?? "no body")",
            )
        }
    }

    private func parseSuccess(_ response: HTTPResponse) throws(PairingError) -> [PairedDevice] {
        let envelope: ListEnvelope
        do {
            envelope = try decoder.decode(ListEnvelope.self, from: response.body)
        } catch {
            throw .invalidServerResponse("decode failed: \(error.localizedDescription)")
        }
        guard envelope.ok else {
            throw .invalidServerResponse("server returned ok=false on 2xx")
        }
        var devices: [PairedDevice] = []
        devices.reserveCapacity(envelope.data.devices.count)
        for entry in envelope.data.devices {
            let trimmedID = entry.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty else {
                throw .invalidServerResponse("device_id missing in list entry")
            }
            guard entry.port > 0, entry.port <= UInt16.max else {
                throw .invalidServerResponse("port out of range for \(trimmedID): \(entry.port)")
            }
            let endpoint: DeviceEndpoint
            do {
                endpoint = try DeviceEndpoint(host: entry.host, port: UInt16(entry.port))
            } catch {
                throw .invalidServerResponse(
                    "invalid endpoint for \(trimmedID): \(String(describing: error))",
                )
            }
            devices.append(
                PairedDevice(
                    id: trimmedID,
                    name: entry.deviceName ?? "",
                    endpoint: endpoint,
                    pairedAt: entry.pairedAt,
                ),
            )
        }
        return devices
    }

    private func extractMessage(from response: HTTPResponse) -> String? {
        guard !response.body.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] {
            if let error = object["error"] as? [String: Any] {
                if let message = error["message"] as? String, !message.isEmpty {
                    return message
                }
                if let code = error["code"] as? String, !code.isEmpty {
                    return code
                }
            }
            if let message = object["message"] as? String, !message.isEmpty {
                return message
            }
        }
        if let text = String(data: response.body, encoding: .utf8),
           !text.isEmpty,
           text.count <= 512
        {
            return text
        }
        return nil
    }
}

private struct ListEnvelope: Decodable {
    let ok: Bool
    let data: ListData
}

private struct ListData: Decodable {
    let devices: [ListEntry]
}

private struct ListEntry: Decodable {
    let deviceID: String
    let deviceName: String?
    let host: String
    let port: Int
    let pairedAt: Date

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case deviceName = "device_name"
        case host
        case port
        case pairedAt = "paired_at"
    }
}
