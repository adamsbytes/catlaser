import Foundation
import Testing

@testable import CatLaserApp

@Suite("EmailValidator")
struct EmailValidatorTests {
    @Test
    func acceptsPlainLowercaseAddress() {
        #expect(EmailValidator.isValid("cat@example.com"))
    }

    @Test
    func acceptsSubdomainAndPlusAddressing() {
        #expect(EmailValidator.isValid("user+tag@mail.example.co.uk"))
    }

    @Test
    func acceptsUppercase() {
        #expect(EmailValidator.isValid("Cat@Example.COM"))
    }

    @Test
    func trimsSurroundingWhitespace() {
        #expect(EmailValidator.isValid("  cat@example.com  "))
        #expect(EmailValidator.isValid("\tcat@example.com\n"))
    }

    @Test
    func rejectsEmptyString() {
        #expect(!EmailValidator.isValid(""))
    }

    @Test
    func rejectsWhitespaceOnlyString() {
        #expect(!EmailValidator.isValid("   "))
        #expect(!EmailValidator.isValid("\n\t"))
    }

    @Test
    func rejectsMissingAtSign() {
        #expect(!EmailValidator.isValid("catexample.com"))
    }

    @Test
    func rejectsMultipleAtSigns() {
        // The `[^\s@]+@[^\s@]+` anchor rejects a literal second `@` in
        // either the local or the domain part.
        #expect(!EmailValidator.isValid("a@b@c.com"))
    }

    @Test
    func rejectsMissingDomainDot() {
        // The pattern requires a dot after the domain — `foo@bar`
        // without a TLD is rejected.
        #expect(!EmailValidator.isValid("cat@example"))
    }

    @Test
    func rejectsMissingLocalPart() {
        #expect(!EmailValidator.isValid("@example.com"))
    }

    @Test
    func rejectsMissingDomainPart() {
        #expect(!EmailValidator.isValid("cat@.com"))
    }

    @Test
    func rejectsInternalWhitespace() {
        #expect(!EmailValidator.isValid("ca t@example.com"))
        #expect(!EmailValidator.isValid("cat@exa mple.com"))
    }

    @Test
    func rejectsControlCharacters() {
        #expect(!EmailValidator.isValid("cat\n@example.com"))
        #expect(!EmailValidator.isValid("cat@example.com\u{0007}"))
    }

    @Test
    func rejectsLengthOver320Bytes() {
        // 300-char local part + "@example.com" = 312 bytes, under bound.
        let localShort = String(repeating: "a", count: 300)
        #expect(EmailValidator.isValid("\(localShort)@example.com"))
        // 315 + "@example.com" (12) = 327 bytes, over the 320 bound.
        let localLong = String(repeating: "a", count: 315)
        #expect(!EmailValidator.isValid("\(localLong)@example.com"))
    }

    @Test
    func rejectsEmailWithMultibyteScalarsPushingOverByteBound() {
        // Each "é" is 2 UTF-8 bytes. 160 of them is 320 bytes; append
        // "@example.com" and the total is 332 bytes.
        let localMultibyte = String(repeating: "é", count: 160)
        #expect(!EmailValidator.isValid("\(localMultibyte)@example.com"))
    }

    @Test
    func normalizedStripsSurroundingWhitespaceOnly() {
        #expect(EmailValidator.normalized("  foo@bar.com  ") == "foo@bar.com")
        #expect(EmailValidator.normalized("no-space@bar.com") == "no-space@bar.com")
    }

    @Test
    func normalizedPreservesInternalText() {
        // Only surrounding whitespace is trimmed; internal content
        // (including an invalid internal space) flows through so the
        // downstream validator can reject it.
        #expect(EmailValidator.normalized("  bad space@bar.com  ") == "bad space@bar.com")
    }
}
