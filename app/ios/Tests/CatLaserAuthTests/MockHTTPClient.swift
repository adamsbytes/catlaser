import Foundation
import Testing

@testable import CatLaserAuth

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor MockHTTPClient: HTTPClient {
    struct RecordedRequest: Sendable {
        let url: URL?
        let method: String?
        let headers: [String: String]
        let body: Data?

        /// Case-insensitive header lookup. HTTP header names are
        /// case-insensitive per RFC 9110, and swift-corelibs-foundation
        /// title-cases custom header names on Linux (Darwin preserves case),
        /// so tests must not depend on the original casing.
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

    func sendCount() -> Int {
        recorded.count
    }

    func lastRequest() -> RecordedRequest? {
        recorded.last
    }

    func requests() -> [RecordedRequest] {
        recorded
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
    static func json(_ dict: [String: Any], status: Int = 200, token: String? = nil) -> HTTPResponse {
        let body = try! JSONSerialization.data(withJSONObject: dict)
        var headers: [String: String] = ["Content-Type": "application/json"]
        if let token {
            headers[AuthClient.bearerHeader] = token
        }
        return HTTPResponse(statusCode: status, headers: headers, body: body)
    }

    static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data(text.utf8))
    }
}
