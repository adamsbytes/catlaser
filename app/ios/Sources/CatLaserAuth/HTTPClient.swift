import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        for (key, value) in headers where key.lowercased() == lower {
            return value
        }
        return nil
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// Thin async wrapper over `URLSession.data(for:)`.
///
/// The default initializer is intentionally absent. A production auth HTTP
/// client MUST be built via `URLSessionHTTPClient.pinned(pinning:)`, which
/// attaches a TLS-pinning delegate and an ephemeral (no-cache, no-cookie)
/// session configuration. The `init(session:)` escape hatch exists only
/// for tests that wire their own `URLSession` — tests that want to stub
/// out the network entirely should use `MockHTTPClient` in the test
/// target instead.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthError.network(NetworkFailure(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.malformedResponse("non-HTTP response")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let keyString = key as? String, let valueString = value as? String {
                headers[keyString] = valueString
            }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}
