import Foundation

public actor AuthCoordinator {
    /// Earliest plausible Unix-seconds value for a request-time binding.
    /// 2020-01-01 UTC — predates every iPhone the app supports, and well
    /// before this product existed. A device reporting a timestamp below
    /// this has a broken clock; emitting `req:<bogus>` would only serve
    /// to push the server's skew check off the near-now window, so the
    /// coordinator refuses to build an attestation at all.
    public static let minPlausibleRequestTimestamp: Int64 = 1_577_836_800

    /// Latest plausible Unix-seconds value for a request-time binding.
    /// 2100-01-01 UTC — more than seven decades out. A device reporting
    /// a timestamp beyond this has a deliberately or accidentally
    /// forward-set clock; signing for the far future lets an attacker
    /// who exfiltrates the header replay it indefinitely as the real
    /// clock catches up, which defeats the ~60s skew defence. Refuse.
    public static let maxPlausibleRequestTimestamp: Int64 = 4_102_444_800

    private let client: AuthClient
    private let store: any BearerTokenStore
    private let nonceGenerator: NonceGenerator
    private let appleProvider: (any AppleIDTokenProviding)?
    private let googleProvider: (any GoogleIDTokenProviding)?
    private let attestationProvider: (any DeviceAttestationProviding)?
    private let clock: @Sendable () -> Date

    public init(
        client: AuthClient,
        store: any BearerTokenStore,
        nonceGenerator: NonceGenerator = NonceGenerator(),
        appleProvider: (any AppleIDTokenProviding)? = nil,
        googleProvider: (any GoogleIDTokenProviding)? = nil,
        attestationProvider: (any DeviceAttestationProviding)? = nil,
    ) {
        self.init(
            client: client,
            store: store,
            nonceGenerator: nonceGenerator,
            appleProvider: appleProvider,
            googleProvider: googleProvider,
            attestationProvider: attestationProvider,
            clock: { Date() },
        )
    }

    init(
        client: AuthClient,
        store: any BearerTokenStore,
        nonceGenerator: NonceGenerator = NonceGenerator(),
        appleProvider: (any AppleIDTokenProviding)? = nil,
        googleProvider: (any GoogleIDTokenProviding)? = nil,
        attestationProvider: (any DeviceAttestationProviding)? = nil,
        clock: @escaping @Sendable () -> Date,
    ) {
        self.client = client
        self.store = store
        self.nonceGenerator = nonceGenerator
        self.appleProvider = appleProvider
        self.googleProvider = googleProvider
        self.attestationProvider = attestationProvider
        self.clock = clock
    }

    public func currentSession() async throws -> AuthSession? {
        try await store.load()
    }

    /// Apple sign-in. The flow commits a SHA-256-hashed nonce in the
    /// authorization request, receives an ID token whose `nonce` claim
    /// must match that hash, and posts the raw nonce to the server so it
    /// can re-hash and re-verify. A SE-backed attestation binds the
    /// token exchange to the device: its `bnd` is `"sis:<rawNonce>"` and
    /// the signed ECDSA message spans `fph_raw || bnd_utf8`. A captured
    /// attestation cannot be replayed — the server treats the nonce as
    /// single-use and the SE private key never leaves the device.
    public func signInWithApple(context: ProviderPresentationContext) async throws -> AuthSession {
        guard let provider = appleProvider else {
            throw AuthError.providerUnavailable("Apple provider not configured")
        }
        guard let attestationProvider else {
            throw AuthError.providerUnavailable("Attestation provider not configured")
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
        let header = try await attestationProvider.currentAttestationHeader(
            binding: .social(rawNonce: nonce.raw),
        )
        let session = try await client.exchangeSocial(
            provider: .apple,
            idToken: idToken,
            attestationHeader: header,
        )
        try await store.save(session)
        return session
    }

    /// Google sign-in. The Authorization Code + PKCE flow pre-commits a
    /// raw nonce (echoed verbatim in the ID token's `nonce` claim), and
    /// the subsequent token exchange carries a SE-backed attestation
    /// whose `bnd` is `"sis:<rawNonce>"`. Server-side binding + single-use
    /// nonce handling make both replay-from-elsewhere and
    /// replay-on-same-device structurally impossible.
    public func signInWithGoogle(context: ProviderPresentationContext) async throws -> AuthSession {
        guard let provider = googleProvider else {
            throw AuthError.providerUnavailable("Google provider not configured")
        }
        guard let attestationProvider else {
            throw AuthError.providerUnavailable("Attestation provider not configured")
        }
        let nonce: Nonce
        do {
            nonce = try nonceGenerator.make()
        } catch {
            throw AuthError.providerInternal("nonce generation: \(error.localizedDescription)")
        }
        let providerToken = try await provider.requestIDToken(rawNonce: nonce.raw, context: context)
        let idToken = SocialIDToken(
            token: providerToken.token,
            rawNonce: nonce.raw,
            accessToken: providerToken.accessToken,
        )
        let header = try await attestationProvider.currentAttestationHeader(
            binding: .social(rawNonce: nonce.raw),
        )
        let session = try await client.exchangeSocial(
            provider: .google,
            idToken: idToken,
            attestationHeader: header,
        )
        try await store.save(session)
        return session
    }

    /// Kick off a magic-link sign-in. Builds a signed device attestation
    /// bound to the current wall-clock second and posts it (with the
    /// email) to the coordination server, which sends a link to the
    /// user's inbox. The timestamp binding limits replay of a captured
    /// header to the server's skew window (~60s). Completion happens in
    /// `completeMagicLink(url:)` when the user taps the email.
    public func requestMagicLink(email: String) async throws {
        guard let attestationProvider else {
            throw AuthError.providerUnavailable("Magic link provider not configured")
        }
        let timestamp = Int64(clock().timeIntervalSince1970)
        guard timestamp >= AuthCoordinator.minPlausibleRequestTimestamp,
              timestamp <= AuthCoordinator.maxPlausibleRequestTimestamp
        else {
            throw AuthError.attestationFailed(
                "system clock reports an implausible Unix-seconds value (\(timestamp));"
                    + " expected ["
                    + "\(AuthCoordinator.minPlausibleRequestTimestamp), "
                    + "\(AuthCoordinator.maxPlausibleRequestTimestamp)]",
            )
        }
        let header = try await attestationProvider.currentAttestationHeader(
            binding: .request(timestamp: timestamp),
        )
        try await client.requestMagicLink(
            email: email,
            attestationHeader: header,
        )
    }

    /// Complete a magic-link sign-in from a Universal Link callback.
    /// Parses the URL, rebuilds a fresh attestation bound to the magic-
    /// link token (whose `fph` and `pk` must still byte-match the
    /// server's stored copy), exchanges for a bearer token, and persists
    /// the session. Binding the signature to the token means a request-
    /// time attestation cannot be replayed here — the signed bytes
    /// differ — nor can this attestation be re-used with any other
    /// token.
    public func completeMagicLink(url: URL) async throws -> AuthSession {
        guard let attestationProvider else {
            throw AuthError.providerUnavailable("Magic link provider not configured")
        }
        let callback = try MagicLinkCallback(url: url, config: client.config)
        let header = try await attestationProvider.currentAttestationHeader(
            binding: .verify(token: callback.token),
        )
        let session = try await client.completeMagicLink(
            token: callback.token,
            attestationHeader: header,
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
