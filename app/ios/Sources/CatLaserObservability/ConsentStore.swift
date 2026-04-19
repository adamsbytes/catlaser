import Foundation

/// Persistent consent state for the observability pipeline.
///
/// Consent is modelled as an enum rather than two independent
/// booleans so the "not yet asked" state (first launch) has a real
/// identity — the consent screen reads it, and the uploader silently
/// no-ops against it. The concrete defaults mean every pipeline path
/// is default-deny until the user explicitly chooses: a failure to
/// present the consent screen leaves the app as if the user had
/// declined, which is the safer posture.
public enum ConsentState: Sendable, Codable, Equatable {
    /// First launch — user has not seen the consent screen yet.
    case notAsked
    /// User explicitly declined both.
    case declined
    /// User opted in. Each toggle is tracked separately so "crash
    /// reports yes, product telemetry no" is a first-class choice.
    case granted(crashReporting: Bool, telemetry: Bool)

    /// Effective crash-reporting state. `.notAsked` and `.declined`
    /// both evaluate to `false`.
    public var crashReportingEnabled: Bool {
        if case let .granted(crash, _) = self { return crash }
        return false
    }

    /// Effective telemetry state. `.notAsked` and `.declined` both
    /// evaluate to `false`.
    public var telemetryEnabled: Bool {
        if case let .granted(_, telemetry) = self { return telemetry }
        return false
    }

    /// Whether the consent screen should be presented.
    public var needsPrompt: Bool {
        if case .notAsked = self { return true }
        return false
    }
}

/// Abstracts the persistent store so tests can swap in an in-memory
/// double and production binds to ``UserDefaultsConsentStore``.
public protocol ConsentStore: Sendable {
    func load() async -> ConsentState
    func save(_ state: ConsentState) async
}

/// Production consent store. Persists in ``UserDefaults`` under a
/// versioned key — a schema change bumps the key so an upgrade can
/// re-prompt the user rather than silently re-interpret a rewritten
/// enum case layout.
public final class UserDefaultsConsentStore: ConsentStore, @unchecked Sendable {
    /// Versioned UserDefaults key. Bump the suffix to force a
    /// re-prompt after a schema change.
    public static let storageKey = "com.catlaser.observability.consent.v1"

    private let defaults: UserDefaults

    public init(suiteName: String? = nil) {
        self.defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public func load() async -> ConsentState {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return .notAsked
        }
        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode(ConsentState.self, from: data) else {
            // A malformed value (rare; only happens across aborted
            // schema changes) is treated as a fresh install so the
            // user is prompted again and the record is rewritten.
            return .notAsked
        }
        return decoded
    }

    public func save(_ state: ConsentState) async {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(state) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

/// In-memory consent store — used by tests and by the SPM Linux
/// build where no Darwin ``UserDefaults`` is available for the
/// composition invariants suite.
public actor InMemoryConsentStore: ConsentStore {
    private var state: ConsentState

    public init(initial: ConsentState = .notAsked) {
        self.state = initial
    }

    public func load() async -> ConsentState {
        state
    }

    public func save(_ state: ConsentState) async {
        self.state = state
    }
}
