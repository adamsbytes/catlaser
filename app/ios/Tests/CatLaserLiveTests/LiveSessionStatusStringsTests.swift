import CatLaserProto
import Foundation
import Testing

@testable import CatLaserLive

@Suite("LiveSessionStatusStrings")
struct LiveSessionStatusStringsTests {
    @Test
    func elapsedFormatsSecondsOnly() {
        let now = Date(timeIntervalSince1970: 100)
        let started = Date(timeIntervalSince1970: 55)
        #expect(LiveSessionStatusStrings.elapsed(since: started, now: now) == "45s")
    }

    @Test
    func elapsedFormatsMinutesAndSeconds() {
        let now = Date(timeIntervalSince1970: 200)
        let started = Date(timeIntervalSince1970: 0)
        #expect(LiveSessionStatusStrings.elapsed(since: started, now: now) == "3m 20s")
    }

    @Test
    func elapsedFormatsHoursMinutesSeconds() {
        let now = Date(timeIntervalSince1970: 3_725)
        let started = Date(timeIntervalSince1970: 0)
        #expect(LiveSessionStatusStrings.elapsed(since: started, now: now) == "1h 02m 05s")
    }

    @Test
    func elapsedClampsNegativeIntervalToZero() {
        // Wall clock can legitimately step backwards (NTP correction).
        // The overlay must not render "-3s" in that case.
        let now = Date(timeIntervalSince1970: 100)
        let started = Date(timeIntervalSince1970: 200)
        #expect(LiveSessionStatusStrings.elapsed(since: started, now: now) == "0s")
    }

    @Test
    func hopperBadgeForLowReturnsLowLabel() {
        #expect(LiveSessionStatusStrings.hopperBadge(for: .low) == LiveSessionStatusStrings.hopperLowLabel)
    }

    @Test
    func hopperBadgeForEmptyReturnsEmptyLabel() {
        #expect(LiveSessionStatusStrings.hopperBadge(for: .empty) == LiveSessionStatusStrings.hopperEmptyLabel)
    }

    @Test
    func hopperBadgeForOkReturnsNil() {
        #expect(LiveSessionStatusStrings.hopperBadge(for: .ok) == nil)
    }

    @Test
    func hopperBadgeForUnspecifiedReturnsNil() {
        #expect(LiveSessionStatusStrings.hopperBadge(for: .unspecified) == nil)
    }

    @Test
    func spokenElapsedReadableForVoiceOver() {
        let started = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 80)
        let spoken = LiveSessionStatusStrings.spokenElapsed(since: started, now: now)
        // Format differs across locales — assert the numbers are
        // somewhere in the rendered string rather than pinning exact
        // phrasing.
        #expect(spoken.contains("one") || spoken.contains("1"))
        #expect(spoken.contains("twenty") || spoken.contains("20"))
    }
}
