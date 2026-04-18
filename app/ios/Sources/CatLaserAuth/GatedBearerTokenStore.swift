#if canImport(LocalAuthentication) && canImport(Security) && canImport(Darwin)
import Foundation
import LocalAuthentication

/// `BearerTokenStore` that layers a biometric gate and an in-memory idle
/// cache over a `KeychainBearerTokenStore`.
///
/// Behaviour:
///
/// * `save` writes through to the keychain (the underlying store's
///   `.userPresence` policy wraps the keychain item in a hardware
///   access-control that requires biometric *or* device-passcode auth on
///   every subsequent read). The freshly-saved session is also placed in
///   the memory cache and the gate is marked fresh — a user who just
///   finished identity-provider sign-in must not be immediately
///   re-prompted for biometrics.
///
/// * `load` returns the cached session without prompting *only* if both
///   the memory cache is populated *and* the gate is fresh. Otherwise it
///   prompts the user (biometric + passcode fallback), threads the
///   resulting authenticated `LAContext` into the keychain read so the
///   OS-level ACL is satisfied without a second prompt, refills the
///   cache, and returns.
///
/// * `requireLiveVideo` is a hard gate: always prompts, regardless of
///   freshness. Use before initiating any video stream or other
///   high-sensitivity action. Does not return the session (callers
///   already hold it from a prior `load`).
///
/// * `delete` clears the memory cache and invalidates the gate before
///   removing the keychain item. A stolen, already-unlocked phone cannot
///   recover the token immediately after sign-out.
///
/// * `invalidateSession` is a soft reset: drops memory cache and gate
///   freshness without touching the keychain. Intended for app-lifecycle
///   hooks (`scenePhase == .background`, tamper signals).
public actor GatedBearerTokenStore: BearerTokenStore, SessionInvalidating {
    private let underlying: any AuthenticatingBearerTokenStore
    private let gate: SessionAccessGate
    private let unlockReason: String
    private let liveVideoReason: String

    private var cached: AuthSession?

    public init(
        underlying: any AuthenticatingBearerTokenStore,
        gate: SessionAccessGate,
        unlockReason: String = "Unlock your Catlaser session",
        liveVideoReason: String = "Confirm to view live video",
    ) {
        self.underlying = underlying
        self.gate = gate
        self.unlockReason = unlockReason
        self.liveVideoReason = liveVideoReason
    }

    public func save(_ session: AuthSession) async throws {
        try await underlying.save(session)
        cached = session
        await gate.markFresh()
    }

    public func load() async throws -> AuthSession? {
        if let cached, await gate.isFresh() {
            return cached
        }
        let context = try await gate.authenticate(reason: unlockReason)
        let session = try await underlying.load(authenticatedWith: context)
        cached = session
        return session
    }

    /// Returns the in-memory cached session without prompting, without
    /// checking gate freshness, and without reading the keychain.
    /// Returns nil whenever the cache is cold — the caller must treat
    /// nil as "no session available without a prompt," *not* "no
    /// session exists." Used by `AuthCoordinator.signOut` so revoking
    /// a session never triggers a biometric UI.
    public func cachedSession() async -> AuthSession? {
        cached
    }

    public func delete() async throws {
        cached = nil
        await gate.invalidate()
        try await underlying.delete()
    }

    /// Hard re-authentication gate for high-sensitivity actions. Always
    /// prompts, even if the ordinary idle window is still fresh. Throws on
    /// user cancellation or auth failure — the caller must refuse to
    /// initiate the protected action.
    public func requireLiveVideo() async throws {
        _ = try await gate.requireStrict(reason: liveVideoReason)
    }

    /// Drop the in-memory token cache and gate freshness. Next `load`
    /// will prompt. Does not touch the keychain.
    public func invalidateSession() async {
        cached = nil
        await gate.invalidate()
    }
}

#endif
