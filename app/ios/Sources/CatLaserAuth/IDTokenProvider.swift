import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct ProviderIDToken: Sendable, Equatable {
    public let token: String
    public let rawNonce: String?
    public let accessToken: String?

    public init(token: String, rawNonce: String? = nil, accessToken: String? = nil) {
        self.token = token
        self.rawNonce = rawNonce
        self.accessToken = accessToken
    }

    func asSocial() -> SocialIDToken {
        SocialIDToken(token: token, rawNonce: rawNonce, accessToken: accessToken)
    }
}

public struct ProviderPresentationContext: @unchecked Sendable {
    #if canImport(UIKit) && !os(watchOS)
    public let viewController: UIViewController?

    public init(viewController: UIViewController?) {
        self.viewController = viewController
    }
    #elseif canImport(AppKit)
    public let window: NSWindow?

    public init(window: NSWindow?) {
        self.window = window
    }
    #else
    public init() {}
    #endif
}

public protocol AppleIDTokenProviding: Sendable {
    func requestIDToken(
        nonceHash: String,
        context: ProviderPresentationContext,
    ) async throws -> ProviderIDToken
}

public protocol GoogleIDTokenProviding: Sendable {
    func requestIDToken(
        rawNonce: String,
        context: ProviderPresentationContext,
    ) async throws -> ProviderIDToken
}
