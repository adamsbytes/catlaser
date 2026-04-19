import CatLaserObservability
import Foundation
import Testing

@Suite("TelemetryEvent")
struct TelemetryEventTests {
    /// The wire name must match the server's closed vocabulary —
    /// adding a case without updating ``wireName`` would produce a
    /// case that gets dropped on the floor at ingest time. We pin
    /// a representative subset here so a rename of a Swift case
    /// name does not silently change the wire contract.
    @Test
    func wireNamesAreStable() {
        #expect(TelemetryEvent.appLaunched(coldStart: true).wireName == "app_launched")
        #expect(TelemetryEvent.signInStarted(provider: .apple).wireName == "sign_in_started")
        #expect(TelemetryEvent.pairingSucceeded.wireName == "pairing_succeeded")
        #expect(TelemetryEvent.liveStreamStarted.wireName == "live_stream_started")
        #expect(TelemetryEvent.consentGranted(crashReporting: true, telemetry: true).wireName == "consent_granted")
        #expect(TelemetryEvent.crashReportDelivered(source: .metricKit).wireName == "crash_report_delivered")
    }

    /// Attributes are stringly typed on the wire.
    @Test
    func appLaunchedEncodesColdStart() {
        let hot = TelemetryEvent.appLaunched(coldStart: false).wireAttributes
        let cold = TelemetryEvent.appLaunched(coldStart: true).wireAttributes
        #expect(hot["cold_start"] == "false")
        #expect(cold["cold_start"] == "true")
    }

    @Test
    func failedSignInEncodesBothProviderAndReason() {
        let event = TelemetryEvent.signInFailed(provider: .google, reason: .network)
        let attrs = event.wireAttributes
        #expect(attrs["provider"] == "google")
        #expect(attrs["reason"] == "network")
    }

    @Test
    func consentEventsEncodeBothToggles() {
        let event = TelemetryEvent.consentGranted(crashReporting: true, telemetry: false)
        let attrs = event.wireAttributes
        #expect(attrs["crash_reporting"] == "true")
        #expect(attrs["telemetry"] == "false")
    }

    @Test
    func scheduleLoadedEncodesEntryCount() {
        let attrs = TelemetryEvent.scheduleLoaded(entryCount: 7).wireAttributes
        #expect(attrs["entry_count"] == "7")
    }

    /// Events without associated values carry no attributes.
    @Test
    func primitiveEventsCarryEmptyAttributes() {
        #expect(TelemetryEvent.pairingSucceeded.wireAttributes.isEmpty)
        #expect(TelemetryEvent.liveStreamStarted.wireAttributes.isEmpty)
        #expect(TelemetryEvent.signedOut.wireAttributes.isEmpty)
    }

    @Test
    func eventCodableRoundTrips() throws {
        let event = TelemetryEvent.historyLoaded(catCount: 4, sessionCount: 12)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(event)
        let decoded = try JSONDecoder().decode(TelemetryEvent.self, from: data)
        #expect(decoded == event)
    }
}
