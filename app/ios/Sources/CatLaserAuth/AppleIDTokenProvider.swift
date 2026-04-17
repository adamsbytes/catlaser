#if canImport(AuthenticationServices)
import AuthenticationServices
import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public final class AppleIDTokenProvider: NSObject, AppleIDTokenProviding, @unchecked Sendable {
    private let scopes: [ASAuthorization.Scope]

    public init(scopes: [ASAuthorization.Scope] = [.fullName, .email]) {
        self.scopes = scopes
    }

    public func requestIDToken(
        nonceHash: String,
        context: ProviderPresentationContext,
    ) async throws -> ProviderIDToken {
        try await withCheckedThrowingContinuation { continuation in
            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = scopes
            request.nonce = nonceHash

            let controller = ASAuthorizationController(authorizationRequests: [request])
            let delegate = AppleAuthDelegate(continuation: continuation)
            let presenter = AppleAuthPresenter(context: context)

            controller.delegate = delegate
            controller.presentationContextProvider = presenter
            delegate.retain(controller: controller, presenter: presenter)
            controller.performRequests()
        }
    }
}

private final class AppleAuthDelegate: NSObject, ASAuthorizationControllerDelegate {
    private var continuation: CheckedContinuation<ProviderIDToken, Error>?
    private var retainedController: ASAuthorizationController?
    private var retainedPresenter: AppleAuthPresenter?

    init(continuation: CheckedContinuation<ProviderIDToken, Error>) {
        self.continuation = continuation
        super.init()
    }

    func retain(controller: ASAuthorizationController, presenter: AppleAuthPresenter) {
        retainedController = controller
        retainedPresenter = presenter
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization,
    ) {
        defer { release() }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            continuation?.resume(throwing: AuthError.credentialInvalid("non-Apple credential"))
            continuation = nil
            return
        }
        guard let tokenData = credential.identityToken,
              let tokenString = String(data: tokenData, encoding: .utf8),
              !tokenString.isEmpty
        else {
            continuation?.resume(throwing: AuthError.missingIDToken)
            continuation = nil
            return
        }
        continuation?.resume(returning: ProviderIDToken(token: tokenString, rawNonce: nil, accessToken: nil))
        continuation = nil
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error,
    ) {
        defer { release() }
        let mapped: AuthError
        if let asError = error as? ASAuthorizationError {
            switch asError.code {
            case .canceled: mapped = .cancelled
            case .failed: mapped = .providerInternal("Apple auth failed")
            case .invalidResponse: mapped = .providerInternal("Apple invalid response")
            case .notHandled: mapped = .providerInternal("Apple not handled")
            case .unknown: mapped = .providerInternal("Apple unknown error")
            @unknown default: mapped = .providerInternal("Apple unmapped error: \(asError.code.rawValue)")
            }
        } else {
            mapped = .providerInternal(error.localizedDescription)
        }
        continuation?.resume(throwing: mapped)
        continuation = nil
    }

    private func release() {
        retainedController = nil
        retainedPresenter = nil
    }
}

private final class AppleAuthPresenter: NSObject, ASAuthorizationControllerPresentationContextProviding {
    private let context: ProviderPresentationContext

    init(context: ProviderPresentationContext) {
        self.context = context
        super.init()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        #if canImport(UIKit) && !os(watchOS)
        if let window = context.viewController?.view.window {
            return window
        }
        return Self.firstActiveWindow()
        #elseif canImport(AppKit)
        if let window = context.window {
            return window
        }
        return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    private static func firstActiveWindow() -> UIWindow {
        let scenes = UIApplication.shared.connectedScenes
        for scene in scenes {
            if let windowScene = scene as? UIWindowScene,
               scene.activationState == .foregroundActive
            {
                if let key = windowScene.windows.first(where: { $0.isKeyWindow }) {
                    return key
                }
                if let any = windowScene.windows.first {
                    return any
                }
            }
        }
        return UIWindow()
    }
    #endif
}
#endif
