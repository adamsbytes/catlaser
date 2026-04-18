import Foundation
import Testing

@testable import CatLaserPairing

@Suite("PairingCode")
struct PairingCodeTests {
    @Test
    func parsesValidURL() throws {
        let code = try PairingCode.parse("catlaser://pair?code=ABCDEFGHIJKLMNOP&device=cat-001")
        #expect(code.code == "ABCDEFGHIJKLMNOP")
        #expect(code.deviceID == "cat-001")
    }

    @Test
    func parsesURLWithTrailingSlashPath() throws {
        let code = try PairingCode.parse("catlaser://pair/?code=ABCDEFGHIJKLMNOP&device=cat-001")
        #expect(code.code == "ABCDEFGHIJKLMNOP")
    }

    @Test
    func acceptsReorderedQueryItems() throws {
        let code = try PairingCode.parse("catlaser://pair?device=cat-001&code=ABCDEFGHIJKLMNOP")
        #expect(code.code == "ABCDEFGHIJKLMNOP")
        #expect(code.deviceID == "cat-001")
    }

    @Test
    func acceptsLongBase32Code() throws {
        let long = String(repeating: "ABCDEFGH", count: 4) // 32 chars, real-world size
        let code = try PairingCode.parse("catlaser://pair?code=\(long)&device=d1")
        #expect(code.code == long)
    }

    @Test
    func acceptsDeviceSlugWithHyphensAndUnderscores() throws {
        let code = try PairingCode.parse("catlaser://pair?code=ABCDEFGHIJKLMNOP&device=cat_001-v2")
        #expect(code.deviceID == "cat_001-v2")
    }

    @Test
    func trimsSurroundingWhitespace() throws {
        let code = try PairingCode.parse("  catlaser://pair?code=ABCDEFGHIJKLMNOP&device=d1 \n")
        #expect(code.code == "ABCDEFGHIJKLMNOP")
    }

    @Test
    func roundTripsViaURL() throws {
        let original = try PairingCode(code: "ABCDEFGHIJKLMNOP", deviceID: "cat-001")
        let url = original.url
        let parsed = try PairingCode.parse(url.absoluteString)
        #expect(parsed == original)
    }

    // MARK: - Rejections

    @Test
    func rejectsEmpty() {
        #expect(throws: PairingCodeError.empty) {
            _ = try PairingCode.parse("")
        }
        #expect(throws: PairingCodeError.empty) {
            _ = try PairingCode.parse("   \t\n  ")
        }
    }

    @Test
    func rejectsWrongScheme() {
        #expect(throws: PairingCodeError.wrongScheme) {
            _ = try PairingCode.parse("https://pair?code=ABCDEFGHIJKLMNOP&device=d1")
        }
    }

    @Test
    func rejectsWrongHost() {
        #expect(throws: PairingCodeError.wrongHost) {
            _ = try PairingCode.parse("catlaser://register?code=ABCDEFGHIJKLMNOP&device=d1")
        }
    }

    @Test
    func rejectsUnexpectedPath() {
        #expect(throws: PairingCodeError.unexpectedPath) {
            _ = try PairingCode.parse("catlaser://pair/extra?code=ABCDEFGHIJKLMNOP&device=d1")
        }
    }

    @Test
    func rejectsMissingQueryItems() {
        #expect(throws: PairingCodeError.missingQueryItems) {
            _ = try PairingCode.parse("catlaser://pair")
        }
    }

    @Test
    func rejectsMissingCode() {
        #expect(throws: PairingCodeError.missingCode) {
            _ = try PairingCode.parse("catlaser://pair?device=d1")
        }
    }

    @Test
    func rejectsMissingDeviceID() {
        #expect(throws: PairingCodeError.missingDeviceID) {
            _ = try PairingCode.parse("catlaser://pair?code=ABCDEFGHIJKLMNOP")
        }
    }

    @Test
    func rejectsDuplicateQueryItem() {
        #expect(throws: PairingCodeError.duplicateQueryItem("code")) {
            _ = try PairingCode.parse("catlaser://pair?code=AAAAAAAAAAAAAAAA&code=BBBBBBBBBBBBBBBB&device=d1")
        }
    }

    @Test
    func rejectsSmuggledExtraQueryItem() {
        #expect(throws: PairingCodeError.unexpectedQueryItem("callback")) {
            _ = try PairingCode.parse("catlaser://pair?code=ABCDEFGHIJKLMNOP&device=d1&callback=https://evil.example")
        }
    }

    @Test
    func rejectsCodeTooShort() {
        #expect(throws: PairingCodeError.codeTooShort) {
            _ = try PairingCode.parse("catlaser://pair?code=ABCD&device=d1")
        }
    }

    @Test
    func rejectsCodeTooLong() {
        let huge = String(repeating: "A", count: PairingCode.maxCodeLength + 1)
        #expect(throws: PairingCodeError.codeTooLong) {
            _ = try PairingCode.parse("catlaser://pair?code=\(huge)&device=d1")
        }
    }

    @Test
    func rejectsCodeWithLowercase() {
        #expect(throws: PairingCodeError.codeIllegalCharacter) {
            _ = try PairingCode.parse("catlaser://pair?code=abcdefghijklmnop&device=d1")
        }
    }

    @Test
    func rejectsCodeWithDigit1() {
        // base32 alphabet excludes 0, 1, 8, 9.
        #expect(throws: PairingCodeError.codeIllegalCharacter) {
            _ = try PairingCode.parse("catlaser://pair?code=ABCDEFGHIJKLMNO1&device=d1")
        }
    }

    @Test
    func rejectsCodeWithPadding() {
        #expect(throws: PairingCodeError.codeIllegalCharacter) {
            _ = try PairingCode.parse("catlaser://pair?code=ABCDEFGHIJKLMNO=&device=d1")
        }
    }

    @Test
    func rejectsDeviceWithTooLongSlug() {
        let longID = String(repeating: "a", count: PairingCode.maxDeviceIDLength + 1)
        #expect(throws: PairingCodeError.deviceIDTooLong) {
            _ = try PairingCode.parse("catlaser://pair?code=ABCDEFGHIJKLMNOP&device=\(longID)")
        }
    }

    @Test
    func rejectsDeviceWithIllegalCharacter() {
        #expect(throws: PairingCodeError.deviceIDIllegalCharacter) {
            _ = try PairingCode.parse("catlaser://pair?code=ABCDEFGHIJKLMNOP&device=cat.001")
        }
    }

    @Test
    func rejectsNonURLText() {
        #expect(throws: PairingCodeError.wrongScheme) {
            // Foundation treats bare text as a relative URL with no
            // scheme, so the scheme check is the gate here.
            _ = try PairingCode.parse("plain text not a URL")
        }
    }

    @Test
    func caseInsensitiveScheme() throws {
        let code = try PairingCode.parse("CATLASER://pair?code=ABCDEFGHIJKLMNOP&device=d1")
        #expect(code.code == "ABCDEFGHIJKLMNOP")
    }

    @Test
    func caseInsensitiveHost() throws {
        let code = try PairingCode.parse("catlaser://PAIR?code=ABCDEFGHIJKLMNOP&device=d1")
        #expect(code.deviceID == "d1")
    }
}
