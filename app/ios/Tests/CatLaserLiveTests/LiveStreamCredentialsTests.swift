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
        // turn a legitimate UPPERCASE hostname into a rejection. The
        // canonical form the LiveKit SDK is handed is lowercased so a
        // URL parser disagreement on case (some libraries treat the
        // host case-sensitively) cannot drive a host the allowlist
        // didn't see — see the parser-disagreement defense in
        // ``LiveStreamCredentials``.
        let allow = try makeAllowlist(hosts: ["livekit.example.com"])
        let creds = try LiveStreamCredentials(
            url: URL(string: "wss://LiveKit.Example.COM")!,
            token: "abc",
            allowlist: allow,
        )
        #expect(creds.url.host == "livekit.example.com")
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

    // MARK: - Parser-disagreement defense (Finding 4)
    //
    // The LiveKit SDK re-parses the URL string we hand it. If
    // Foundation's `URL.host` extracts a different host than
    // LiveKit's parser, an attacker-supplied StreamOffer can pass
    // the allowlist check while the SDK dials a different host.
    // The fix: refuse URLs containing userinfo / fragment, and
    // rebuild the URL from individually-validated components so the
    // string we hand the SDK contains exactly the scheme/host/port/
    // path/query we approved.

    /// Userinfo (`user:pass@host`) is the canonical parser-
    /// disagreement vector. RFC 3986-strict parsers extract
    /// `host` from after the `@`; some lenient parsers take
    /// `host` from before. We refuse the URL outright rather than
    /// trust either interpretation.
    @Test
    func rejectsURLWithUserinfo() throws {
        let allow = try makeAllowlist(hosts: ["livekit.example.com"])
        // Foundation parses this with `user = "livekit.example.com"`
        // and `host = "attacker.com"`; without the userinfo gate the
        // app would correctly reject (host fails allowlist), but the
        // explicit refusal catches every case (including ones where
        // Foundation might extract `host = "livekit.example.com"`
        // and pass the URL to LiveKit verbatim).
        var offer = Catlaser_App_V1_StreamOffer()
        offer.livekitURL = "wss://livekit.example.com:443@attacker.com/"
        offer.subscriberToken = "x"
        do {
            _ = try LiveStreamCredentials(offer: offer, allowlist: allow)
            Issue.record("expected userinfo URL to be rejected")
        } catch let error {
            // ``LiveStreamCredentials`` uses typed throws, so the
            // bare catch already binds a typed
            // ``LiveStreamCredentialsError``. Either rejection mode
            // is acceptable: the structural refusal (.invalidURL) or
            // the host-not-allowed branch. Both close the
            // parser-disagreement gap.
            switch error {
            case .invalidURL, .hostNotAllowed:
                break
            default:
                Issue.record("expected .invalidURL or .hostNotAllowed, got \(error)")
            }
        }
    }

    /// URL fragments have no place in a `wss://` dial target —
    /// LiveKit ignores them but they're a documented vector for
    /// smuggling additional state into URL parsers (some treat
    /// `#@host` as host-shifting). Refuse outright.
    @Test
    func rejectsURLWithFragment() throws {
        let allow = try makeAllowlist(hosts: ["livekit.example.com"])
        var offer = Catlaser_App_V1_StreamOffer()
        offer.livekitURL = "wss://livekit.example.com/#@attacker.com"
        offer.subscriberToken = "x"
        #expect(throws: LiveStreamCredentialsError.invalidURL) {
            _ = try LiveStreamCredentials(offer: offer, allowlist: allow)
        }
    }

    /// The URL handed to the LiveKit SDK MUST be the rebuilt
    /// canonical form, NOT the raw input. This test asserts the
    /// canonicalisation: a mixed-case host is lowercased, and the
    /// resulting `absoluteString` matches the expected canonical
    /// shape byte-for-byte.
    @Test
    func handsCanonicalLowercaseURLToTheSDK() throws {
        let allow = try makeAllowlist(hosts: ["livekit.example.com"])
        let creds = try LiveStreamCredentials(
            url: URL(string: "wss://LiveKit.Example.COM/path?room=abc")!,
            token: "abc",
            allowlist: allow,
        )
        // Lowercased host. The reconstruction guarantees the LiveKit
        // SDK sees the host the allowlist approved, not whatever
        // case the offer carried.
        #expect(creds.url.host == "livekit.example.com")
        // Path and query survived the rebuild.
        #expect(creds.url.path == "/path")
        #expect(creds.url.query == "room=abc")
        // Scheme is the operator-mandated wss:// only.
        #expect(creds.url.scheme == "wss")
    }

    /// The trailing-dot-FQDN form `host.` is equivalent to `host`
    /// in DNS but `URL.host` may include the dot, breaking the
    /// allowlist's exact match. The validator strips a single
    /// trailing dot before the allowlist lookup so the canonical
    /// form survives.
    @Test
    func acceptsTrailingDotHostAsCanonical() throws {
        let allow = try makeAllowlist(hosts: ["livekit.example.com"])
        let creds = try LiveStreamCredentials(
            url: URL(string: "wss://livekit.example.com./room")!,
            token: "abc",
            allowlist: allow,
        )
        // The canonicalised host has the dot stripped — what the
        // SDK receives matches the allowlist entry byte-for-byte.
        #expect(creds.url.host == "livekit.example.com")
    }

    /// Port survives the rebuild — operators can host LiveKit on a
    /// non-default port and we must not silently drop it.
    @Test
    func preservesExplicitPort() throws {
        let allow = try makeAllowlist(hosts: ["livekit.example.com"])
        let creds = try LiveStreamCredentials(
            url: URL(string: "wss://livekit.example.com:8443/")!,
            token: "abc",
            allowlist: allow,
        )
        #expect(creds.url.port == 8443)
        #expect(creds.url.host == "livekit.example.com")
    }

    /// Subdomain that is NOT in the allowlist must be refused even
    /// though the suffix matches. This documents that the allowlist
    /// is exact (no wildcarding); the parser-defense rebuild does
    /// not soften the membership check.
    @Test
    func rejectsSubdomainOfAllowedHost() throws {
        let allow = try makeAllowlist(hosts: ["livekit.example.com"])
        var offer = Catlaser_App_V1_StreamOffer()
        offer.livekitURL = "wss://attacker.livekit.example.com/"
        offer.subscriberToken = "x"
        #expect(throws: LiveStreamCredentialsError.hostNotAllowed("attacker.livekit.example.com")) {
            _ = try LiveStreamCredentials(offer: offer, allowlist: allow)
        }
    }

    /// Path traversal in the URL must not change the host. The
    /// rebuild preserves the path as-is (LiveKit dials whatever
    /// path the offer specified), but the host the allowlist
    /// approved is always the host the SDK sees.
    @Test
    func pathContentDoesNotInfluenceAllowlist() throws {
        let allow = try makeAllowlist(hosts: ["livekit.example.com"])
        let creds = try LiveStreamCredentials(
            url: URL(string: "wss://livekit.example.com/../@attacker.com/x")!,
            token: "abc",
            allowlist: allow,
        )
        #expect(creds.url.host == "livekit.example.com")
    }
}
