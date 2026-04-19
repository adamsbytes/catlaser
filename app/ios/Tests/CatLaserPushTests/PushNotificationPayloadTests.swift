import Foundation
import Testing

@testable import CatLaserPush

@Suite("PushNotificationPayload")
struct PushNotificationPayloadTests {
    // MARK: - Happy paths (byte-for-byte fidelity with push.py)

    @Test
    func parsesSessionSummary() {
        // Matches ``PushNotifier.notify_session_summary`` from
        // ``python/catlaser_brain/network/push.py`` — the shape is
        // frozen by the app/server contract.
        let data: [String: String] = [
            "type": "session_summary",
            "cat_names": "Pancake,Fig",
            "duration_sec": "180",
            "engagement_score": "0.87",
            "treats_dispensed": "5",
            "pounce_count": "12",
        ]
        let payload = PushNotificationPayload.parse(data: data)
        guard case let .sessionSummary(summary) = payload else {
            Issue.record("expected .sessionSummary, got \(payload)")
            return
        }
        #expect(summary.catNames == ["Pancake", "Fig"])
        #expect(summary.durationSec == 180)
        #expect(summary.engagementScore == 0.87)
        #expect(summary.treatsDispensed == 5)
        #expect(summary.pounceCount == 12)
    }

    @Test
    func parsesSessionStarted() {
        let data: [String: String] = [
            "type": "session_started",
            "cat_names": "Pancake",
            "trigger": "scheduled",
        ]
        let payload = PushNotificationPayload.parse(data: data)
        guard case let .sessionStarted(started) = payload else {
            Issue.record("expected .sessionStarted, got \(payload)")
            return
        }
        #expect(started.catNames == ["Pancake"])
        #expect(started.trigger == "scheduled")
    }

    @Test
    func parsesHopperEmpty() {
        let payload = PushNotificationPayload.parse(data: ["type": "hopper_empty"])
        #expect(payload == .hopperEmpty)
    }

    @Test
    func parsesNewCatDetected() {
        let data: [String: String] = [
            "type": "new_cat_detected",
            "track_id_hint": "42",
            "confidence": "0.91",
        ]
        let payload = PushNotificationPayload.parse(data: data)
        guard case let .newCatDetected(detected) = payload else {
            Issue.record("expected .newCatDetected, got \(payload)")
            return
        }
        #expect(detected.trackIDHint == 42)
        #expect(detected.confidence == 0.91)
    }

    // MARK: - Permissive fallbacks

    @Test
    func missingNumericFieldsFallBackToZero() {
        // A partial payload (transitional device state) must not
        // crash — the banner title/body is already rendered by the
        // OS; the in-app surface re-fetches authoritative values
        // over the data channel anyway.
        let payload = PushNotificationPayload.parse(data: ["type": "session_summary"])
        guard case let .sessionSummary(summary) = payload else {
            Issue.record("expected .sessionSummary, got \(payload)")
            return
        }
        #expect(summary.catNames.isEmpty)
        #expect(summary.durationSec == 0)
        #expect(summary.engagementScore == 0)
        #expect(summary.treatsDispensed == 0)
        #expect(summary.pounceCount == 0)
    }

    @Test
    func nonNumericFieldsParseAsZero() {
        // A malformed numeric field must not throw. This can happen
        // in a future server schema change that emits "high" /
        // "medium" / "low" instead of a score; the app degrades
        // gracefully rather than crashing.
        let payload = PushNotificationPayload.parse(data: [
            "type": "new_cat_detected",
            "track_id_hint": "not-a-number",
            "confidence": "high",
        ])
        guard case let .newCatDetected(detected) = payload else {
            Issue.record("expected .newCatDetected, got \(payload)")
            return
        }
        #expect(detected.trackIDHint == 0)
        #expect(detected.confidence == 0)
    }

    @Test
    func emptyCatNamesProducesEmptyArray() {
        // Server side always filters empties, but test the defensive
        // fallback just in case — an empty comma-joined string must
        // yield [].
        let payload = PushNotificationPayload.parse(data: [
            "type": "session_summary",
            "cat_names": "",
        ])
        guard case let .sessionSummary(summary) = payload else {
            Issue.record("expected .sessionSummary, got \(payload)")
            return
        }
        #expect(summary.catNames.isEmpty)
    }

    @Test
    func missingTypeMapsToUnknownEmpty() {
        let payload = PushNotificationPayload.parse(data: [:])
        #expect(payload == .unknown(type: ""))
    }

    @Test
    func unknownTypeMapsToUnknown() {
        let payload = PushNotificationPayload.parse(data: ["type": "weird-future-type"])
        #expect(payload == .unknown(type: "weird-future-type"))
    }

    // MARK: - Offensive inputs

    @Test
    func oversizedCatNamesStillParses() {
        // A wildly oversized `cat_names` value (hypothetical hostile
        // push or a server-side bug) must still produce a parseable
        // payload — we just end up with a long array. The banner /
        // route decision is the same.
        let huge = (0 ..< 256).map { "cat-\($0)" }.joined(separator: ",")
        let payload = PushNotificationPayload.parse(data: [
            "type": "session_summary",
            "cat_names": huge,
            "duration_sec": "60",
        ])
        guard case let .sessionSummary(summary) = payload else {
            Issue.record("expected .sessionSummary, got \(payload)")
            return
        }
        #expect(summary.catNames.count == 256)
        #expect(summary.durationSec == 60)
    }

    @Test
    func wrongTypeCasingDoesNotMatch() {
        // The server emits snake_case; a differently-cased type is
        // by definition a string we don't recognise and must route
        // to .unknown, not collapse to one of the known cases. This
        // protects against a future server-side casing drift
        // silently triggering a deep link.
        let payload = PushNotificationPayload.parse(data: ["type": "Session_Summary"])
        #expect(payload == .unknown(type: "Session_Summary"))
    }

    @Test
    func negativeNumericsClampToZero() {
        // UInt32 parse of "-1" is nil. Clamping to 0 is deliberate —
        // the banner body never uses negative numbers, and a nil
        // crash here would take down the UN delegate before it got
        // to route the tap.
        let payload = PushNotificationPayload.parse(data: [
            "type": "session_summary",
            "duration_sec": "-1",
        ])
        guard case let .sessionSummary(summary) = payload else {
            Issue.record("expected .sessionSummary, got \(payload)")
            return
        }
        #expect(summary.durationSec == 0)
    }
}
