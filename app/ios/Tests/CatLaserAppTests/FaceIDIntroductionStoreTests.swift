import Foundation
import Testing

@testable import CatLaserApp

@Suite("FaceIDIntroductionStore")
struct FaceIDIntroductionStoreTests {
    @Test
    func freshStateNeedsPrompt() {
        #expect(FaceIDIntroductionState.notSeen.needsPrompt)
        #expect(!FaceIDIntroductionState.seen.needsPrompt)
    }

    @Test
    func inMemoryRoundTripsThroughSeen() async {
        let store = InMemoryFaceIDIntroductionStore()
        #expect(await store.load() == .notSeen)
        await store.save(.seen)
        #expect(await store.load() == .seen)
    }

    @Test
    func encodeIsVersionedCaseOnly() throws {
        // The persisted layout is a single codable enum with no
        // associated values. A schema drift that silently rewrote the
        // representation would break the versioned-key roll-forward
        // story — pin the JSON shape here so a refactor either updates
        // the test or bumps the storage-key suffix (which would force a
        // fresh prompt on every install).
        let seen = try JSONEncoder().encode(FaceIDIntroductionState.seen)
        let notSeen = try JSONEncoder().encode(FaceIDIntroductionState.notSeen)
        let seenString = try #require(String(data: seen, encoding: .utf8))
        let notSeenString = try #require(String(data: notSeen, encoding: .utf8))
        #expect(seenString.contains("seen"))
        #expect(notSeenString.contains("notSeen"))
    }
}

@Suite("OnboardingTourStore")
struct OnboardingTourStoreTests {
    @Test
    func freshStateHasBothFlagsFalse() {
        let state = OnboardingTourState()
        #expect(!state.hasSeenTabsTour)
        #expect(!state.hasSeenScheduleHint)
    }

    @Test
    func markingFlagsIsIndependent() async {
        let store = InMemoryOnboardingTourStore()
        await store.markTabsTourSeen()
        let afterTabs = await store.load()
        #expect(afterTabs.hasSeenTabsTour)
        #expect(!afterTabs.hasSeenScheduleHint)

        await store.markScheduleHintSeen()
        let afterBoth = await store.load()
        #expect(afterBoth.hasSeenTabsTour)
        #expect(afterBoth.hasSeenScheduleHint)
    }

    @Test
    func markingAlreadySeenIsIdempotent() async {
        let store = InMemoryOnboardingTourStore(
            initial: OnboardingTourState(hasSeenTabsTour: true, hasSeenScheduleHint: true),
        )
        await store.markTabsTourSeen()
        await store.markScheduleHintSeen()
        let state = await store.load()
        #expect(state.hasSeenTabsTour)
        #expect(state.hasSeenScheduleHint)
    }

    @Test
    func encodesBothFlags() throws {
        let state = OnboardingTourState(hasSeenTabsTour: true, hasSeenScheduleHint: false)
        let data = try JSONEncoder().encode(state)
        let string = try #require(String(data: data, encoding: .utf8))
        #expect(string.contains("hasSeenTabsTour"))
        #expect(string.contains("hasSeenScheduleHint"))
    }
}

@MainActor
@Suite("FaceIDIntroViewModel")
struct FaceIDIntroViewModelTests {
    @Test
    func biometricsAvailableFollowsProbe() {
        let storeTrue = InMemoryFaceIDIntroductionStore()
        let vmTrue = FaceIDIntroViewModel(
            store: storeTrue,
            onCompletion: {},
            biometricsProbe: { true },
        )
        #expect(vmTrue.biometricsAvailable)

        let storeFalse = InMemoryFaceIDIntroductionStore()
        let vmFalse = FaceIDIntroViewModel(
            store: storeFalse,
            onCompletion: {},
            biometricsProbe: { false },
        )
        #expect(!vmFalse.biometricsAvailable)
    }

    @Test
    func commitFlipsStoreAndFiresCompletion() async {
        let store = InMemoryFaceIDIntroductionStore()
        var completed = false
        let vm = FaceIDIntroViewModel(
            store: store,
            onCompletion: { completed = true },
            biometricsProbe: { true },
        )
        await vm.commit()
        #expect(completed)
        #expect(await store.load() == .seen)
        #expect(!vm.isCommitting)
    }

    @Test
    func commitEvenWhenBiometricsUnavailable() async {
        // The unavailable-biometrics card's "Continue anyway" path
        // still needs to flip the flag — the card is an onboarding
        // moment, not a gate. Otherwise a user without biometrics
        // would see the card on every launch forever.
        let store = InMemoryFaceIDIntroductionStore()
        var completed = false
        let vm = FaceIDIntroViewModel(
            store: store,
            onCompletion: { completed = true },
            biometricsProbe: { false },
        )
        await vm.commit()
        #expect(completed)
        #expect(await store.load() == .seen)
    }
}
