#if canImport(Security) && canImport(Darwin)
import Foundation
import Security

/// Concrete, production-only HTTP client that enforces SPKI-SHA256
/// pinning on every outbound request.
///
/// The type exists to make pinning a **type-system invariant** rather
/// than a convention.
///
/// * Public callers can only construct a `PinnedHTTPClient` via the
///   `init(pinning:onRejection:)` initializer. That initializer builds
///   an ephemeral `URLSession` with cookies + caching disabled and
///   attaches a `PinnedSessionDelegate` before returning — there is no
///   public path to an unpinned instance.
/// * `PinnedHTTPClient` is the ONLY type the `SignedHTTPClient(transport:
///   store:attestationProvider:)` public initializer accepts, so the
///   coordination-server HTTP path at every protected call site
///   (`PairingClient`, `PairedDevicesClient`, `AuthClient`) is
///   structurally guaranteed to run through a pinned session.
/// * Tests that need to intercept requests use the package-private
///   `SignedHTTPClient.init(underlying: any HTTPClient, ...)` via
///   `@testable import CatLaserAuth`; that path never exists in a
///   release product build, so a "temporary" unpinned client in a
///   feature branch cannot compile against the production seam.
///
/// The Security framework is only available on Darwin. On Linux /
/// other platforms this file compiles out; `SignedHTTPClient`'s
/// production-facing public initializer is likewise Darwin-gated.
/// Library logic that builds on Linux SPM runners uses the
/// package-private init under `@testable` and is therefore untouched.
public struct PinnedHTTPClient: HTTPClient {
    private let session: URLSession

    /// Build a pinned HTTP client.
    ///
    /// - Parameters:
    ///   - pinning: the SPKI-SHA256 pin set. A challenge is accepted
    ///     iff the system trust chain validates AND at least one
    ///     certificate in the chain's SPKI hashes appears in the pin
    ///     set.
    ///   - onRejection: optional diagnostic callback fired whenever a
    ///     pinning check rejects a server trust challenge. Intended
    ///     for telemetry — the connection is still cancelled.
    public init(
        pinning: TLSPinning,
        onRejection: (@Sendable (_ reason: String) -> Void)? = nil,
    ) {
        self.session = URLSession.pinned(pinning: pinning, onRejection: onRejection)
    }

    /// Package-private escape hatch so tests living in `CatLaserAuthTests`
    /// can inject a pre-built `URLSession` without going through
    /// `URLSession.pinned(...)`. Not exposed outside the module —
    /// downstream code targeting the production-facing API cannot reach
    /// this initializer. Kept separate from the public designated init
    /// so any test that uses it is visibly exercising a test-only path.
    init(preBuiltSession: URLSession) {
        self.session = preBuiltSession
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

#endif
