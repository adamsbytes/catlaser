#if canImport(GoogleSignIn)
import Foundation
import GoogleSignIn
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public final class GoogleIDTokenProvider: GoogleIDTokenProviding, @unchecked Sendable {
    private let clientID: String
    private let serverClientID: String?
    private let scopes: [String]

    public init(clientID: String, serverClientID: String? = nil, scopes: [String] = []) {
        self.clientID = clientID
        self.serverClientID = serverClientID
        self.scopes = scopes
        let config = GIDConfiguration(clientID: clientID, serverClientID: serverClientID)
        GIDSignIn.sharedInstance.configuration = config
    }

    public func requestIDToken(
        context: ProviderPresentationContext,
    ) async throws -> ProviderIDToken {
        #if canImport(UIKit) && !os(watchOS)
        let presenterOpt: UIViewController? = await MainActor.run {
            context.viewController ?? Self.topViewController()
        }
        guard let presenter = presenterOpt else {
            throw AuthError.providerUnavailable("Google: no presenting UIViewController available")
        }
        let result = try await runSignIn(presenting: presenter)
        return try extract(from: result)
        #elseif canImport(AppKit)
        guard let window = context.window ?? NSApplication.shared.keyWindow else {
            throw AuthError.providerUnavailable("Google: no presenting NSWindow available")
        }
        let result = try await runSignIn(presenting: window)
        return try extract(from: result)
        #else
        throw AuthError.providerUnavailable("Google sign-in not available on this platform")
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    private func runSignIn(presenting: UIViewController) async throws -> GIDSignInResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                GIDSignIn.sharedInstance.signIn(
                    withPresenting: presenting,
                    hint: nil,
                    additionalScopes: self.scopes,
                ) { signInResult, error in
                    Self.complete(continuation: continuation, result: signInResult, error: error)
                }
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
    private func runSignIn(presenting: NSWindow) async throws -> GIDSignInResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                GIDSignIn.sharedInstance.signIn(
                    withPresenting: presenting,
                    hint: nil,
                    additionalScopes: self.scopes,
                ) { signInResult, error in
                    Self.complete(continuation: continuation, result: signInResult, error: error)
                }
            }
        }
    }
    #endif

    #if canImport(UIKit) || canImport(AppKit)
    private static func complete(
        continuation: CheckedContinuation<GIDSignInResult, Error>,
        result: GIDSignInResult?,
        error: Error?,
    ) {
        if let error {
            let nsError = error as NSError
            if nsError.domain == kGIDSignInErrorDomain, nsError.code == GIDSignInError.canceled.rawValue {
                continuation.resume(throwing: AuthError.cancelled)
            } else {
                continuation.resume(throwing: AuthError.providerInternal(nsError.localizedDescription))
            }
            return
        }
        guard let result else {
            continuation.resume(throwing: AuthError.providerInternal("Google returned no result"))
            return
        }
        continuation.resume(returning: result)
    }

    private func extract(from result: GIDSignInResult) throws -> ProviderIDToken {
        guard let idToken = result.user.idToken?.tokenString, !idToken.isEmpty else {
            throw AuthError.missingIDToken
        }
        let accessToken = result.user.accessToken.tokenString
        return ProviderIDToken(
            token: idToken,
            rawNonce: nil,
            accessToken: accessToken.isEmpty ? nil : accessToken,
        )
    }
    #endif
}
#endif
