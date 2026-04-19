import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP transport that uploads a batch of telemetry events (and an
/// optional crash payload) to the observability ingest endpoint.
///
/// The transport is injected rather than constructed in-line so the
/// composition root can control:
///
/// - Pinning: production builds wrap a ``PinnedHTTPClient`` (see
///   ``CatLaserAuth``); tests wrap a ``MockHTTPClient``.
/// - Bearer attachment: the production wrapper fishes the current
///   bearer out of the keychain when a signed-in user is present and
///   attaches it so the server can map the payload to the account;
///   pre-sign-in and post-sign-out uploads flow without a bearer and
///   the server accepts them against the device-ID hash alone.
/// - Retry policy: the transport returns a typed ``ObservabilityError``
///   so the uploader can decide whether to back off or discard the
///   batch.
public protocol ObservabilityTransport: Sendable {
    /// Upload a batch. Returns on HTTP 2xx; throws a typed
    /// ``ObservabilityError`` on every non-success outcome so the
    /// uploader can branch cleanly.
    func upload(_ batch: UploadBatch) async throws
}

/// HTTP-based transport backed by a caller-supplied ``HTTPClient``.
///
/// The public initialiser accepts any ``HTTPClient``; the composition
/// root passes the same pinned client used for auth traffic. The
/// transport never signs with bearer itself — it delegates to the
/// caller-supplied ``bearerProvider`` closure, which returns the
/// current bearer or `nil`. This keeps the auth dependency optional
/// (pre-sign-in crash uploads still work) and lets the composition
/// decide the bearer source without this module needing to import
/// ``CatLaserAuth``.
public struct HTTPObservabilityTransport: ObservabilityTransport {
    /// Closure that returns the current bearer token, or `nil` if the
    /// user is not signed in. Called per upload so a freshly-signed-
    /// in session attaches its bearer on the next batch without the
    /// transport caching state.
    public typealias BearerProvider = @Sendable () async -> String?

    private let uploadURL: URL
    private let httpClient: any ObservabilityHTTPClient
    private let bearerProvider: BearerProvider
    private let encoder: JSONEncoder

    public init(
        uploadURL: URL,
        httpClient: any ObservabilityHTTPClient,
        bearerProvider: @escaping BearerProvider,
    ) {
        self.uploadURL = uploadURL
        self.httpClient = httpClient
        self.bearerProvider = bearerProvider
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    public func upload(_ batch: UploadBatch) async throws {
        let payload: Data
        do {
            payload = try encoder.encode(batch)
        } catch {
            throw ObservabilityError.encodingFailed("upload batch: \(error)")
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(batch.context.deviceIDHash, forHTTPHeaderField: "x-device-id-hash")
        request.setValue(batch.context.sessionID, forHTTPHeaderField: "x-session-id")
        if let bearer = await bearerProvider(), !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = payload

        let response: ObservabilityHTTPResponse
        do {
            response = try await httpClient.send(request)
        } catch {
            throw ObservabilityError.uploadUnreachable(error.localizedDescription)
        }

        switch response.statusCode {
        case 200 ..< 300:
            return
        case 429:
            throw ObservabilityError.uploadTransient("rate limited")
        case 500 ..< 600:
            throw ObservabilityError.uploadTransient("server error \(response.statusCode)")
        default:
            throw ObservabilityError.uploadRejected(statusCode: response.statusCode)
        }
    }
}

/// Minimal ``HTTPClient`` contract copied from ``CatLaserAuth`` so
/// this module does not depend on the auth module at compile time.
/// The composition root supplies the same concrete type in both
/// places — see `AppComposition.production`.
public protocol ObservabilityHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> ObservabilityHTTPResponse
}

public struct ObservabilityHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// In-memory transport used by tests and by the composition-
/// invariants suite. Records every uploaded batch so assertions can
/// read back the exact bytes the production path would have
/// submitted.
public actor InMemoryObservabilityTransport: ObservabilityTransport {
    public enum Behavior: Sendable {
        case succeed
        case fail(ObservabilityError)
    }

    private(set) public var uploaded: [UploadBatch] = []
    private var behavior: Behavior

    public init(behavior: Behavior = .succeed) {
        self.behavior = behavior
    }

    public func setBehavior(_ behavior: Behavior) {
        self.behavior = behavior
    }

    public func upload(_ batch: UploadBatch) async throws {
        switch behavior {
        case .succeed:
            uploaded.append(batch)
        case let .fail(error):
            throw error
        }
    }
}
