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
    private var lifecycleObservers: [any SessionLifecycleObserver]

    public init(
        client: AuthClient,
        store: any BearerTokenStore,
        nonceGenerator: NonceGenerator = NonceGenerator(),
        appleProvider: (any AppleIDTokenProviding)? = nil,
        googleProvider: (any GoogleIDTokenProviding)? = nil,
        attestationProvider: (any DeviceAttestationProviding)? = nil,
        lifecycleObservers: [any SessionLifecycleObserver] = [],
    ) {
        self.init(
            client: client,
            store: store,
            nonceGenerator: nonceGenerator,
            appleProvider: appleProvider,
            googleProvider: googleProvider,
            attestationProvider: attestationProvider,
            lifecycleObservers: lifecycleObservers,
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
        lifecycleObservers: [any SessionLifecycleObserver] = [],
        clock: @escaping @Sendable () -> Date,
    ) {
        self.client = client
        self.store = store
        self.nonceGenerator = nonceGenerator
        self.appleProvider = appleProvider
        self.googleProvider = googleProvider
        self.attestationProvider = attestationProvider
        self.clock = clock
        self.lifecycleObservers = lifecycleObservers
    }

    /// Register a `SessionLifecycleObserver` at runtime. Observers
    /// added this way are notified on the next `signOut()` call in
    /// registration order, after any observers passed at init time.
    /// Registration is idempotent only at the identity level —
    /// registering the same instance twice causes two notifications.
    public func addLifecycleObserver(_ observer: any SessionLifecycleObserver) {
        lifecycleObservers.append(observer)
    }

    public func currentSession() async throws -> AuthSession? {
        try await store.load()
    }

    /// Handle an HTTP 401 observed on a downstream protected call.
    ///
    /// The signed HTTP client wrapper calls this (via the
    /// `onSessionExpired` callback threaded in at construction time)
    /// whenever the coordination server rejects a bearer with 401.
    /// The response is:
    ///
    /// * Invalidate the in-memory bearer cache so the next protected
    ///   call prompts the user to re-authenticate instead of reusing
    ///   the already-rejected token. The persistent keychain row is
    ///   intentionally left alone — the token is still valid at rest;
    ///   it is just no longer accepted by the server, and the correct
    ///   remediation is a fresh sign-in, not destruction of the
    ///   stored material.
    /// * Notify every lifecycle observer via `sessionDidExpire()`.
    ///   Observers with no `sessionDidExpire` override (e.g., the
    ///   pairing endpoint store) take the default no-op, so a 401 in
    ///   the middle of a paired-devices re-verification does NOT
    ///   clobber the keychain-held pairing. Observers that care about
    ///   re-auth UX (the app-level coordinator) override the hook.
    ///
    /// Idempotent and safe to call from any thread that can reach the
    /// actor; the in-memory cache invalidation + observer notification
    /// are serialised through the actor's isolation domain.
    public func handleSessionExpired() async {
        if let invalidator = store as? SessionInvalidating {
            await invalidator.invalidateSession()
        }
        for observer in lifecycleObservers {
            await observer.sessionDidExpire()
        }
    }

    /// Apple sign-in. The flow commits a SHA-256-hashed nonce in the
    /// authorization request, receives an ID token whose `nonce` claim
    /// must match that hash, and posts the raw nonce to the server so it
    /// can re-hash and re-verify. A SE-backed attestation binds the
    /// token exchange to the device: its `bnd` is
    /// `"sis:<unix_seconds>:<rawNonce>"` and the signed ECDSA message
    /// spans `fph_raw || bnd_utf8`. A captured `(body, attestation)`
    /// pair cannot be replayed outside the server's ±60s skew window
    /// even within the Apple ID-token's own validity period.
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
        let timestamp = try plausibleRequestTimestamp()
        let header = try await attestationProvider.currentAttestationHeader(
            binding: .social(timestamp: timestamp, rawNonce: nonce.raw),
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
    /// whose `bnd` is `"sis:<unix_seconds>:<rawNonce>"`. Server-side
    /// binding + ±60s skew on the timestamp + nonce/body three-way match
    /// make replay-from-elsewhere, replay-on-same-device, and
    /// capture-then-delay replay all structurally blocked.
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
        let timestamp = try plausibleRequestTimestamp()
        let header = try await attestationProvider.currentAttestationHeader(
            binding: .social(timestamp: timestamp, rawNonce: nonce.raw),
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
        let timestamp = try plausibleRequestTimestamp()
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

    /// Complete a magic-link sign-in via the 6-digit backup code shown
    /// beneath the tap link in the email. Used on the same phone that
    /// requested the link when the user's mail landed on a different
    /// device — they read the code, type it here, and the server
    /// redeems it against the SE key the request-time attestation
    /// bound to.
    ///
    /// The attestation uses the same `.verify(token:)` binding shape as
    /// the URL path, with the 6-digit code playing the token role. The
    /// server rejects any divergence between the attestation binding
    /// and the body code, so a captured ``.verify(token:)`` attestation
    /// from the URL path cannot be relayed here (the binding would
    /// sign a different string).
    public func completeMagicLink(code: BackupCode) async throws -> AuthSession {
        guard let attestationProvider else {
            throw AuthError.providerUnavailable("Magic link provider not configured")
        }
        let header = try await attestationProvider.currentAttestationHeader(
            binding: .verify(token: code.canonical),
        )
        let session = try await client.completeMagicLinkByCode(
            code: code.canonical,
            attestationHeader: header,
        )
        try await store.save(session)
        return session
    }

    /// Revoke the session without ever prompting the user.
    ///
    /// Sign-out uses only the session already cached in memory. Reaching
    /// into the keychain to satisfy an OS-level `.userPresence` ACL
    /// would fire a biometric prompt — a UX trap when the user's
    /// intent is to *stop* using the app. If the cache is cold (app was
    /// just launched, scene was backgrounded and the session
    /// invalidated, etc.) the server call is skipped entirely; local
    /// session material is always cleared, and the bearer token expires
    /// naturally server-side.
    ///
    /// When the cache is warm, the outbound revocation carries a fresh
    /// `x-device-attestation` header bound to the current wall-clock
    /// second (`bnd = "out:<unix_seconds>"`). This turns sign-out into
    /// a cryptographically authenticated call — a leaked bearer token
    /// alone cannot revoke the session; the caller must also produce a
    /// fresh ECDSA signature under the original Secure-Enclave key.
    /// Local state is still wiped even if the server call fails.
    public func signOut() async throws {
        let cachedSession = await store.cachedSession()
        guard let cachedSession else {
            try await store.delete()
            await notifyLifecycleObservers()
            return
        }
        guard let attestationProvider else {
            // Misconfiguration: we hold a session to revoke but cannot
            // sign an attestation for the server call. Fail the
            // operation explicitly, but still wipe local state —
            // otherwise the device is stuck holding a bearer with no
            // working path to revoke it. The orphaned server-side
            // bearer will expire naturally. Observers still fire so
            // dependent modules (endpoint store, push registration)
            // clean up even on a half-broken sign-out.
            try await store.delete()
            await notifyLifecycleObservers()
            throw AuthError.providerUnavailable("Sign-out provider not configured")
        }
        let header: String
        do {
            let timestamp = try plausibleRequestTimestamp()
            header = try await attestationProvider.currentAttestationHeader(
                binding: .signOut(timestamp: timestamp),
            )
        } catch {
            try await store.delete()
            await notifyLifecycleObservers()
            throw error
        }
        do {
            try await client.signOut(session: cachedSession, attestationHeader: header)
        } catch {
            try await store.delete()
            await notifyLifecycleObservers()
            throw error
        }
        try await store.delete()
        await notifyLifecycleObservers()
    }

    /// Permanently delete the user's account on the coordination
    /// server, then wipe every locally-persisted session artefact and
    /// notify lifecycle observers so the host returns to sign-in.
    ///
    /// Differences from ``signOut``:
    ///
    /// * Uses the ``.deleteAccount(timestamp:)`` binding (wire tag
    ///   ``del:``) so a captured sign-out or protected-route
    ///   attestation cannot be replayed at the delete-account
    ///   endpoint.
    /// * Does NOT pre-emptively wipe local state on a failed server
    ///   call. A network blip that fails deletion leaves the session
    ///   intact so the user can retry — wiping credentials after a
    ///   failed server call would leave a half-deleted state where
    ///   the server still holds the account but the device has lost
    ///   the credentials needed to retry.
    /// * Refuses to proceed without a warm in-memory session cache.
    ///   Reaching into the keychain to hydrate a cold cache would
    ///   require the OS-level ``userPresence`` ACL prompt, which is
    ///   the wrong UX inside an explicit destructive confirmation
    ///   that the user just tapped through — the OS prompt would
    ///   land on top of the confirmation and confuse "are you sure"
    ///   with "who are you". Returning ``missingBearerToken`` tells
    ///   the UI to unwind to sign-in first.
    public func deleteAccount() async throws {
        let cachedSession = await store.cachedSession()
        guard let cachedSession else {
            throw AuthError.missingBearerToken
        }
        guard let attestationProvider else {
            throw AuthError.providerUnavailable("Delete-account provider not configured")
        }
        let timestamp = try plausibleRequestTimestamp()
        let header = try await attestationProvider.currentAttestationHeader(
            binding: .deleteAccount(timestamp: timestamp),
        )
        try await client.deleteAccount(session: cachedSession, attestationHeader: header)
        // Server call landed — the account is gone. Wipe local
        // credentials and fire the same lifecycle observers that
        // sign-out does so the endpoint store, push registrar, and
        // observability sink all clean up. The observer protocol has
        // only ``sessionDidSignOut`` and ``sessionDidExpire``; treat
        // post-delete as a sign-out for cleanup purposes since the
        // downstream wipes (Keychain endpoint row, APNs unregister,
        // telemetry purge) are identical. A dedicated "account
        // deleted" hook would let observers draw a different banner,
        // but the actual work is the same either way.
        try await store.delete()
        await notifyLifecycleObservers()
    }

    /// Fire every registered observer in registration order. Observers
    /// cannot throw; any storage failure they encounter is their own
    /// problem to log. Sign-out itself is complete either way.
    private func notifyLifecycleObservers() async {
        for observer in lifecycleObservers {
            await observer.sessionDidSignOut()
        }
    }

    private func plausibleRequestTimestamp() throws(AuthError) -> Int64 {
        let timestamp = Int64(clock().timeIntervalSince1970)
        guard timestamp >= AuthCoordinator.minPlausibleRequestTimestamp,
              timestamp <= AuthCoordinator.maxPlausibleRequestTimestamp
        else {
            throw .attestationFailed(
                "system clock reports an implausible Unix-seconds value (\(timestamp));"
                    + " expected ["
                    + "\(AuthCoordinator.minPlausibleRequestTimestamp), "
                    + "\(AuthCoordinator.maxPlausibleRequestTimestamp)]",
            )
        }
        return timestamp
    }
}
