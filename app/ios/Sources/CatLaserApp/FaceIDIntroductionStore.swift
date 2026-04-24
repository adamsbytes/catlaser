import Foundation

/// Persistent flag that drives the Face ID / passcode onboarding
/// card. The card is shown ONCE per install — after the user taps
/// "Got it" or "Continue anyway" we flip the flag and never show it
/// again. Follows the same versioned-key pattern
/// ``UserDefaultsConsentStore`` uses so a schema change can re-prompt
/// users by bumping the suffix.
public enum FaceIDIntroductionState: Sendable, Codable, Equatable {
    /// First launch after consent — card has not been shown.
    case notSeen
    /// User has seen and dismissed the card.
    case seen

    /// Whether the onboarding card should be presented.
    public var needsPrompt: Bool {
        if case .notSeen = self { return true }
        return false
    }
}

/// Abstracts the persistent store so tests can swap in an in-memory
/// double and production binds to ``UserDefaultsFaceIDIntroductionStore``.
public protocol FaceIDIntroductionStore: Sendable {
    func load() async -> FaceIDIntroductionState
    func save(_ state: FaceIDIntroductionState) async
}

/// Production store. Persists in ``UserDefaults`` under a versioned
/// key — bumping the suffix forces a re-prompt on the next install.
public final class UserDefaultsFaceIDIntroductionStore:
    FaceIDIntroductionStore,
    @unchecked Sendable
{
    public static let storageKey = "com.catlaser.onboarding.faceId.v1"

    private let defaults: UserDefaults

    public init(suiteName: String? = nil) {
        self.defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public func load() async -> FaceIDIntroductionState {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return .notSeen
        }
        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode(FaceIDIntroductionState.self, from: data) else {
            // A malformed value is treated as a fresh install so the
            // user is shown the card again and the record is rewritten.
            return .notSeen
        }
        return decoded
    }

    public func save(_ state: FaceIDIntroductionState) async {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(state) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

/// In-memory store — used by tests and by the SPM Linux build where
/// the composition invariants suite runs without ``UserDefaults``.
public actor InMemoryFaceIDIntroductionStore: FaceIDIntroductionStore {
    private var state: FaceIDIntroductionState

    public init(initial: FaceIDIntroductionState = .notSeen) {
        self.state = initial
    }

    public func load() async -> FaceIDIntroductionState {
        state
    }

    public func save(_ state: FaceIDIntroductionState) async {
        self.state = state
    }
}
