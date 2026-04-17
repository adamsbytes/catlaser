import Foundation

public actor AuthCoordinator {
    private let client: AuthClient
    private let store: any BearerTokenStore
    private let nonceGenerator: NonceGenerator
    private let appleProvider: (any AppleIDTokenProviding)?
    private let googleProvider: (any GoogleIDTokenProviding)?
    private let fingerprintProvider: (any DeviceFingerprintProviding)?
    private let magicLinkCallbackURL: String?

    public init(
        client: AuthClient,
        store: any BearerTokenStore,
        nonceGenerator: NonceGenerator = NonceGenerator(),
        appleProvider: (any AppleIDTokenProviding)? = nil,
        googleProvider: (any GoogleIDTokenProviding)? = nil,
        fingerprintProvider: (any DeviceFingerprintProviding)? = nil,
        magicLinkCallbackURL: String? = nil,
    ) {
        self.client = client
        self.store = store
        self.nonceGenerator = nonceGenerator
        self.appleProvider = appleProvider
        self.googleProvider = googleProvider
        self.fingerprintProvider = fingerprintProvider
        self.magicLinkCallbackURL = magicLinkCallbackURL
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

    /// Kick off a magic-link sign-in. Captures the current device fingerprint
    /// and posts it (together with the email) to the coordination server,
    /// which sends a link to the user's inbox. Completion happens in
    /// `completeMagicLink(url:)` when the user taps the email.
    public func requestMagicLink(email: String) async throws {
        guard let fingerprintProvider else {
            throw AuthError.providerUnavailable("Magic link provider not configured")
        }
        let header = try await fingerprintProvider.currentFingerprintHeader()
        try await client.requestMagicLink(
            email: email,
            callbackURL: magicLinkCallbackURL,
            fingerprintHeader: header,
        )
    }

    /// Complete a magic-link sign-in from a Universal Link callback. Parses
    /// the URL, re-captures the current fingerprint (which must still match
    /// the server's stored copy to pass phishing defence), exchanges for a
    /// bearer token, and persists the session.
    public func completeMagicLink(url: URL) async throws -> AuthSession {
        guard let fingerprintProvider else {
            throw AuthError.providerUnavailable("Magic link provider not configured")
        }
        let callback = try MagicLinkCallback(url: url, config: client.config)
        let header = try await fingerprintProvider.currentFingerprintHeader()
        let session = try await client.completeMagicLink(
            token: callback.token,
            fingerprintHeader: header,
        )
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
