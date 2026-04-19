import Foundation
import Testing

@testable import CatLaserPush

@Suite("PushDeepLink routing")
struct PushDeepLinkTests {
    @Test
    func sessionSummaryRoutesToHome() {
        let payload: PushNotificationPayload = .sessionSummary(
            .init(
                catNames: ["Pancake"],
                durationSec: 60,
                engagementScore: 0.5,
                treatsDispensed: 1,
                pounceCount: 2,
            ),
        )
        #expect(PushDeepLink.route(for: payload) == .home)
    }

    @Test
    func sessionStartedRoutesToLiveView() {
        let payload: PushNotificationPayload = .sessionStarted(
            .init(catNames: ["Pancake"], trigger: "manual"),
        )
        #expect(PushDeepLink.route(for: payload) == .liveView)
    }

    @Test
    func hopperEmptyRoutesToHopperStatus() {
        #expect(PushDeepLink.route(for: .hopperEmpty) == .hopperStatus)
    }

    @Test
    func newCatDetectedRoutesToHistory() {
        let payload: PushNotificationPayload = .newCatDetected(
            .init(trackIDHint: 7, confidence: 0.8),
        )
        #expect(PushDeepLink.route(for: payload) == .history)
    }

    // Offensive: every "unrecognised" input MUST land on `.home`.
    // Collapsing to a presence-sensitive screen (live view) on a
    // malformed type is the regression this test is here to prevent.
    @Test
    func unknownRoutesToHomeNeverLiveView() {
        let route = PushDeepLink.route(for: .unknown(type: ""))
        #expect(route == .home)
    }

    @Test
    func arbitraryUnknownTypeRoutesToHome() {
        let route = PushDeepLink.route(for: .unknown(type: "attacker-chose-this"))
        #expect(route == .home)
    }
}
