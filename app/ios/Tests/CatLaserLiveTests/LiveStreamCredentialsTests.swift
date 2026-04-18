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
    func rejectsPlaintextWebSocket() {
        // A `ws://` URL would expose the LiveKit subscriber JWT and the
        // SDP/ICE signaling to any network hop between the app and the
        // LiveKit server. The credential type must refuse these outright
        // so a compromised or buggy device cannot downgrade the signaling
        // channel.
        #expect(throws: LiveStreamCredentialsError.invalidURLScheme) {
            _ = try LiveStreamCredentials(url: URL(string: "ws://livekit.test")!, token: "abc")
        }
    }

    @Test
    func rejectsPlaintextHTTP() {
        #expect(throws: LiveStreamCredentialsError.invalidURLScheme) {
            _ = try LiveStreamCredentials(url: URL(string: "http://livekit.test")!, token: "abc")
        }
    }

    @Test
    func rejectsHTTPS() {
        // The LiveKit Swift SDK dials a WebSocket. A `https://` URL would
        // either fail at the SDK layer or silently be upgraded; neither is
        // the contract we want to document. `wss://` is the single
        // supported scheme.
        #expect(throws: LiveStreamCredentialsError.invalidURLScheme) {
            _ = try LiveStreamCredentials(url: URL(string: "https://livekit.test")!, token: "abc")
        }
    }

    @Test
    func rejectsOfferWithPlaintextScheme() {
        // The most realistic attack path for this vulnerability: a
        // compromised or buggy device daemon returns a `StreamOffer` with
        // a `ws://` URL. The proto-convenience initializer must reject it
        // at construction so `LiveViewModel` never dials plaintext.
        var offer = Catlaser_App_V1_StreamOffer()
        offer.livekitURL = "ws://livekit.test"
        offer.subscriberToken = "xyz"
        #expect(throws: LiveStreamCredentialsError.invalidURLScheme) {
            _ = try LiveStreamCredentials(offer: offer)
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
