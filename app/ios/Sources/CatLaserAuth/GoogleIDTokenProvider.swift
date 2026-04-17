#if canImport(AppAuth)
import AppAuth
import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Google sign-in that runs the OIDC Authorization Code + PKCE flow with
/// an explicit `nonce`. The raw nonce is sent in the authorization request
/// and must be echoed back verbatim in the issued ID token's `nonce` claim;
/// the server rechecks this on token exchange, and so does this client as
/// defence in depth (a compromised in-app browser / hooked AppAuth session
/// that returned a different token for a different user would be caught
/// locally before it ever reaches the wire).
///
/// ## Endpoints are hardcoded, not discovered
///
/// Google's OIDC authorization and token endpoints have been stable at the
/// URLs below for well over a decade. Hardcoding them eliminates the
/// discovery-document round-trip entirely — and with it the attack
/// surface where a network adversary with a rogue system-trusted CA
/// could rewrite `/.well-known/openid-configuration` to redirect the
/// authorization endpoint to an attacker-controlled page that harvests
/// Google credentials, or redirect the token endpoint to capture the
/// PKCE verifier + authorization code. The endpoints are what the app
/// ships with; no network response can move them.
///
/// ## Network path is pinned
///
/// AppAuth uses `NSURLSession` for the token-exchange POST. (The
/// authorization step runs inside `ASWebAuthenticationSession`, which is
/// Safari-process — we cannot pin it, but it is out-of-process and
/// user-visible.) Callers supply a pinned `URLSession` at init time;
/// `requestIDToken` installs it on the AppAuth-wide singleton via
/// `OIDURLSessionProvider.setSession(_:)` before each authorization, so
/// the token-exchange call is SPKI-pinned. Setting the session every
/// call is idempotent and costs nothing; it also ensures no third-party
/// dependency can silently swap the session out between our sign-ins.
///
/// ## Redirect URL policy
///
/// `redirectURL` must:
///
/// 1. Have scheme `https`.
/// 2. Specify a host present in `allowedRedirectHosts`.
/// 3. Specify no port.
/// 4. Carry no userinfo.
///
/// Custom URL schemes (`com.example:/oauth`, `com.googleusercontent.apps.*`,
/// app-specific reverse-DNS) are **rejected**. iOS custom-scheme routing
/// has no ownership verification — any other installed app can claim the
/// same scheme and intercept the OAuth response code. An HTTPS Universal
/// Link restricted to an AASA-claimed domain makes interception impossible
/// because Apple's secure domain-association step requires the app to
/// prove bundle-ID ownership of the domain.
///
/// The server **must** host an `apple-app-site-association` file on each
/// host listed in `allowedRedirectHosts` registering the OAuth callback
/// path with this app's bundle identifier. Without that AASA, iOS falls
/// back to Safari and the flow cannot complete — which is the desired
/// fail-closed behaviour.
public final class GoogleIDTokenProvider: GoogleIDTokenProviding, @unchecked Sendable {
    /// Google's OIDC authorization endpoint. Stable URL, shipped in the
    /// app binary rather than discovered at runtime.
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!

    /// Google's OIDC token-exchange endpoint. Stable URL, shipped in the
    /// app binary rather than discovered at runtime.
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// OIDC issuer identifier for Google. Used as the `issuer` field on
    /// `OIDServiceConfiguration` for book-keeping; we do not fetch the
    /// discovery document from it.
    public static let defaultIssuerURL = URL(string: "https://accounts.google.com")!

    /// The default scopes map one-to-one to the identity claims Better Auth's
    /// Google provider expects on the server: `sub`, `email`, and profile fields.
    public static let defaultScopes: [String] = ["openid", "email", "profile"]

    private let clientID: String
    private let redirectURL: URL
    private let pinnedSession: URLSession
    private let configuration: OIDServiceConfiguration
    private let scopes: [String]
    private let flowBox = FlowBox()

    public init(
        clientID: String,
        redirectURL: URL,
        allowedRedirectHosts: Set<String>,
        pinnedSession: URLSession,
        scopes: [String] = GoogleIDTokenProvider.defaultScopes,
    ) throws(AuthError) {
        try OAuthRedirectPolicy.validate(redirectURL, allowedHosts: allowedRedirectHosts)
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .providerInternal("Google client ID must not be empty")
        }
        self.clientID = clientID
        self.redirectURL = redirectURL
        self.pinnedSession = pinnedSession
        self.configuration = OIDServiceConfiguration(
            authorizationEndpoint: GoogleIDTokenProvider.authorizationEndpoint,
            tokenEndpoint: GoogleIDTokenProvider.tokenEndpoint,
            issuer: GoogleIDTokenProvider.defaultIssuerURL,
        )
        self.scopes = scopes
    }

    /// Forward a Universal Link / custom-URL-scheme callback to the in-flight
    /// AppAuth session. Returns true iff AppAuth recognised the URL and consumed
    /// it. On iOS 13+ ASWebAuthenticationSession handles the redirect internally
    /// and this hook typically won't be hit, but the app delegate should still
    /// call it from `application(_:open:options:)` and the SwiftUI
    /// `onOpenURL` handler to stay safe against older agent fallbacks.
    @discardableResult
    public func resume(with url: URL) -> Bool {
        flowBox.resume(with: url)
    }

    public func requestIDToken(
        rawNonce: String,
        context: ProviderPresentationContext,
    ) async throws -> ProviderIDToken {
        guard !rawNonce.isEmpty else {
            throw AuthError.providerInternal("Google: rawNonce must not be empty")
        }
        // Route AppAuth's internal NSURLSession calls (most importantly
        // the token-exchange POST) through the pinned session. Safe to
        // call every time — OIDURLSessionProvider is a process-wide
        // singleton and we re-assert our session before each flow so no
        // other dependency can silently replace it between sign-ins.
        OIDURLSessionProvider.setSession(pinnedSession)
        // Convenience init generates a fresh `state` and a consistent
        // PKCE verifier+challenge (S256) automatically. We only override the
        // nonce so the ID token comes back bound to our pre-committed value.
        let request = OIDAuthorizationRequest(
            configuration: configuration,
            clientId: clientID,
            scopes: scopes,
            redirectURL: redirectURL,
            responseType: OIDResponseTypeCode,
            nonce: rawNonce,
            additionalParameters: nil,
        )
        let state = try await present(request: request, context: context)
        let token = try extract(from: state, rawNonce: rawNonce)
        try IDTokenClaims.verifyNonce(idToken: token.token, expectedNonce: rawNonce)
        return token
    }

    #if canImport(UIKit) && !os(watchOS)
    private func present(
        request: OIDAuthorizationRequest,
        context: ProviderPresentationContext,
    ) async throws -> OIDAuthState {
        let presenterOpt: UIViewController? = await MainActor.run {
            context.viewController ?? Self.topViewController()
        }
        guard let presenter = presenterOpt else {
            throw AuthError.providerUnavailable("Google: no presenting UIViewController available")
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                let session = OIDAuthState.authState(
                    byPresenting: request,
                    presenting: presenter,
                ) { authState, error in
                    self.flowBox.finish()
                    Self.complete(continuation: continuation, state: authState, error: error)
                }
                self.flowBox.set(session: session)
            }
        }
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        for scene in scenes {
            guard let windowScene = scene as? UIWindowScene,
                  scene.activationState == .foregroundActive else { continue }
            for window in windowScene.windows where window.isKeyWindow {
                if let root = window.rootViewController {
                    return topMost(from: root)
                }
            }
            if let any = windowScene.windows.first, let root = any.rootViewController {
                return topMost(from: root)
            }
        }
        return nil
    }

    @MainActor
    private static func topMost(from controller: UIViewController) -> UIViewController {
        if let presented = controller.presentedViewController {
            return topMost(from: presented)
        }
        if let nav = controller as? UINavigationController, let visible = nav.visibleViewController {
            return topMost(from: visible)
        }
        if let tab = controller as? UITabBarController, let selected = tab.selectedViewController {
            return topMost(from: selected)
        }
        return controller
    }
    #elseif canImport(AppKit)
    private func present(
        request: OIDAuthorizationRequest,
        context: ProviderPresentationContext,
    ) async throws -> OIDAuthState {
        let presenterOpt: NSWindow? = await MainActor.run {
            context.window ?? NSApplication.shared.keyWindow
        }
        guard let presenter = presenterOpt else {
            throw AuthError.providerUnavailable("Google: no presenting NSWindow available")
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                let session = OIDAuthState.authState(
                    byPresenting: request,
                    presenting: presenter,
                ) { authState, error in
                    self.flowBox.finish()
                    Self.complete(continuation: continuation, state: authState, error: error)
                }
                self.flowBox.set(session: session)
            }
        }
    }
    #endif

    #if canImport(UIKit) || canImport(AppKit)
    private static func complete(
        continuation: CheckedContinuation<OIDAuthState, Error>,
        state: OIDAuthState?,
        error: Error?,
    ) {
        if let error {
            continuation.resume(throwing: map(error: error))
            return
        }
        guard let state else {
            continuation.resume(throwing: AuthError.providerInternal("Google returned no auth state"))
            return
        }
        continuation.resume(returning: state)
    }

    private static func map(error: Error) -> AuthError {
        let ns = error as NSError
        if ns.domain == OIDGeneralErrorDomain {
            switch ns.code {
            case OIDErrorCode.userCanceledAuthorizationFlow.rawValue,
                 OIDErrorCode.programCanceledAuthorizationFlow.rawValue:
                return .cancelled
            default:
                return .providerInternal("Google: \(ns.localizedDescription)")
            }
        }
        return .providerInternal(ns.localizedDescription)
    }

    private func extract(from state: OIDAuthState, rawNonce: String) throws -> ProviderIDToken {
        guard let tokenResponse = state.lastTokenResponse else {
            throw AuthError.missingIDToken
        }
        guard let idToken = tokenResponse.idToken, !idToken.isEmpty else {
            throw AuthError.missingIDToken
        }
        let accessToken = tokenResponse.accessToken
        return ProviderIDToken(
            token: idToken,
            rawNonce: rawNonce,
            accessToken: (accessToken?.isEmpty == false) ? accessToken : nil,
        )
    }
    #endif
}

/// Holds the in-flight AppAuth session so that a callback URL delivered via
/// `application(_:open:options:)` can be forwarded to it. Thread-safe by lock.
private final class FlowBox: @unchecked Sendable {
    private let lock = NSLock()
    private var session: (any OIDExternalUserAgentSession)?

    func set(session: any OIDExternalUserAgentSession) {
        lock.lock()
        defer { lock.unlock() }
        self.session = session
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        session = nil
    }

    func resume(with url: URL) -> Bool {
        lock.lock()
        let current = session
        lock.unlock()
        return current?.resumeExternalUserAgentFlow(with: url) ?? false
    }
}
#endif
