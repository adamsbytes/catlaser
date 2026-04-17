import Foundation

public enum SocialProvider: String, Sendable, Equatable, CaseIterable {
    case apple
    case google
}

public struct SocialIDToken: Sendable, Equatable {
    public let token: String
    public let rawNonce: String?
    public let accessToken: String?

    public init(token: String, rawNonce: String? = nil, accessToken: String? = nil) {
        self.token = token
        self.rawNonce = rawNonce
        self.accessToken = accessToken
    }
}

struct SocialSignInRequest: Encodable, Equatable {
    let provider: SocialProvider
    let idToken: EncodedIDToken

    struct EncodedIDToken: Encodable, Equatable {
        let token: String
        let nonce: String?
        let accessToken: String?

        enum CodingKeys: String, CodingKey {
            case token
            case nonce
            case accessToken
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(token, forKey: .token)
            try container.encodeIfPresent(nonce, forKey: .nonce)
            try container.encodeIfPresent(accessToken, forKey: .accessToken)
        }
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case idToken
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider.rawValue, forKey: .provider)
        try container.encode(idToken, forKey: .idToken)
    }

    init(provider: SocialProvider, idToken: SocialIDToken) {
        self.provider = provider
        self.idToken = EncodedIDToken(
            token: idToken.token,
            nonce: idToken.rawNonce,
            accessToken: idToken.accessToken,
        )
    }
}

public struct AuthUser: Sendable, Equatable, Codable {
    public let id: String
    public let email: String?
    public let name: String?
    public let image: String?
    public let emailVerified: Bool

    public init(
        id: String,
        email: String?,
        name: String?,
        image: String?,
        emailVerified: Bool,
    ) {
        self.id = id
        self.email = email
        self.name = name
        self.image = image
        self.emailVerified = emailVerified
    }

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case name
        case image
        case emailVerified
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        emailVerified = try c.decodeIfPresent(Bool.self, forKey: .emailVerified) ?? false
    }
}

struct SocialSignInResponse: Decodable, Equatable {
    let user: AuthUser
}

public struct AuthSession: Sendable, Equatable, Codable {
    public let bearerToken: String
    public let user: AuthUser
    public let provider: SocialProvider
    public let establishedAt: Date

    public init(
        bearerToken: String,
        user: AuthUser,
        provider: SocialProvider,
        establishedAt: Date,
    ) {
        self.bearerToken = bearerToken
        self.user = user
        self.provider = provider
        self.establishedAt = establishedAt
    }

    enum CodingKeys: String, CodingKey {
        case bearerToken
        case user
        case provider
        case establishedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bearerToken = try c.decode(String.self, forKey: .bearerToken)
        user = try c.decode(AuthUser.self, forKey: .user)
        let providerRaw = try c.decode(String.self, forKey: .provider)
        guard let parsed = SocialProvider(rawValue: providerRaw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .provider,
                in: c,
                debugDescription: "unknown provider: \(providerRaw)",
            )
        }
        provider = parsed
        establishedAt = try c.decode(Date.self, forKey: .establishedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bearerToken, forKey: .bearerToken)
        try c.encode(user, forKey: .user)
        try c.encode(provider.rawValue, forKey: .provider)
        try c.encode(establishedAt, forKey: .establishedAt)
    }
}
