#if canImport(LocalAuthentication) && canImport(Darwin)
import Foundation
import LocalAuthentication

/// Policy + state machine for gating bearer-token access behind biometric
/// (or device-passcode) authentication.
///
/// The gate tracks a single piece of state: `lastAuthenticatedAt`. It does
/// **not** cache `LAContext` instances — an `LAContext`'s authenticated
/// state is only reliably reusable for a keychain read within a few
/// seconds of `evaluatePolicy` returning, so any longer-lived reuse would
/// silently degrade into a surprise re-prompt. The durable cache lives one
/// layer up, in `GatedBearerTokenStore`, which stores the decoded token in
/// memory for the duration of the idle window and only contacts the gate
/// + the keychain when the cache is cold.
///
/// Two entry points:
///
/// * **`authenticate(reason:)`** — always prompts, returns the fresh
///   `LAContext` for the caller to thread into exactly one immediate
///   keychain read. Marks the gate fresh.
///
/// * **`requireStrict(reason:)`** — same as `authenticate`. Separate name
///   so call-site intent is self-documenting at high-sensitivity surfaces
///   (live video, treat dispense). Also marks the gate fresh.
///
/// `isFresh()` is a pure read of `lastAuthenticatedAt` used by the bearer
/// store to decide whether the memory-cached token is still valid without
/// re-asking the user.
///
/// The evaluation policy is `.deviceOwnerAuthentication`, which is
/// biometric with passcode fallback. The gate does not fall back to a
/// weaker policy when biometric enrollment is missing — if the device
/// owner has no passcode at all, the gate throws `biometricUnavailable`
/// and refuses to hand out a context. For a product that streams live
/// video of someone's home, a device with no authentication configured
/// must never be trusted with a bearer token.
public actor SessionAccessGate {
    /// Default idle window between biometric prompts during normal use.
    public static let defaultIdleTimeout: TimeInterval = 15 * 60

    /// Evaluation policy. `.deviceOwnerAuthentication` accepts biometric or
    /// device passcode; `.biometricOnly` rejects passcode fallback.
    public enum Policy: Sendable {
        case deviceOwnerAuthentication
        case biometricOnly

        var laPolicy: LAPolicy {
            switch self {
            case .deviceOwnerAuthentication: .deviceOwnerAuthentication
            case .biometricOnly: .deviceOwnerAuthenticationWithBiometrics
            }
        }
    }

    public let idleTimeout: TimeInterval
    public let policy: Policy

    private let clock: @Sendable () -> Date
    private let evaluator: @Sendable (_ reason: String, _ policy: LAPolicy, _ context: LAContext) async throws -> Void
    private let contextFactory: @Sendable () -> LAContext

    private var lastAuthenticatedAt: Date?

    public init(
        idleTimeout: TimeInterval = SessionAccessGate.defaultIdleTimeout,
        policy: Policy = .deviceOwnerAuthentication,
    ) {
        self.init(
            idleTimeout: idleTimeout,
            policy: policy,
            clock: { Date() },
            contextFactory: { LAContext() },
            evaluator: SessionAccessGate.defaultEvaluator,
        )
    }

    init(
        idleTimeout: TimeInterval,
        policy: Policy,
        clock: @escaping @Sendable () -> Date,
        contextFactory: @escaping @Sendable () -> LAContext,
        evaluator: @escaping @Sendable (_ reason: String, _ policy: LAPolicy, _ context: LAContext) async throws -> Void,
    ) {
        precondition(idleTimeout >= 0, "idleTimeout must be non-negative")
        self.idleTimeout = idleTimeout
        self.policy = policy
        self.clock = clock
        self.contextFactory = contextFactory
        self.evaluator = evaluator
    }

    /// True if `authenticate` or `requireStrict` succeeded within
    /// `idleTimeout` from now. Used by the bearer store to decide whether
    /// the in-memory token is still valid.
    public func isFresh() -> Bool {
        guard let last = lastAuthenticatedAt else { return false }
        return clock().timeIntervalSince(last) < idleTimeout
    }

    /// Prompt the user and return an authenticated `LAContext`. Marks the
    /// gate fresh on success. The returned context must be used
    /// immediately for the one keychain read that triggered this call —
    /// do not cache it across the idle window.
    public func authenticate(reason: String) async throws -> LAContext {
        let context = contextFactory()
        do {
            try await evaluator(reason, policy.laPolicy, context)
        } catch let error as AuthError {
            throw error
        } catch let error as LAError {
            throw Self.map(error)
        } catch {
            throw AuthError.biometricFailed(status: Int32(kLAErrorSystemCancel))
        }
        lastAuthenticatedAt = clock()
        return context
    }

    /// Strict re-auth for high-sensitivity actions. Always prompts;
    /// identical to `authenticate` but with a distinct name so call-site
    /// intent is self-documenting.
    public func requireStrict(reason: String) async throws -> LAContext {
        try await authenticate(reason: reason)
    }

    /// Mark the gate fresh without prompting. Called after a successful
    /// identity-provider sign-in, because the user just authenticated with
    /// Apple/Google/magic-link and re-prompting for biometrics immediately
    /// after would be noise.
    public func markFresh() {
        lastAuthenticatedAt = clock()
    }

    /// Clear freshness. Next call to `authenticate`/`requireStrict` will
    /// prompt. Call on app background, explicit sign-out, or tamper.
    public func invalidate() {
        lastAuthenticatedAt = nil
    }

    private static let defaultEvaluator: @Sendable (String, LAPolicy, LAContext) async throws -> Void = { reason, policy, context in
        var policyError: NSError?
        guard context.canEvaluatePolicy(policy, error: &policyError) else {
            if let policyError {
                let code = policyError.code
                if code == LAError.passcodeNotSet.rawValue
                    || code == LAError.biometryNotAvailable.rawValue
                    || code == LAError.biometryNotEnrolled.rawValue
                {
                    throw AuthError.biometricUnavailable("LAError \(code): \(policyError.localizedDescription)")
                }
                throw AuthError.biometricFailed(status: Int32(code))
            }
            throw AuthError.biometricUnavailable("canEvaluatePolicy returned false")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.evaluatePolicy(policy, localizedReason: reason) { success, error in
                if success {
                    continuation.resume(returning: ())
                    return
                }
                if let laError = error as? LAError {
                    continuation.resume(throwing: SessionAccessGate.map(laError))
                } else if let nsError = error as NSError? {
                    continuation.resume(throwing: AuthError.biometricFailed(status: Int32(nsError.code)))
                } else {
                    continuation.resume(throwing: AuthError.biometricFailed(status: Int32(kLAErrorAuthenticationFailed)))
                }
            }
        }
    }

    static func map(_ error: LAError) -> AuthError {
        switch error.code {
        case .userCancel, .appCancel, .systemCancel:
            return .cancelled
        case .passcodeNotSet, .biometryNotAvailable, .biometryNotEnrolled:
            return .biometricUnavailable("LAError \(error.code.rawValue): \(error.localizedDescription)")
        default:
            return .biometricFailed(status: Int32(error.code.rawValue))
        }
    }
}

#endif
