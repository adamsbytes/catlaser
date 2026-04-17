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
/// the server rechecks this on token exchange, closing the replay window.
public final class GoogleIDTokenProvider: GoogleIDTokenProviding, @unchecked Sendable {
    /// Google's OIDC issuer. The discovery document at
    /// `<issuer>/.well-known/openid-configuration` is fetched on first use
    /// and supplies the authorization and token endpoints.
    public static let defaultIssuerURL = URL(string: "https://accounts.google.com")!

    /// The default scopes map one-to-one to the identity claims Better Auth's
    /// Google provider expects on the server: `sub`, `email`, and profile fields.
    public static let defaultScopes: [String] = ["openid", "email", "profile"]

    private let clientID: String
    private let redirectURL: URL
    private let issuerURL: URL
    private let scopes: [String]
    private let flowBox = FlowBox()

    public init(
        clientID: String,
        redirectURL: URL,
        issuerURL: URL = GoogleIDTokenProvider.defaultIssuerURL,
        scopes: [String] = GoogleIDTokenProvider.defaultScopes,
    ) {
        self.clientID = clientID
        self.redirectURL = redirectURL
        self.issuerURL = issuerURL
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
        let config = try await discoverConfiguration()
        // Convenience init generates a fresh `state` and a consistent
        // PKCE verifier+challenge (S256) automatically. We only override the
        // nonce so the ID token comes back bound to our pre-committed value.
        let request = OIDAuthorizationRequest(
            configuration: config,
            clientId: clientID,
            scopes: scopes,
            redirectURL: redirectURL,
            responseType: OIDResponseTypeCode,
            nonce: rawNonce,
            additionalParameters: nil,
        )
        let state = try await present(request: request, context: context)
        return try extract(from: state, rawNonce: rawNonce)
    }

    private func discoverConfiguration() async throws -> OIDServiceConfiguration {
        try await withCheckedThrowingContinuation { continuation in
            OIDAuthorizationService.discoverConfiguration(forIssuer: self.issuerURL) { config, error in
                if let error {
                    continuation.resume(throwing: AuthError.providerInternal(
                        "Google discovery failed: \(error.localizedDescription)",
                    ))
                    return
                }
                guard let config else {
                    continuation.resume(throwing: AuthError.providerInternal(
                        "Google discovery returned no configuration",
                    ))
                    return
                }
                continuation.resume(returning: config)
            }
        }
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
