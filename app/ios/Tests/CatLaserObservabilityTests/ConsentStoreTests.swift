import CatLaserObservability
import Foundation
import Testing

@Suite("ConsentState")
struct ConsentStateTests {
    @Test
    func notAskedMeansNeedsPromptAndEverythingDisabled() {
        let state = ConsentState.notAsked
        #expect(state.needsPrompt)
        #expect(!state.crashReportingEnabled)
        #expect(!state.telemetryEnabled)
    }

    @Test
    func declinedDisablesEverythingButDoesNotNeedPrompt() {
        let state = ConsentState.declined
        #expect(!state.needsPrompt)
        #expect(!state.crashReportingEnabled)
        #expect(!state.telemetryEnabled)
    }

    @Test
    func grantedTogglesAreIndependent() {
        let crashOnly = ConsentState.granted(crashReporting: true, telemetry: false)
        #expect(crashOnly.crashReportingEnabled)
        #expect(!crashOnly.telemetryEnabled)
        #expect(!crashOnly.needsPrompt)

        let telemetryOnly = ConsentState.granted(crashReporting: false, telemetry: true)
        #expect(!telemetryOnly.crashReportingEnabled)
        #expect(telemetryOnly.telemetryEnabled)
    }

    @Test
    func codableRoundTrips() throws {
        let cases: [ConsentState] = [
            .notAsked,
            .declined,
            .granted(crashReporting: true, telemetry: true),
            .granted(crashReporting: true, telemetry: false),
            .granted(crashReporting: false, telemetry: true),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for state in cases {
            let data = try encoder.encode(state)
            let decoded = try decoder.decode(ConsentState.self, from: data)
            #expect(decoded == state)
        }
    }
}

@Suite("InMemoryConsentStore")
struct InMemoryConsentStoreTests {
    @Test
    func loadReturnsInitialValue() async {
        let store = InMemoryConsentStore(initial: .granted(crashReporting: true, telemetry: true))
        let state = await store.load()
        if case .granted(true, true) = state {
            // ok
        } else {
            Issue.record("expected .granted(true, true), got \(state)")
        }
    }

    @Test
    func saveAndLoadRoundTrips() async {
        let store = InMemoryConsentStore()
        await store.save(.granted(crashReporting: false, telemetry: true))
        let loaded = await store.load()
        #expect(loaded == .granted(crashReporting: false, telemetry: true))
    }
}
