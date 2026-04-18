import CatLaserProto
import Foundation
import Testing

@testable import CatLaserLive

@Suite("LiveStreamCredentials")
struct LiveStreamCredentialsTests {
    @Test
    func acceptsWSSURL() throws {
        let creds = try LiveStreamCredentials(url: URL(string: "wss://livekit.test")!, token: "abc")
        #expect(creds.url.scheme == "wss")
        #expect(creds.token == "abc")
    }

    @Test
    func rejectsUnsupportedScheme() {
        #expect(throws: LiveStreamCredentialsError.invalidURLScheme) {
            _ = try LiveStreamCredentials(url: URL(string: "tcp://livekit.test")!, token: "abc")
        }
    }

    @Test
    func rejectsEmptyToken() {
        #expect(throws: LiveStreamCredentialsError.missingToken) {
            _ = try LiveStreamCredentials(url: URL(string: "wss://livekit.test")!, token: "")
        }
        #expect(throws: LiveStreamCredentialsError.missingToken) {
            _ = try LiveStreamCredentials(url: URL(string: "wss://livekit.test")!, token: "   ")
        }
    }

    @Test
    func trimsTokenWhitespace() throws {
        let creds = try LiveStreamCredentials(url: URL(string: "wss://livekit.test")!, token: "  t  ")
        #expect(creds.token == "t")
    }

    @Test
    func buildsFromStreamOfferProto() throws {
        var offer = Catlaser_App_V1_StreamOffer()
        offer.livekitURL = "wss://livekit.test"
        offer.subscriberToken = "xyz"
        let creds = try LiveStreamCredentials(offer: offer)
        #expect(creds.url.absoluteString == "wss://livekit.test")
        #expect(creds.token == "xyz")
    }

    @Test
    func rejectsEmptyOfferURL() {
        var offer = Catlaser_App_V1_StreamOffer()
        offer.livekitURL = ""
        offer.subscriberToken = "xyz"
        #expect(throws: LiveStreamCredentialsError.invalidURL) {
            _ = try LiveStreamCredentials(offer: offer)
        }
    }
}
