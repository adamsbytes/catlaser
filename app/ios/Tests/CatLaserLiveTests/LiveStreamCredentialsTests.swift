import CatLaserProto
import Foundation
import Testing

@testable import CatLaserLive

@Suite("LiveStreamCredentials")
struct LiveStreamCredentialsTests {
    /// A single-host allowlist that every test below uses for the
    /// positive paths. Reused so adding a new test automatically
    /// exercises the allowlist code path rather than accidentally
    /// bypassing it with a permissive overload.
    private func makeAllowlist(hosts: [String] = ["livekit.test"]) throws -> LiveKitHostAllowlist {
        try LiveKitHostAllowlist(hosts: hosts)
    }

    @Test
    func acceptsWSSURL() throws {
        let creds = try LiveStreamCredentials(
            url: URL(string: "wss://livekit.test")!,
            token: "abc",
            allowlist: makeAllowlist(),
        )
        #expect(creds.url.scheme == "wss")
        #expect(creds.token == "abc")
    }

    @Test
    func rejectsUnsupportedScheme() throws {
        let allow = try makeAllowlist()
        #expect(throws: LiveStreamCredentialsError.invalidURLScheme) {
            _ = try LiveStreamCredentials(
                url: URL(string: "tcp://livekit.test")!,
                token: "abc",
                allowlist: allow,
            )
        }
    }

    @Test
    func rejectsPlaintextWebSocket() throws {
        // A `ws://` URL would expose the LiveKit subscriber JWT and the
        // SDP/ICE signaling to any network hop between the app and the
        // LiveKit server. The credential type must refuse these outright
        // so a compromised or buggy device cannot downgrade the signaling
        // channel.
        let allow = try makeAllowlist()
        #expect(throws: LiveStreamCredentialsError.invalidURLScheme) {
            _ = try LiveStreamCredentials(
                url: URL(string: "ws://livekit.test")!,
                token: "abc",
                allowlist: allow,
            )
        }
    }

    @Test
    func rejectsPlaintextHTTP() throws {
        let allow = try makeAllowlist()
        #expect(throws: LiveStreamCredentialsError.invalidURLScheme) {
            _ = try LiveStreamCredentials(
                url: URL(string: "http://livekit.test")!,
                token: "abc",
                allowlist: allow,
            )
        }
    }

    @Test
    func rejectsHTTPS() throws {
        // The LiveKit Swift SDK dials a WebSocket. A `https://` URL would
        // either fail at the SDK layer or silently be upgraded; neither is
        // the contract we want to document. `wss://` is the single
        // supported scheme.
        let allow = try makeAllowlist()
        #expect(throws: LiveStreamCredentialsError.invalidURLScheme) {
            _ = try LiveStreamCredentials(
                url: URL(string: "https://livekit.test")!,
                token: "abc",
                allowlist: allow,
            )
        }
    }

    @Test
    func rejectsOfferWithPlaintextScheme() throws {
        // The most realistic attack path for this vulnerability: a
        // compromised or buggy device daemon returns a `StreamOffer` with
        // a `ws://` URL. The proto-convenience initializer must reject it
        // at construction so `LiveViewModel` never dials plaintext.
        var offer = Catlaser_App_V1_StreamOffer()
        offer.livekitURL = "ws://livekit.test"
        offer.subscriberToken = "xyz"
        let allow = try makeAllowlist()
        #expect(throws: LiveStreamCredentialsError.invalidURLScheme) {
            _ = try LiveStreamCredentials(offer: offer, allowlist: allow)
        }
    }

    @Test
    func rejectsEmptyToken() throws {
        let allow = try makeAllowlist()
        #expect(throws: LiveStreamCredentialsError.missingToken) {
            _ = try LiveStreamCredentials(
                url: URL(string: "wss://livekit.test")!,
                token: "",
                allowlist: allow,
            )
        }
        #expect(throws: LiveStreamCredentialsError.missingToken) {
            _ = try LiveStreamCredentials(
                url: URL(string: "wss://livekit.test")!,
                token: "   ",
                allowlist: allow,
            )
        }
    }

    @Test
    func trimsTokenWhitespace() throws {
        let creds = try LiveStreamCredentials(
            url: URL(string: "wss://livekit.test")!,
            token: "  t  ",
            allowlist: makeAllowlist(),
        )
        #expect(creds.token == "t")
    }

    @Test
    func buildsFromStreamOfferProto() throws {
        var offer = Catlaser_App_V1_StreamOffer()
        offer.livekitURL = "wss://livekit.test"
        offer.subscriberToken = "xyz"
        let creds = try LiveStreamCredentials(offer: offer, allowlist: makeAllowlist())
        #expect(creds.url.absoluteString == "wss://livekit.test")
        #expect(creds.token == "xyz")
    }

    @Test
    func rejectsEmptyOfferURL() throws {
        var offer = Catlaser_App_V1_StreamOffer()
        offer.livekitURL = ""
        offer.subscriberToken = "xyz"
        let allow = try makeAllowlist()
        #expect(throws: LiveStreamCredentialsError.invalidURL) {
            _ = try LiveStreamCredentials(offer: offer, allowlist: allow)
        }
    }

    // MARK: - Host allowlist

    /// The primary guarantee behind fix H2: a URL whose host is NOT
    /// in the app's operator-provisioned allowlist is refused. A
    /// compromised device that hands the app a well-formed
    /// `wss://attacker.example/...` offer cannot steer the subscriber
    /// dial at an attacker-controlled LiveKit server.
    @Test
    func rejectsHostOutsideAllowlist() throws {
        let allow = try makeAllowlist(hosts: ["livekit.example.com"])
        #expect(throws: LiveStreamCredentialsError.hostNotAllowed("attacker.example")) {
            _ = try LiveStreamCredentials(
                url: URL(string: "wss://attacker.example")!,
                token: "abc",
                allowlist: allow,
            )
        }
    }

    @Test
    func allowlistMatchIsCaseInsensitive() throws {
        // DNS names are case-insensitive; the allowlist must not
        // turn a legitimate UPPERCASE hostname into a rejection.
        let allow = try makeAllowlist(hosts: ["livekit.example.com"])
        let creds = try LiveStreamCredentials(
            url: URL(string: "wss://LiveKit.Example.COM")!,
            token: "abc",
            allowlist: allow,
        )
        #expect(creds.url.host == "LiveKit.Example.COM")
    }

    @Test
    func allowlistOnMultipleHosts() throws {
        let allow = try makeAllowlist(hosts: ["lk1.example", "lk2.example"])
        #expect((try? LiveStreamCredentials(
            url: URL(string: "wss://lk1.example")!,
            token: "a",
            allowlist: allow,
        )) != nil)
        #expect((try? LiveStreamCredentials(
            url: URL(string: "wss://lk2.example")!,
            token: "a",
            allowlist: allow,
        )) != nil)
        #expect(throws: LiveStreamCredentialsError.hostNotAllowed("lk3.example")) {
            _ = try LiveStreamCredentials(
                url: URL(string: "wss://lk3.example")!,
                token: "a",
                allowlist: allow,
            )
        }
    }

    @Test
    func streamOfferPathEnforcesAllowlist() throws {
        // The production path is proto-decode → `init(offer:allowlist:)`.
        // Must refuse an out-of-list host even though the scheme is
        // valid — regression guard against someone who might "forget"
        // to thread the allowlist through the offer init.
        var offer = Catlaser_App_V1_StreamOffer()
        offer.livekitURL = "wss://attacker.example"
        offer.subscriberToken = "xyz"
        let allow = try makeAllowlist(hosts: ["livekit.example.com"])
        #expect(throws: LiveStreamCredentialsError.hostNotAllowed("attacker.example")) {
            _ = try LiveStreamCredentials(offer: offer, allowlist: allow)
        }
    }

    @Test
    func allowlistConstructionRejectsEmpty() {
        #expect(throws: LiveKitHostAllowlistError.empty) {
            _ = try LiveKitHostAllowlist(hosts: [])
        }
        #expect(throws: LiveKitHostAllowlistError.empty) {
            _ = try LiveKitHostAllowlist(hosts: ["", "   "])
        }
    }

    @Test
    func allowlistContainsIsCaseAndWhitespaceInsensitive() throws {
        let allow = try LiveKitHostAllowlist(hosts: ["  LIVEKIT.example.COM  "])
        #expect(allow.contains("livekit.example.com"))
        #expect(allow.contains("LIVEKIT.EXAMPLE.COM"))
        #expect(!allow.contains("other.example.com"))
        #expect(!allow.contains(""))
    }
}
