import CatLaserAuth
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP fake for `PairingClientTests`. Mirrors the pattern in
/// `CatLaserAuthTests/MockHTTPClient.swift` — queue response outcomes
/// up front, drive the `PairingClient`, then assert on the recorded
/// requests.
actor MockHTTPClient: HTTPClient {
    struct RecordedRequest: Sendable {
        let url: URL?
        let method: String?
        let headers: [String: String]
        let body: Data?

        func header(_ name: String) -> String? {
            let lower = name.lowercased()
            for (k, v) in headers where k.lowercased() == lower {
                return v
            }
            return nil
        }
    }

    enum Outcome: Sendable {
        case response(HTTPResponse)
        case failure(any Error)
    }

    private var outcomes: [Outcome]
    private var recorded: [RecordedRequest] = []

    init(outcomes: [Outcome] = []) {
        self.outcomes = outcomes
    }

    func enqueue(_ outcome: Outcome) {
        outcomes.append(outcome)
    }

    func requests() -> [RecordedRequest] { recorded }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        var headers: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] {
            headers[k] = v
        }
        recorded.append(
            RecordedRequest(
                url: request.url,
                method: request.httpMethod,
                headers: headers,
                body: request.httpBody,
            ),
        )
        guard !outcomes.isEmpty else {
            struct NoOutcome: Error {}
            throw NoOutcome()
        }
        let outcome = outcomes.removeFirst()
        switch outcome {
        case let .response(r): return r
        case let .failure(e): throw e
        }
    }
}

extension HTTPResponse {
    static func json(_ dict: [String: Any], status: Int = 200) -> HTTPResponse {
        let body = try! JSONSerialization.data(withJSONObject: dict)
        return HTTPResponse(
            statusCode: status,
            headers: ["Content-Type": "application/json"],
            body: body,
        )
    }

    static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data(text.utf8))
    }

    static func empty(status: Int) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data())
    }
}
