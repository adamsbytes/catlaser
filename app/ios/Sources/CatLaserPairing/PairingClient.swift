import CatLaserAuth
import CatLaserDevice
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP client for the coordination-server-brokered pairing exchange.
///
/// POSTs a scanned `(code, device_id)` pair to the coordination
/// server. The server resolves the code against its internal ledger
/// of provisioning-time-issued codes, looks up the device's current
/// Tailscale endpoint, and returns it. This is the ONLY bridge
/// between a scanned QR and a reachable device address; the QR
/// itself never carries the endpoint, so a captured QR that never
/// reaches the server does not leak routing information.
///
/// ## Wire contract
///
/// ```
/// POST /api/v1/devices/pair
/// Authorization: Bearer <session bearer>
/// x-device-attestation: <api:<ts> signed payload>
/// Idempotency-Key: <rfc-4122 uuid>
/// Content-Type: application/json
///
/// { "code": "<base32>", "device_id": "<slug>" }
///
/// 200 OK, application/json:
/// { "device_id": "<slug>", "device_name": "<display>",
///   "host": "<tailscale host or IP>", "port": <uint16> }
/// ```
///
/// All three of `Authorization`, `x-device-attestation`, and
/// `Idempotency-Key` are attached by `SignedHTTPClient`. The caller
/// constructs the `URLRequest` here without those headers; the signed
/// wrapper owns them.
///
/// ## Failure mapping
///
/// * 400 — `PairingError.invalidCode(.malformedURL)` (unlikely — we
///   validated client-side, but the server has authority).
/// * 401 — `PairingError.missingSession`. The signed wrapper should
///   have caught this; surfacing 401 here means the bearer was
///   revoked between load and send.
/// * 404 — `PairingError.codeNotFound` (code never issued).
/// * 409 — `PairingError.codeAlreadyUsed` (single-use QR already
///   consumed by another session; get a fresh QR from the device).
/// * 410 — `PairingError.codeExpired`.
/// * 429 — `PairingError.rateLimited` — wait window advertised via
///   `Retry-After` header (not parsed here; the UI surfaces the raw
///   message and asks the user to wait).
/// * 5xx — `PairingError.serverError`.
/// * Other — `PairingError.invalidServerResponse` with the status
///   code in the message.
public struct PairingClient: Sendable {
    public static let pairPath = "api/v1/devices/pair"

    private let baseURL: URL
    private let http: any HTTPClient
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameters:
    ///   - baseURL: coordination server root. Must match
    ///     `AuthConfig.baseURL` byte-for-byte — using a different
    ///     origin would bypass the pinning posture and is a bug.
    ///   - http: `SignedHTTPClient` wrapping a pinned
    ///     `URLSessionHTTPClient`. Must be the signed variant; calling
    ///     the coordination server with an unsigned client would
    ///     produce 401 because the `api:` attestation middleware
    ///     rejects the call.
    public init(baseURL: URL, http: any HTTPClient) {
        self.baseURL = baseURL
        self.http = http
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Send a scanned pairing code to the coordination server and
    /// return the resolved device endpoint.
    public func exchange(code: PairingCode, now: Date = Date()) async throws(PairingError) -> PairedDevice {
        let body: Data
        do {
            body = try encoder.encode(PairExchangeRequest(code: code.code, deviceID: code.deviceID))
        } catch {
            throw .invalidServerResponse("request encode failed: \(error.localizedDescription)")
        }

        var request = URLRequest(url: baseURL.appendingPathComponent(Self.pairPath))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch let error as AuthError {
            throw PairingError.from(error)
        } catch {
            throw .network(error.localizedDescription)
        }

        switch response.statusCode {
        case 200 ..< 300:
            return try parseSuccess(response, now: now)
        case 400:
            let message = extractMessage(from: response)
            throw .invalidServerResponse(message ?? "server rejected pairing request (400)")
        case 401:
            throw .missingSession
        case 404:
            throw .codeNotFound(message: extractMessage(from: response))
        case 409:
            throw .codeAlreadyUsed(message: extractMessage(from: response))
        case 410:
            throw .codeExpired(message: extractMessage(from: response))
        case 429:
            throw .rateLimited(message: extractMessage(from: response))
        default:
            throw .serverError(status: response.statusCode, message: extractMessage(from: response))
        }
    }

    private func parseSuccess(_ response: HTTPResponse, now: Date) throws(PairingError) -> PairedDevice {
        let decoded: PairExchangeResponse
        do {
            decoded = try decoder.decode(PairExchangeResponse.self, from: response.body)
        } catch {
            throw .invalidServerResponse("decode failed: \(error.localizedDescription)")
        }
        guard decoded.port > 0, decoded.port <= UInt16.max else {
            throw .invalidServerResponse("port out of range: \(decoded.port)")
        }
        let endpoint: DeviceEndpoint
        do {
            endpoint = try DeviceEndpoint(host: decoded.host, port: UInt16(decoded.port))
        } catch {
            throw .invalidServerResponse("invalid endpoint: \(String(describing: error))")
        }
        let trimmedID = decoded.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw .invalidServerResponse("device_id missing in response")
        }
        return PairedDevice(
            id: trimmedID,
            name: decoded.deviceName ?? "",
            endpoint: endpoint,
            pairedAt: now,
        )
    }

    private func extractMessage(from response: HTTPResponse) -> String? {
        guard !response.body.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] {
            if let message = object["message"] as? String, !message.isEmpty {
                return message
            }
            if let error = object["error"] as? String, !error.isEmpty {
                return error
            }
            if let code = object["code"] as? String, !code.isEmpty {
                return code
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

struct PairExchangeRequest: Encodable, Equatable {
    let code: String
    let deviceID: String

    enum CodingKeys: String, CodingKey {
        case code
        case deviceID = "device_id"
    }
}

struct PairExchangeResponse: Decodable, Equatable {
    let deviceID: String
    let deviceName: String?
    let host: String
    let port: Int

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case deviceName = "device_name"
        case host
        case port
    }
}
