import Foundation
import Testing

@testable import CatLaserPairing

@Suite("PairingStrings.humanizedDeviceID")
struct PairingStringsHumanizedDeviceIDTests {
    @Test
    func shortAlphanumericRunPassesThrough() {
        // Under the 8-character grouping threshold — spaces would
        // produce noise with no legibility win.
        #expect(PairingStrings.humanizedDeviceID("abc") == "abc")
        #expect(PairingStrings.humanizedDeviceID("abc1") == "abc1")
        #expect(PairingStrings.humanizedDeviceID("1234567") == "1234567")
    }

    @Test
    func alphanumericRunIsChunkedByFours() {
        #expect(PairingStrings.humanizedDeviceID("abcd1234") == "abcd 1234")
        #expect(PairingStrings.humanizedDeviceID("abcd1234ef") == "abcd 1234 ef")
        #expect(PairingStrings.humanizedDeviceID("A4B293F7ABCD") == "A4B2 93F7 ABCD")
    }

    @Test
    func hyphenatedSlugIsNotRegrouped() {
        // Firmware-chosen format must survive byte-for-byte so a
        // printed or spoken identifier matches support tickets.
        let raw = "catlaser-abc123def456"
        #expect(PairingStrings.humanizedDeviceID(raw) == raw)
    }

    @Test
    func underscoredSlugIsNotRegrouped() {
        let raw = "lab_unit_0042"
        #expect(PairingStrings.humanizedDeviceID(raw) == raw)
    }
}

/// Manual-entry copy was rewritten to be mom-friendly: the
/// raw-URL-scheme placeholder ("catlaser://pair?code=...") and the
/// missing field label have been replaced with human guidance. These
/// tests pin the contract so a future copy edit cannot silently
/// regress the rewrite.
@Suite("PairingStrings.manualEntry")
struct PairingStringsManualEntryTests {
    @Test
    func placeholderIsHumanLanguageNotURLScheme() {
        // The placeholder is what a user reads before they understand
        // what the field accepts. The previous "catlaser://pair?code=..."
        // value is jargon that a non-technical owner cannot interpret;
        // any future edit that re-introduces a URL-scheme leak fails
        // here.
        #expect(!PairingStrings.manualEntryPlaceholder.contains("://"))
        #expect(!PairingStrings.manualEntryPlaceholder.contains("pair?"))
        #expect(!PairingStrings.manualEntryPlaceholder.contains("catlaser:"))
        #expect(!PairingStrings.manualEntryPlaceholder.isEmpty)
    }

    @Test
    func subtitleExplainsWhereTheLinkComesFrom() {
        // The subtitle must be present and give the user a real
        // reason to engage with the field. An empty subtitle would
        // leave manual-entry as cryptic as the old placeholder.
        #expect(!PairingStrings.manualEntrySubtitle.isEmpty)
        #expect(PairingStrings.manualEntrySubtitle.contains("Catlaser"))
    }

    @Test
    func fieldLabelIsConcreteAndNotJargon() {
        let label = PairingStrings.manualEntryFieldLabel
        #expect(!label.isEmpty)
        #expect(!label.contains("://"))
        #expect(!label.lowercased().contains("url"))
        #expect(!label.lowercased().contains("scheme"))
    }
}

/// Connecting-screen troubleshooting block must stay friendly,
/// concrete, and free of developer jargon. The rewrite added
/// ``connectingHelpTitle`` and ``connectingHelpBullets`` to give a
/// stuck user something to do BEFORE the destructive Unpair button
/// becomes the only escape; tests pin those strings so a regression
/// can't re-introduce the dead-end the original review flagged.
@Suite("PairingStrings.connectingHelp")
struct PairingStringsConnectingHelpTests {
    @Test
    func helpTitleIsAQuestionNotAFailure() {
        let title = PairingStrings.connectingHelpTitle
        #expect(!title.isEmpty)
        // The block is offered help, not confessed failure — the
        // supervisor is still actively retrying when this renders.
        // Negative copy ("Couldn't connect") would mis-frame the
        // moment.
        #expect(!title.lowercased().contains("can't"))
        #expect(!title.lowercased().contains("failed"))
        #expect(!title.lowercased().contains("error"))
    }

    @Test
    func helpBulletsAreUserActionable() {
        let bullets = PairingStrings.connectingHelpBullets
        #expect(bullets.count >= 3)
        for bullet in bullets {
            #expect(!bullet.isEmpty)
            // No developer jargon — the rewrite specifically excluded
            // implementation terms. A future edit that re-introduces
            // them fails here.
            #expect(!bullet.lowercased().contains("tailscale"))
            #expect(!bullet.lowercased().contains("attestation"))
            #expect(!bullet.lowercased().contains("nat"))
            #expect(!bullet.lowercased().contains("handshake"))
        }
    }
}
