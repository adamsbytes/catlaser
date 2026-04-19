#if canImport(SwiftUI)
import CatLaserDesign
import Foundation
import Testing

@Suite("AccessibilityID")
struct AccessibilityIDTests {
    /// Every identifier has a non-empty raw value — an empty string
    /// would silently reduce VoiceOver / UI-test targeting to a
    /// no-op with no compile error.
    @Test
    func everyIDHasNonEmptyRawValue() {
        for identifier in AccessibilityID.allCases {
            #expect(!identifier.rawValue.isEmpty,
                    "\(identifier) has an empty accessibility id")
        }
    }

    /// Every identifier uses the `<screen>.<control>` dotted form.
    /// A rogue entry without a dot would still compile but would be
    /// hard to group by screen in the UI-test report.
    @Test
    func everyIDIsNamespaced() {
        for identifier in AccessibilityID.allCases {
            #expect(identifier.rawValue.contains("."),
                    "\(identifier) should contain a '.' namespace separator")
        }
    }

    /// Raw values are unique across every case. Two cases with the
    /// same string would cause UI tests to target the wrong
    /// element.
    @Test
    func everyIDRawValueIsUnique() {
        let rawValues = AccessibilityID.allCases.map(\.rawValue)
        let uniqueCount = Set(rawValues).count
        #expect(rawValues.count == uniqueCount,
                "duplicate accessibility ids detected: \(rawValues)")
    }
}
#endif
