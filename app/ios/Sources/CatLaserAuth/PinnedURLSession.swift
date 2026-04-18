#if canImport(Security) && canImport(Darwin)
import Foundation
import Security

/// URLSession delegate that enforces SPKI-SHA256 pinning on every server
/// trust challenge.
///
/// Protocol:
///
/// 1. The challenge must be for `NSURLAuthenticationMethodServerTrust`.
///    Other methods (client cert, HTTP basic, etc.) are passed through to
///    default handling — pinning does not alter them.
/// 2. The system performs its own trust evaluation first via
///    `SecTrustEvaluateWithError`. This preserves CA validity, expiry,
///    hostname, OCSP, and CT checks. If the system rejects the chain, we
///    reject — pinning never *loosens* trust, it only tightens it.
/// 3. Every certificate in the chain is hashed (SubjectPublicKeyInfo
///    SHA-256). If *any* cert's SPKI hash matches any configured pin, the
///    challenge is accepted. Otherwise it is cancelled with an explicit
///    error attached to the session task.
///
/// A single delegate instance is reused across tasks on the same session;
/// it holds no per-request state.
public final class PinnedSessionDelegate: NSObject, URLSessionDelegate {
    public let pinning: TLSPinning
    private let onRejection: (@Sendable (_ reason: String) -> Void)?

    public init(
        pinning: TLSPinning,
        onRejection: (@Sendable (_ reason: String) -> Void)? = nil,
    ) {
        self.pinning = pinning
        self.onRejection = onRejection
        super.init()
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        switch evaluate(trust: trust, host: challenge.protectionSpace.host) {
        case .accept:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case let .reject(reason):
            onRejection?(reason)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    enum Decision: Equatable {
        case accept
        case reject(String)
    }

    /// Package-private so unit tests can exercise the decision without a
    /// real network session.
    func evaluate(trust: SecTrust, host: String) -> Decision {
        var cfError: CFError?
        guard SecTrustEvaluateWithError(trust, &cfError) else {
            let message = cfError.map { CFErrorCopyDescription($0) as String } ?? "trust evaluation failed"
            return .reject("system trust rejection for host \(host): \(message)")
        }

        let certificates = copyCertificateChain(trust)
        guard !certificates.isEmpty else {
            return .reject("empty certificate chain for host \(host)")
        }

        for certificate in certificates {
            let hash: Data
            do {
                hash = try SPKIHasher.sha256(of: certificate)
            } catch {
                // Skip this cert only — a chain can mix algorithms; we
                // care whether ANY cert matches a pin.
                continue
            }
            if pinning.matches(spkiHash: hash) {
                return .accept
            }
        }
        return .reject("no pinned SPKI matched for host \(host)")
    }

    private func copyCertificateChain(_ trust: SecTrust) -> [SecCertificate] {
        if #available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *) {
            if let array = SecTrustCopyCertificateChain(trust) as? [SecCertificate] {
                return array
            }
            return []
        } else {
            let count = SecTrustGetCertificateCount(trust)
            var chain: [SecCertificate] = []
            chain.reserveCapacity(count)
            for index in 0 ..< count {
                if let certificate = SecTrustGetCertificateAtIndex(trust, index) {
                    chain.append(certificate)
                }
            }
            return chain
        }
    }
}

public extension URLSession {
    /// Build an ephemeral `URLSession` with SPKI-SHA256 pinning applied on
    /// every server-trust challenge. Exposed so callers that need a raw
    /// `URLSession` — notably third-party SDKs like AppAuth, whose
    /// `OIDURLSessionProvider.setSession(_:)` accepts a `URLSession` —
    /// can obtain a pinned one without reaching into internal HTTP-client
    /// plumbing.
    ///
    /// The returned session:
    ///
    /// * Uses `URLSessionConfiguration.ephemeral` — no on-disk cache, no
    ///   cookie jar, no credential storage. Sensitive responses can
    ///   never be written to disk by URLSession's own caching layer.
    /// * Installs a `PinnedSessionDelegate` enforcing SPKI-SHA256 pinning
    ///   on every host the session connects to. The delegate compares
    ///   each certificate in the presented chain against the configured
    ///   pin set and rejects the connection if none match.
    /// * Disables `httpCookieAcceptPolicy` and `httpShouldSetCookies` for
    ///   defence in depth; the authenticated paths are bearer-token /
    ///   OAuth-code based and have no legitimate reason to accept
    ///   cookies.
    ///
    /// The delegate is retained by the session for the session's lifetime
    /// (URLSession holds a strong reference to its delegate). Callers
    /// that want to tear down the session should call
    /// `invalidateAndCancel` on it — but pinned sessions typically live
    /// for the app's lifetime.
    static func pinned(
        pinning: TLSPinning,
        onRejection: (@Sendable (_ reason: String) -> Void)? = nil,
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let delegate = PinnedSessionDelegate(pinning: pinning, onRejection: onRejection)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }
}

#endif
