import Foundation

/// Two independent one-shot flags that drive the post-pair tour and
/// the Schedule-tab first-run hint. Independence is deliberate: a
/// user who saw the tabs tour but closed the schedule hint before
/// tapping Schedule should still see the hint on their first real
/// Schedule visit. Collapsing the two into a single "onboarded" flag
/// would forfeit that nudge.
public struct OnboardingTourState: Sendable, Codable, Equatable {
    /// Whether the four-tab coach-mark overlay has been seen. Read
    /// by ``PairedShell`` on first ``MainTabView`` mount.
    public var hasSeenTabsTour: Bool
    /// Whether the Schedule first-run hint banner has been dismissed.
    /// Read by ``ScheduleView`` on ``.task`` entry.
    public var hasSeenScheduleHint: Bool

    public init(
        hasSeenTabsTour: Bool = false,
        hasSeenScheduleHint: Bool = false,
    ) {
        self.hasSeenTabsTour = hasSeenTabsTour
        self.hasSeenScheduleHint = hasSeenScheduleHint
    }
}

public protocol OnboardingTourStore: Sendable {
    func load() async -> OnboardingTourState
    func save(_ state: OnboardingTourState) async
    func markTabsTourSeen() async
    func markScheduleHintSeen() async
}

/// Production store. Versioned UserDefaults key — bump the suffix to
/// re-surface the tour after a schema change.
public final class UserDefaultsOnboardingTourStore:
    OnboardingTourStore,
    @unchecked Sendable
{
    public static let storageKey = "com.catlaser.onboarding.tour.v1"

    private let defaults: UserDefaults

    public init(suiteName: String? = nil) {
        self.defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public func load() async -> OnboardingTourState {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return OnboardingTourState()
        }
        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode(OnboardingTourState.self, from: data) else {
            return OnboardingTourState()
        }
        return decoded
    }

    public func save(_ state: OnboardingTourState) async {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(state) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    public func markTabsTourSeen() async {
        var current = await load()
        guard !current.hasSeenTabsTour else { return }
        current.hasSeenTabsTour = true
        await save(current)
    }

    public func markScheduleHintSeen() async {
        var current = await load()
        guard !current.hasSeenScheduleHint else { return }
        current.hasSeenScheduleHint = true
        await save(current)
    }
}

/// In-memory store — tests + SPM Linux build.
public actor InMemoryOnboardingTourStore: OnboardingTourStore {
    private var state: OnboardingTourState

    public init(initial: OnboardingTourState = OnboardingTourState()) {
        self.state = initial
    }

    public func load() async -> OnboardingTourState {
        state
    }

    public func save(_ state: OnboardingTourState) async {
        self.state = state
    }

    public func markTabsTourSeen() async {
        state.hasSeenTabsTour = true
    }

    public func markScheduleHintSeen() async {
        state.hasSeenScheduleHint = true
    }
}
