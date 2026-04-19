import CatLaserApp
import Foundation
import Testing

/// Policy: pairing is QR-only. Any URL claiming `catlaser://` is
/// refused and the user gets a message explaining why. These tests
/// lock that policy in so a later release that adds a URL scheme
/// handler can't silently open a pairing path.
@Suite("PairingURLHandler")
struct PairingURLHandlerTests {
    @Test
    func catlaserSchemeIsRefused() throws {
        let url = try #require(URL(string: "catlaser://pair?code=ABC&device=cat-001"))
        switch PairingURLHandler.handle(url: url) {
        case .refusedURLBasedPairing(let message):
            #expect(!message.isEmpty)
        case .notPairingRelated:
            Issue.record("catlaser:// must be recognised and refused, got .notPairingRelated")
        }
    }

    @Test
    func catlaserSchemeWithNoPathStillRefused() throws {
        // Blanket refusal on the scheme. Even a bare `catlaser://`
        // (no pair path, no query) must be refused so a future
        // release that carries auxiliary data on the scheme has to
        // explicitly pattern-match rather than accidentally pair.
        let url = try #require(URL(string: "catlaser://random"))
        if case .refusedURLBasedPairing = PairingURLHandler.handle(url: url) {
            // good
        } else {
            Issue.record("expected refusal for bare catlaser:// URL")
        }
    }

    @Test
    func schemeMatchIsCaseInsensitive() throws {
        // RFC 3986 declares URL schemes case-insensitive; a
        // `CatLaser://` URL must not slip through because someone
        // shoved the first letter uppercase.
        let url = try #require(URL(string: "CatLaser://pair?code=ABC&device=cat-001"))
        if case .refusedURLBasedPairing = PairingURLHandler.handle(url: url) {
            // good
        } else {
            Issue.record("expected refusal for uppercase scheme")
        }
    }

    @Test
    func magicLinkHTTPSIsNotClaimed() throws {
        // Magic-link URLs go through `SignInView.onOpenURL`. The
        // pairing handler must return `.notPairingRelated` so the
        // caller forwards them to the right place.
        let url = try #require(URL(string: "https://auth.catlaser.example/magic-link/verify?token=abc"))
        #expect(PairingURLHandler.handle(url: url) == .notPairingRelated)
    }

    @Test
    func unrelatedSchemeIsNotClaimed() throws {
        let url = try #require(URL(string: "file:///tmp/foo"))
        #expect(PairingURLHandler.handle(url: url) == .notPairingRelated)
    }
}
