import Foundation

public enum AuthProvider: String, Sendable, Equatable, CaseIterable, Codable {
    case apple
    case google
    case magicLink = "magic-link"
}

extension AuthProvider {
    init(social: SocialProvider) {
        switch social {
        case .apple: self = .apple
        case .google: self = .google
        }
    }
}
