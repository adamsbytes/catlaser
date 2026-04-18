import Foundation
import Testing

@testable import CatLaserPairing

@Suite("QRPayloadDecision")
struct QRPayloadDetectionTests {
    @Test
    func acceptsValidCatlaserURL() {
        let decision = QRPayloadDecision.evaluate("catlaser://pair?code=ABCDEFGHIJKLMNOP&device=cat-001")
        if case let .accepted(code) = decision {
            #expect(code.code == "ABCDEFGHIJKLMNOP")
        } else {
            Issue.record("expected .accepted, got \(decision)")
        }
    }

    @Test
    func ignoresNonCatlaserQR() {
        let decision = QRPayloadDecision.evaluate("https://example.com/promo")
        #expect(decision == .ignored)
    }

    @Test
    func ignoresBareText() {
        let decision = QRPayloadDecision.evaluate("my phone number is 555-1234")
        #expect(decision == .ignored)
    }

    @Test
    func ignoresEmpty() {
        #expect(QRPayloadDecision.evaluate("") == .ignored)
        #expect(QRPayloadDecision.evaluate("   ") == .ignored)
    }

    @Test
    func rejectsCatlaserURLWithMalformedCode() {
        let decision = QRPayloadDecision.evaluate("catlaser://pair?code=short&device=d1")
        if case let .rejected(error) = decision {
            #expect(error == .codeTooShort)
        } else {
            Issue.record("expected .rejected, got \(decision)")
        }
    }

    @Test
    func rejectsCatlaserURLWithSmuggledParameter() {
        let decision = QRPayloadDecision.evaluate("catlaser://pair?code=ABCDEFGHIJKLMNOP&device=d1&x=y")
        if case let .rejected(error) = decision {
            #expect(error == .unexpectedQueryItem("x"))
        } else {
            Issue.record("expected .rejected, got \(decision)")
        }
    }

    @Test
    func trimsSurroundingWhitespace() {
        let decision = QRPayloadDecision.evaluate(
            "  catlaser://pair?code=ABCDEFGHIJKLMNOP&device=cat-001  \n",
        )
        if case let .accepted(code) = decision {
            #expect(code.deviceID == "cat-001")
        } else {
            Issue.record("expected .accepted, got \(decision)")
        }
    }

    @Test
    func schemeMatchIsCaseInsensitive() {
        let decision = QRPayloadDecision.evaluate("CATLASER://pair?code=ABCDEFGHIJKLMNOP&device=d1")
        if case .accepted = decision {
            // good
        } else {
            Issue.record("expected .accepted for uppercase scheme, got \(decision)")
        }
    }
}
