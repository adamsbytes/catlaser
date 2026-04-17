import Foundation

public actor AuthCoordinator {
    private let client: AuthClient
    private let store: any BearerTokenStore
    private let nonceGenerator: NonceGenerator
    private let appleProvider: (any AppleIDTokenProviding)?
    private let googleProvider: (any GoogleIDTokenProviding)?

    public init(
        client: AuthClient,
        store: any BearerTokenStore,
        nonceGenerator: NonceGenerator = NonceGenerator(),
        appleProvider: (any AppleIDTokenProviding)? = nil,
        googleProvider: (any GoogleIDTokenProviding)? = nil,
    ) {
        self.client = client
        self.store = store
        self.nonceGenerator = nonceGenerator
        self.appleProvider = appleProvider
        self.googleProvider = googleProvider
    }

    public func currentSession() async throws -> AuthSession? {
        try await store.load()
    }

    public func signInWithApple(context: ProviderPresentationContext) async throws -> AuthSession {
        guard let provider = appleProvider else {
            throw AuthError.providerUnavailable("Apple provider not configured")
        }
        let nonce: Nonce
        do {
            nonce = try nonceGenerator.make()
        } catch {
            throw AuthError.providerInternal("nonce generation: \(error.localizedDescription)")
        }
        let providerToken = try await provider.requestIDToken(nonceHash: nonce.hashed, context: context)
        let idToken = SocialIDToken(
            token: providerToken.token,
            rawNonce: nonce.raw,
            accessToken: providerToken.accessToken,
        )
        let session = try await client.exchangeSocial(provider: .apple, idToken: idToken)
        try await store.save(session)
        return session
    }

    public func signInWithGoogle(context: ProviderPresentationContext) async throws -> AuthSession {
        guard let provider = googleProvider else {
            throw AuthError.providerUnavailable("Google provider not configured")
        }
        let providerToken = try await provider.requestIDToken(context: context)
        let idToken = SocialIDToken(
            token: providerToken.token,
            rawNonce: nil,
            accessToken: providerToken.accessToken,
        )
        let session = try await client.exchangeSocial(provider: .google, idToken: idToken)
        try await store.save(session)
        return session
    }

    public func signOut() async throws {
        let existing = try await store.load()
        if let existing {
            do {
                try await client.signOut(session: existing)
            } catch {
                try await store.delete()
                throw error
            }
        }
        try await store.delete()
    }
}
