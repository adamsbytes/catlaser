import Foundation
import Testing

@testable import CatLaserAuth

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Test double for `HTTPClient` scoped to the app layer's tests. Mirrors
/// the shape used by `CatLaserAuthTests/MockHTTPClient.swift` — kept
/// narrow and duplicated rather than shared via a third target because
/// Swift Package Manager test targets cannot depend on other test
/// targets, and promoting the mock to a public library would ship
/// throwaway test helpers as consumable product code.
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

    func sendCount() -> Int {
        recorded.count
    }

    func lastRequest() -> RecordedRequest? {
        recorded.last
    }

    func requests() -> [RecordedRequest] {
        recorded
    }

    func enqueue(_ outcome: Outcome) {
        outcomes.append(outcome)
    }

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
            throw AuthError.providerInternal("MockHTTPClient: no outcomes enqueued")
        }
        let outcome = outcomes.removeFirst()
        switch outcome {
        case let .response(r): return r
        case let .failure(e): throw e
        }
    }
}

extension HTTPResponse {
    static func json(
        _ dict: [String: Any],
        status: Int = 200,
        token: String? = nil,
    ) -> HTTPResponse {
        // Force-try is acceptable in test support — the JSON object is
        // constructed in-process from literals and never depends on
        // external input.
        // swiftlint:disable:next force_try
        let body = try! JSONSerialization.data(withJSONObject: dict)
        var headers: [String: String] = ["Content-Type": "application/json"]
        if let token {
            headers[AuthClient.bearerHeader] = token
        }
        return HTTPResponse(statusCode: status, headers: headers, body: body)
    }
}
