#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import CatLaserDeviceTestSupport
import CatLaserProto
import Foundation
import Testing

@testable import CatLaserDevice

@Suite("DeviceClient")
struct DeviceClientTests {
    // MARK: - Helpers

    private func makeClient(
        requestTimeout: TimeInterval = 5.0,
    ) -> (DeviceClient, InMemoryDeviceTransport) {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(
            transport: transport,
            requestTimeout: requestTimeout,
        )
        return (client, transport)
    }

    /// Build a (client, transport, signer) triple wired with a real
    /// ``HandshakeResponseVerifier``. Tests that exercise the
    /// handshake path use this so the production-shape contract
    /// (handshake without verifier is forbidden) is honoured.
    private func makeAuthenticatedClient(
        requestTimeout: TimeInterval = 5.0,
    ) -> (DeviceClient, InMemoryDeviceTransport, Curve25519.Signing.PrivateKey) {
        let signer = Curve25519.Signing.PrivateKey()
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(
            transport: transport,
            requestTimeout: requestTimeout,
            responseVerifier: HandshakeResponseVerifier(
                devicePublicKey: signer.publicKey.rawRepresentation,
            ),
        )
        return (client, transport, signer)
    }

    /// Build an ``AuthResponse`` `DeviceEvent` properly signed by
    /// `signer` so a real ``HandshakeResponseVerifier`` accepts it.
    /// Centralised so each handshake-path test does not have to
    /// reimplement the transcript layout.
    fileprivate static func signedAuthResponseEvent(
        nonce: Data,
        requestID: UInt32,
        signer: Curve25519.Signing.PrivateKey,
        ok: Bool = true,
        reason: String = "",
        signedAt: Date = Date(),
    ) throws -> Catlaser_App_V1_DeviceEvent {
        let signedAtNs = Int64(signedAt.timeIntervalSince1970 * 1_000_000_000)
        let transcript = HandshakeResponseVerifier.buildTranscript(
            nonce: nonce,
            signedAtUnixNs: signedAtNs,
            ok: ok,
            reason: reason,
        )
        let signature = try signer.signature(for: transcript)
        var event = Catlaser_App_V1_DeviceEvent()
        event.requestID = requestID
        var response = Catlaser_App_V1_AuthResponse()
        response.ok = ok
        response.reason = reason
        response.nonce = nonce
        response.signature = signature
        response.signedAtUnixNs = signedAtNs
        event.authResponse = response
        return event
    }

    private func catProfileListEvent(names: [String]) -> Catlaser_App_V1_DeviceEvent {
        var list = Catlaser_App_V1_CatProfileList()
        list.profiles = names.map { name in
            var cat = Catlaser_App_V1_CatProfile()
            cat.name = name
            return cat
        }
        var event = Catlaser_App_V1_DeviceEvent()
        event.catProfileList = list
        return event
    }

    // MARK: - Happy path

    @Test
    func connectOpensTransportAndConsumesFrames() async throws {
        let (client, transport) = makeClient()
        try await client.connect()
        #expect(await client.isConnected)

        // Fire a request, read what the client wrote, reply, check correlation.
        var request = Catlaser_App_V1_AppRequest()
        request.getCatProfiles = Catlaser_App_V1_GetCatProfilesRequest()

        async let response: Catlaser_App_V1_DeviceEvent = client.request(request)

        let outgoing = try await transport.nextAppRequest(timeout: 2.0)
        #expect(outgoing.requestID != 0)
        #expect(outgoing.getCatProfiles == Catlaser_App_V1_GetCatProfilesRequest())

        var reply = catProfileListEvent(names: ["Mochi", "Biscuit"])
        reply.requestID = outgoing.requestID
        try transport.deliver(event: reply)

        let received = try await response
        #expect(received.requestID == outgoing.requestID)
        #expect(received.catProfileList.profiles.count == 2)

        await client.disconnect()
    }

    // MARK: - Concurrent requests

    @Test
    func concurrentRequestsRouteByRequestID() async throws {
        let (client, transport) = makeClient()
        try await client.connect()

        var ping = Catlaser_App_V1_AppRequest()
        ping.getStatus = Catlaser_App_V1_GetStatusRequest()

        var cats = Catlaser_App_V1_AppRequest()
        cats.getCatProfiles = Catlaser_App_V1_GetCatProfilesRequest()

        async let pingResult: Catlaser_App_V1_DeviceEvent = client.request(ping)
        async let catsResult: Catlaser_App_V1_DeviceEvent = client.request(cats)

        // Collect both outbound requests (order-independent).
        let first = try await transport.nextAppRequest(timeout: 2.0)
        let second = try await transport.nextAppRequest(timeout: 2.0)
        let outbound = [first, second]
        #expect(Set(outbound.map(\.requestID)).count == 2)
        #expect(outbound.contains(where: {
            if case .getStatus = $0.request { true } else { false }
        }))
        #expect(outbound.contains(where: {
            if case .getCatProfiles = $0.request { true } else { false }
        }))

        // Reply out-of-order: cats first, then status.
        let cats_rid = outbound.first(where: {
            if case .getCatProfiles = $0.request { true } else { false }
        })!.requestID
        let status_rid = outbound.first(where: {
            if case .getStatus = $0.request { true } else { false }
        })!.requestID

        var catsReply = catProfileListEvent(names: ["Mochi"])
        catsReply.requestID = cats_rid
        try transport.deliver(event: catsReply)

        var statusReply = Catlaser_App_V1_DeviceEvent()
        var status = Catlaser_App_V1_StatusUpdate()
        status.uptimeSec = 42
        statusReply.statusUpdate = status
        statusReply.requestID = status_rid
        try transport.deliver(event: statusReply)

        let (pingEvent, catsEvent) = try await (pingResult, catsResult)
        #expect(pingEvent.statusUpdate.uptimeSec == 42)
        #expect(catsEvent.catProfileList.profiles.first?.name == "Mochi")

        await client.disconnect()
    }

    // MARK: - Fire-and-forget

    @Test
    func sendDoesNotWaitAndUsesZeroID() async throws {
        let (client, transport) = makeClient()
        try await client.connect()

        var request = Catlaser_App_V1_AppRequest()
        request.stopSession = Catlaser_App_V1_StopSessionRequest()
        try await client.send(request)

        let outgoing = try await transport.nextAppRequest(timeout: 2.0)
        #expect(outgoing.requestID == 0)

        await client.disconnect()
    }

    // MARK: - Unsolicited events

    @Test
    func unsolicitedEventsStreamOnEventsProperty() async throws {
        let (client, transport) = makeClient()
        try await client.connect()

        // Consume one unsolicited status_update with request_id=0.
        var beat = Catlaser_App_V1_DeviceEvent()
        var status = Catlaser_App_V1_StatusUpdate()
        status.uptimeSec = 7
        beat.statusUpdate = status
        try transport.deliver(event: beat)

        var iterator = client.events.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received?.statusUpdate.uptimeSec == 7)

        await client.disconnect()
    }

    // MARK: - Remote error

    @Test
    func remoteDeviceErrorMapsToRemoteCase() async throws {
        let (client, transport) = makeClient()
        try await client.connect()

        var request = Catlaser_App_V1_AppRequest()
        request.startStream = Catlaser_App_V1_StartStreamRequest()

        async let result: Catlaser_App_V1_DeviceEvent = client.request(request)

        let outgoing = try await transport.nextAppRequest(timeout: 2.0)
        var errorEvent = Catlaser_App_V1_DeviceEvent()
        var err = Catlaser_App_V1_DeviceError()
        err.code = 3
        err.message = "streaming not configured"
        errorEvent.error = err
        errorEvent.requestID = outgoing.requestID
        try transport.deliver(event: errorEvent)

        do {
            _ = try await result
            Issue.record("expected throw")
        } catch let DeviceClientError.remote(code, message) {
            #expect(code == 3)
            #expect(message == "streaming not configured")
        } catch {
            Issue.record("wrong error: \(error)")
        }

        await client.disconnect()
    }

    // MARK: - Disconnect failures

    @Test
    func peerHalfCloseFailsAllPendingAndClosesClient() async throws {
        let (client, transport) = makeClient()
        try await client.connect()

        var request = Catlaser_App_V1_AppRequest()
        request.getStatus = Catlaser_App_V1_GetStatusRequest()
        async let result: Catlaser_App_V1_DeviceEvent = client.request(request)

        // Wait for the send so the pending map is populated.
        _ = try await transport.nextAppRequest(timeout: 2.0)
        transport.finishPeer()

        do {
            _ = try await result
            Issue.record("expected throw on peer close")
        } catch let DeviceClientError.closedByPeer {
            // Good.
        } catch {
            Issue.record("wrong error: \(error)")
        }

        #expect(await !client.isConnected)
    }

    @Test
    func requestBeforeConnectFails() async throws {
        let (client, _) = makeClient()
        var request = Catlaser_App_V1_AppRequest()
        request.getStatus = Catlaser_App_V1_GetStatusRequest()
        do {
            _ = try await client.request(request)
            Issue.record("expected throw")
        } catch DeviceClientError.notConnected {
            // Good.
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test
    func doubleConnectFails() async throws {
        let (client, _) = makeClient()
        try await client.connect()
        do {
            try await client.connect()
            Issue.record("expected throw")
        } catch DeviceClientError.alreadyConnected {
            // Good.
        } catch {
            Issue.record("wrong error: \(error)")
        }
        await client.disconnect()
    }

    @Test
    func disconnectIsIdempotent() async throws {
        let (client, _) = makeClient()
        try await client.connect()
        await client.disconnect()
        await client.disconnect()
        #expect(await !client.isConnected)
    }

    // MARK: - Timeout

    @Test
    func requestTimesOutWhenNoReplyArrives() async throws {
        let (client, transport) = makeClient(requestTimeout: 0.1)
        try await client.connect()
        var request = Catlaser_App_V1_AppRequest()
        request.getStatus = Catlaser_App_V1_GetStatusRequest()

        async let result: Catlaser_App_V1_DeviceEvent = client.request(request)
        _ = try await transport.nextAppRequest(timeout: 2.0)

        do {
            _ = try await result
            Issue.record("expected timeout")
        } catch DeviceClientError.requestTimedOut {
            // Good.
        } catch {
            Issue.record("wrong error: \(error)")
        }

        await client.disconnect()
    }

    // MARK: - Framing robustness

    @Test
    func frameReassemblyAcrossMultipleDeliveries() async throws {
        let (client, transport) = makeClient()
        try await client.connect()

        var request = Catlaser_App_V1_AppRequest()
        request.getStatus = Catlaser_App_V1_GetStatusRequest()
        async let result: Catlaser_App_V1_DeviceEvent = client.request(request)

        let outgoing = try await transport.nextAppRequest(timeout: 2.0)

        var reply = Catlaser_App_V1_DeviceEvent()
        var status = Catlaser_App_V1_StatusUpdate()
        status.firmwareVersion = "x.y.z"
        reply.statusUpdate = status
        reply.requestID = outgoing.requestID

        let payload = try reply.serializedData()
        let frame = try FrameCodec.encode(payload)
        // Deliver byte-by-byte to make sure the client reassembles.
        for byte in frame {
            transport.deliver(Data([byte]))
        }

        let received = try await result
        #expect(received.statusUpdate.firmwareVersion == "x.y.z")

        await client.disconnect()
    }

    @Test
    func malformedFramePayloadTearsConnectionDown() async throws {
        let (client, transport) = makeClient()
        try await client.connect()

        var request = Catlaser_App_V1_AppRequest()
        request.getStatus = Catlaser_App_V1_GetStatusRequest()
        async let result: Catlaser_App_V1_DeviceEvent = client.request(request)
        let outgoing = try await transport.nextAppRequest(timeout: 2.0)
        _ = outgoing

        // Write a frame whose declared length is valid but the bytes
        // aren't a valid DeviceEvent.
        let bogus = Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        let frame = try FrameCodec.encode(bogus)
        transport.deliver(frame)

        do {
            _ = try await result
            Issue.record("expected throw on malformed payload")
        } catch DeviceClientError.malformedFrame, DeviceClientError.closedByPeer {
            // Either is acceptable — the client tears down on the
            // decode failure, and pending continuations fail with the
            // error.
        } catch {
            Issue.record("wrong error: \(error)")
        }

        #expect(await !client.isConnected)
    }

    // MARK: - ScriptedDeviceServer integration

    @Test
    func scriptedServerRoundTripsStreamOffer() async throws {
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(transport: transport)
        let server = ScriptedDeviceServer(transport: transport) { request in
            switch request.request {
            case .startStream:
                var offer = Catlaser_App_V1_StreamOffer()
                offer.livekitURL = "wss://livekit.test.local"
                offer.subscriberToken = "token-xyz"
                var event = Catlaser_App_V1_DeviceEvent()
                event.streamOffer = offer
                return .reply(event)
            default:
                return .error(code: 2, message: "unknown")
            }
        }

        try await client.connect()
        await server.run()

        var request = Catlaser_App_V1_AppRequest()
        request.startStream = Catlaser_App_V1_StartStreamRequest()

        let response = try await client.request(request)
        if case let .streamOffer(offer) = response.event {
            #expect(offer.livekitURL == "wss://livekit.test.local")
            #expect(offer.subscriberToken == "token-xyz")
        } else {
            Issue.record("expected stream_offer")
        }

        await server.stop()
        await client.disconnect()
    }

    // MARK: - Device-auth handshake (fix #2)

    @Test
    func handshakeHappyPathSendsAuthRequestAndAcceptsResponse() async throws {
        // The client MUST send the handshake as its first frame. The
        // scripted server echoes a properly-signed AuthResponse(ok=true)
        // — production wiring requires a verifier whenever a handshake
        // is supplied, so the response must validate under the
        // verifier's pubkey or `connect` rejects with
        // `.handshakeSignatureInvalid` regardless of the `ok` bit.
        // After the handshake, normal request/response continues to
        // work.
        let (client, transport, signer) = makeAuthenticatedClient()
        // ``Curve25519.Signing.PrivateKey`` is not ``Sendable``; capture
        // its raw bytes (which are) and reconstruct the signer inside
        // the handler closure.
        let signerRaw = signer.rawRepresentation
        let server = ScriptedDeviceServer(transport: transport) { request in
            if case let .auth(authReq) = request.request {
                guard let signerCopy = try? Curve25519.Signing.PrivateKey(rawRepresentation: signerRaw),
                      let event = try? Self.signedAuthResponseEvent(
                          nonce: authReq.nonce,
                          requestID: request.requestID,
                          signer: signerCopy,
                      )
                else {
                    return .silent
                }
                return .reply(event)
            }
            // The post-handshake GetStatus ping verifies the connection
            // is usable end-to-end.
            var event = Catlaser_App_V1_DeviceEvent()
            event.statusUpdate = Catlaser_App_V1_StatusUpdate()
            return .reply(event)
        }
        await server.run()

        try await client.connect {
            "attestation-header-value"
        }

        var ping = Catlaser_App_V1_AppRequest()
        ping.getStatus = Catlaser_App_V1_GetStatusRequest()
        let response = try await client.request(ping)
        if case .statusUpdate = response.event {
            // good
        } else {
            Issue.record("expected status_update event, got \(String(describing: response.event))")
        }

        await server.stop()
        await client.disconnect()
    }

    @Test
    func handshakeRejectedResponseThrowsHandshakeFailed() async throws {
        // The server says ok=false with a specific reason — but the
        // response is signed by the genuine device key, so the verifier
        // accepts the signature and the client honours the rejection.
        // `isConnected` must read false after the throw so callers
        // can drive reconnect with backoff.
        //
        // The signed-rejection path is load-bearing: a signed `ok=false`
        // is the ONLY way an attacker can convince the client to give
        // up on a session. An impostor cannot forge a signed `ok=false`
        // (they don't have the device's private key), and a forged
        // unsigned `ok=false` lands on `.handshakeSignatureInvalid`,
        // which the supervisor treats as transient — preventing a
        // denial-of-pairing attack from a tunnel-internal MitM.
        let (client, transport, signer) = makeAuthenticatedClient()
        let signerRaw = signer.rawRepresentation
        let server = ScriptedDeviceServer(transport: transport) { request in
            if case let .auth(authReq) = request.request {
                guard let signerCopy = try? Curve25519.Signing.PrivateKey(rawRepresentation: signerRaw),
                      let event = try? Self.signedAuthResponseEvent(
                          nonce: authReq.nonce,
                          requestID: request.requestID,
                          signer: signerCopy,
                          ok: false,
                          reason: "DEVICE_AUTH_NOT_AUTHORIZED",
                      )
                else {
                    return .silent
                }
                return .reply(event)
            }
            return .silent
        }
        await server.run()

        do {
            try await client.connect {
                "attestation-header-value"
            }
            Issue.record("expected throw")
        } catch let error as DeviceClientError {
            if case let .handshakeFailed(reason) = error {
                #expect(reason == "DEVICE_AUTH_NOT_AUTHORIZED")
            } else {
                Issue.record("expected handshakeFailed, got \(error)")
            }
        }
        #expect(!(await client.isConnected))
        await server.stop()
    }

    @Test
    func handshakeBlockFailureSurfacesAsHandshakeFailed() async throws {
        // The attestation builder itself can throw (e.g. SE key
        // unavailable, clock out of range). The error must be mapped
        // to `.handshakeFailed` so `ConnectionManager`'s reconnect
        // loop handles it like a server rejection. The verifier is
        // wired (production-shape), but the builder fails before any
        // handshake frame is sent so the verifier is never consulted.
        let (client, transport, _) = makeAuthenticatedClient()
        let server = ScriptedDeviceServer(transport: transport) { _ in .silent }
        await server.run()

        do {
            try await client.connect {
                struct BuilderFailure: Error {}
                throw BuilderFailure()
            }
            Issue.record("expected throw")
        } catch let error as DeviceClientError {
            if case let .handshakeFailed(reason) = error {
                #expect(reason.contains("attestation build failed"))
            } else {
                Issue.record("expected handshakeFailed, got \(error)")
            }
        }
        #expect(!(await client.isConnected))
        await server.stop()
    }

    @Test
    func handshakeReplyOfWrongKindFailsCleanly() async throws {
        // The server's first reply is anything other than
        // AuthResponse (simulating a protocol regression). The
        // client must refuse to treat it as a successful handshake
        // and must close the connection. The verifier is wired
        // (production-shape) but is never consulted because the
        // event isn't an AuthResponse — the type-of-event check
        // fires first.
        let (client, transport, _) = makeAuthenticatedClient()
        let server = ScriptedDeviceServer(transport: transport) { request in
            if case .auth = request.request {
                var event = Catlaser_App_V1_DeviceEvent()
                event.statusUpdate = Catlaser_App_V1_StatusUpdate()
                return .reply(event)
            }
            return .silent
        }
        await server.run()

        do {
            try await client.connect {
                "attestation-header-value"
            }
            Issue.record("expected throw")
        } catch let error as DeviceClientError {
            if case let .handshakeFailed(reason) = error {
                #expect(reason.contains("was not AuthResponse"))
            } else {
                Issue.record("expected handshakeFailed, got \(error)")
            }
        }
        #expect(!(await client.isConnected))
        await server.stop()
    }

    // MARK: - ACL revocation (fix for per-connection auth caching)

    /// An unsolicited `DeviceError { code: AUTH_REVOKED }` sent by the
    /// device after an ACL snapshot removed the user's SPKI must
    /// terminate the connection and fail all in-flight requests with
    /// `.authRevoked(message:)` — NOT `.closedByPeer` — so the
    /// supervisor can distinguish "re-pair required" from a transport
    /// drop.
    @Test
    func authRevokedUnsolicitedEventFailsPendingWithAuthRevoked() async throws {
        let (client, transport) = makeClient()
        try await client.connect()

        var request = Catlaser_App_V1_AppRequest()
        request.getStatus = Catlaser_App_V1_GetStatusRequest()
        async let result: Catlaser_App_V1_DeviceEvent = client.request(request)

        // Wait for the client to send the request so its continuation
        // is registered — otherwise the unsolicited event arrives
        // before there's anything to fail.
        _ = try await transport.nextAppRequest(timeout: 2.0)

        var revokeEvent = Catlaser_App_V1_DeviceEvent()
        var err = Catlaser_App_V1_DeviceError()
        err.code = DeviceClientError.authRevokedCode
        err.message = "device access revoked; re-pair to continue"
        revokeEvent.error = err
        // request_id=0 ⇒ unsolicited push, matching the Python daemon.
        try transport.deliver(event: revokeEvent)

        do {
            _ = try await result
            Issue.record("expected throw on auth revocation")
        } catch let DeviceClientError.authRevoked(message) {
            #expect(message.contains("revoked"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
        // The client must have closed itself — a subsequent request
        // returns notConnected rather than hitting the (now torn down)
        // transport.
        #expect(await !client.isConnected)
    }

    /// PRE-HANDSHAKE AUTH_REVOKED MUST NOT BE HONOURED.
    ///
    /// Threat model: an impostor that wins the TCP-accept race on the
    /// Tailscale endpoint (or a tunnel-internal MitM) can write a
    /// `DeviceError(code: AUTH_REVOKED, request_id: 0)` frame onto the
    /// connection BEFORE the handshake's Ed25519 verification has had
    /// a chance to fail. The pre-fix behaviour took that signal at
    /// face value and routed it through `ConnectionManager` to
    /// `PairingViewModel.unpairAfterRevocation`, wiping the keychain
    /// pairing — a permanent denial-of-pairing with no cryptographic
    /// gate.
    ///
    /// The fix: `handleFrame` only honours `AUTH_REVOKED` when
    /// `state == .connected`, i.e. AFTER the handshake has succeeded
    /// and the device's `AuthResponse` has verified under the paired
    /// public key. Pre-handshake the frame flows through normal
    /// routing (request_id 0 → events stream) and is discarded.
    /// This test forges the impostor's pre-handshake AUTH_REVOKED and
    /// asserts the connect path surfaces a NON-terminal error
    /// (handshake reply was wrong kind, not authRevoked) — the
    /// supervisor's transient-failure path takes over and the pairing
    /// survives.
    @Test
    func preHandshakeAuthRevokedFrameDoesNotTriggerTerminalRevocation() async throws {
        // Production-shape client: verifier wired, handshake builder
        // supplied. The scripted server sends an AUTH_REVOKED
        // unsolicited frame INSTEAD of an AuthResponse — exactly what
        // an impostor that doesn't have the device's private key would
        // do (it can't sign a valid AuthResponse, but it can echo any
        // unsigned bytes).
        let (client, transport, _) = makeAuthenticatedClient(requestTimeout: 1.0)
        let server = ScriptedDeviceServer(transport: transport) { request in
            if case .auth = request.request {
                // Forge AUTH_REVOKED with request_id 0 — the wire shape
                // a tunnel-internal attacker would push hoping to
                // trigger the early-handle path. Because we are still
                // in `.handshaking`, the early-handle gate refuses to
                // honour it; the frame reaches the events stream and
                // the handshake reply path eventually sees the absence
                // of an AuthResponse for the request_id we sent.
                var event = Catlaser_App_V1_DeviceEvent()
                var err = Catlaser_App_V1_DeviceError()
                err.code = DeviceClientError.authRevokedCode
                err.message = "FORGED — should be ignored pre-handshake"
                event.error = err
                event.requestID = 0
                return .reply(event)
            }
            return .silent
        }
        await server.run()

        do {
            try await client.connect { "header" }
            Issue.record("expected handshake to fail on missing AuthResponse")
        } catch let error as DeviceClientError {
            // Critical assertion: the error is NOT
            // `.authRevoked(...)` and is NOT
            // `isTerminalAuthRevocation`. A request timeout (the
            // handshake's pending `AuthRequest` was never answered
            // with an AuthResponse) is the expected outcome — the
            // forged AUTH_REVOKED with request_id 0 went to the
            // events stream and the handshake's pending continuation
            // timed out waiting for a properly-correlated reply.
            #expect(!error.isTerminalAuthRevocation,
                    "pre-handshake AUTH_REVOKED must NOT classify as terminal — got \(error)")
            if case .authRevoked = error {
                Issue.record("pre-handshake AUTH_REVOKED leaked into terminal path")
            }
        }
        #expect(!(await client.isConnected))
        await server.stop()
    }

    /// VERIFIER REQUIRED WHEN HANDSHAKE IS PROVIDED.
    ///
    /// A `connect(handshake:)` call without a verifier wired at
    /// init MUST fail loudly with `.handshakeVerifierMissing` BEFORE
    /// the builder closure runs (so no Secure-Enclave signing op
    /// burns and no wire bytes leak). This is the type-system
    /// invariant that prevents a refactor from accidentally
    /// constructing a production-shape DeviceClient that would
    /// silently accept a forged `AuthResponse` from any party that
    /// can speak the wire framing.
    @Test
    func handshakeWithoutVerifierThrowsBeforeAnyWireWork() async throws {
        let transport = InMemoryDeviceTransport()
        // No verifier passed — production-shape contract violation.
        let client = DeviceClient(
            transport: transport,
            requestTimeout: 1.0,
        )
        let builderCalls = BuilderCallCounter()
        do {
            try await client.connect { [builderCalls] in
                await builderCalls.increment()
                return "header"
            }
            Issue.record("expected throw on missing verifier")
        } catch let error as DeviceClientError {
            #expect(error == .handshakeVerifierMissing)
        }
        #expect(await builderCalls.count == 0,
                "verifier-missing gate must reject BEFORE the builder is invoked — no SE signing op should burn")
        #expect(!(await client.isConnected))
    }

    /// Tiny actor-backed counter used by the verifier-missing test
    /// to observe whether the handshake builder was ever invoked.
    /// Sendable so it can be captured in the `@Sendable` closure.
    private actor BuilderCallCounter {
        private(set) var count: Int = 0
        func increment() { count += 1 }
    }

    /// The terminal-auth classifier must stay in sync with the two
    /// wire signals that carry the revocation. A regression here would
    /// let `ConnectionManager` keep reconnecting against an endpoint
    /// that is guaranteed to reject every future handshake.
    @Test
    func isTerminalAuthRevocationClassification() {
        #expect(DeviceClientError.authRevoked(message: "anything").isTerminalAuthRevocation)
        #expect(DeviceClientError.handshakeFailed(reason: "DEVICE_AUTH_NOT_AUTHORIZED").isTerminalAuthRevocation)
        // Transient auth states: ACL not primed yet, clock skew,
        // replay-detected — not terminal; reconnect-with-backoff is
        // the correct behavior. The replay-detected path in particular
        // MUST be non-terminal: an honest client's next attestation
        // signs with a fresh ECDSA k and therefore produces a fresh
        // signature that does not collide with the cached replay
        // tuple, so the retry naturally self-heals.
        #expect(!DeviceClientError.handshakeFailed(reason: "DEVICE_AUTH_ACL_NOT_READY").isTerminalAuthRevocation)
        #expect(!DeviceClientError.handshakeFailed(reason: "DEVICE_AUTH_SKEW_EXCEEDED").isTerminalAuthRevocation)
        #expect(!DeviceClientError.handshakeFailed(reason: DeviceClientError.handshakeReasonReplayDetected).isTerminalAuthRevocation)
        #expect(!DeviceClientError.closedByPeer.isTerminalAuthRevocation)
        #expect(!DeviceClientError.transport("network down").isTerminalAuthRevocation)
        #expect(!DeviceClientError.requestTimedOut.isTerminalAuthRevocation)
    }

    // MARK: - Handshake-stage gating

    @Test
    func publicRequestIsRefusedWhileHandshakeIsInFlight() async throws {
        // The public `request` API must refuse to transmit until the
        // mandatory first-frame `AuthRequest` handshake has completed
        // and the device has accepted us. The scenario:
        //
        //   1. `connect(handshake:)` is called. It opens the transport
        //      (successful), enters `.handshaking`, builds and sends
        //      the AuthRequest, then awaits the AuthResponse.
        //   2. During that await, `DeviceClient` is an actor and
        //      reentrant — a second task that can reach the client
        //      reference COULD call `request(_:)`.
        //   3. The contract is that such a call MUST throw
        //      `.notConnected` so a non-AuthRequest frame cannot race
        //      the handshake onto the wire. The server enforces this
        //      by dropping any connection whose first frame is not
        //      `AuthRequest`, but the app-side gate prevents us from
        //      emitting such a frame at all.
        //
        // The test constructs a handshake builder that never returns
        // until the test explicitly unblocks it. Meanwhile, a
        // concurrent `request(_:)` call is issued — it must throw
        // synchronously, without ever seeing the wire.
        let (client, transport, signer) = makeAuthenticatedClient()
        let gate = HandshakeGate()
        async let connectResult: Void = client.connect(handshake: {
            // Park until the test resumes us. Once resumed, return a
            // syntactically-valid-but-test-irrelevant header string —
            // the test drives the response path directly below via
            // `transport.deliver`.
            await gate.wait()
            return "handshake-header"
        })

        // Wait until the client has entered `.handshaking`.
        // `isConnected` must be false during this window.
        while await client.isConnected {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(await client.isConnected == false)

        // Issue a parallel public request. It must be refused with
        // `.notConnected` because we are in `.handshaking`. We do NOT
        // drive the wire — if the gate were broken and the frame went
        // out, the test would detect it via a non-throwing branch.
        var statusReq = Catlaser_App_V1_AppRequest()
        statusReq.getStatus = Catlaser_App_V1_GetStatusRequest()
        do {
            _ = try await client.request(statusReq)
            Issue.record("expected .notConnected; a request slipped past the handshake gate")
        } catch let error as DeviceClientError {
            #expect(error == .notConnected)
        }

        // Unblock the handshake and complete it with a properly-signed
        // AuthResponse. The AuthRequest frame should be the FIRST and
        // ONLY frame on the outbound path at this point.
        await gate.release()
        let firstFrame = try await transport.nextAppRequest(timeout: 2.0)
        #expect(firstFrame.request != nil)
        if case .auth = firstFrame.request {
            // correct: handshake frame landed first
        } else {
            Issue.record("first outbound frame was not AuthRequest: \(String(describing: firstFrame.request))")
        }
        let ok = try Self.signedAuthResponseEvent(
            nonce: firstFrame.auth.nonce,
            requestID: firstFrame.requestID,
            signer: signer,
        )
        try transport.deliver(event: ok)
        try await connectResult

        // Post-handshake the public gate opens and the same call
        // succeeds (driven via the standard request/response dance).
        #expect(await client.isConnected)
        await client.disconnect()
    }

    @Test
    func publicSendIsRefusedWhileHandshakeIsInFlight() async throws {
        // Matching coverage for the fire-and-forget `send` path: it
        // must also gate on `.connected`, not `.handshaking`, so an
        // attacker or buggy caller cannot smuggle a non-auth frame
        // past the handshake using the zero-request_id path.
        let (client, transport, signer) = makeAuthenticatedClient()
        let gate = HandshakeGate()
        async let connectResult: Void = client.connect(handshake: {
            await gate.wait()
            return "handshake-header"
        })

        while await client.isConnected {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        var stopReq = Catlaser_App_V1_AppRequest()
        stopReq.stopSession = Catlaser_App_V1_StopSessionRequest()
        do {
            try await client.send(stopReq)
            Issue.record("expected .notConnected on send during handshake")
        } catch let error as DeviceClientError {
            #expect(error == .notConnected)
        }

        await gate.release()
        let first = try await transport.nextAppRequest(timeout: 2.0)
        if case .auth = first.request {
            // correct
        } else {
            Issue.record("first frame after unblock was not AuthRequest")
        }
        let ok = try Self.signedAuthResponseEvent(
            nonce: first.auth.nonce,
            requestID: first.requestID,
            signer: signer,
        )
        try transport.deliver(event: ok)
        try await connectResult

        await client.disconnect()
    }

    @Test
    func connectReachesConnectedOnlyAfterSuccessfulHandshake() async throws {
        // Regression guard: `isConnected` must be false during
        // `.handshaking` and true only after the AuthResponse(ok=true)
        // lands. A prior implementation flipped the flag to true
        // before the handshake and relied on composition discipline
        // to keep callers out — the type system now enforces it.
        let (client, transport, signer) = makeAuthenticatedClient()
        async let connectResult: Void = client.connect(handshake: { "header" })

        let auth = try await transport.nextAppRequest(timeout: 2.0)
        #expect(await client.isConnected == false,
                "isConnected must remain false during .handshaking")

        let reply = try Self.signedAuthResponseEvent(
            nonce: auth.auth.nonce,
            requestID: auth.requestID,
            signer: signer,
        )
        try transport.deliver(event: reply)
        try await connectResult

        #expect(await client.isConnected)
        await client.disconnect()
    }

    @Test
    func handshakeRejectionClosesClientWithoutFlippingToConnected() async throws {
        // A signed `ok=false` AuthResponse must surface the typed
        // `handshakeFailed(reason:)` error and leave the client in a
        // terminal state — it must never transition to `.connected`.
        let (client, transport, signer) = makeAuthenticatedClient()
        async let connectResult: Void = client.connect(handshake: { "header" })

        let auth = try await transport.nextAppRequest(timeout: 2.0)
        let reply = try Self.signedAuthResponseEvent(
            nonce: auth.auth.nonce,
            requestID: auth.requestID,
            signer: signer,
            ok: false,
            reason: "DEVICE_AUTH_NOT_AUTHORIZED",
        )
        try transport.deliver(event: reply)

        do {
            try await connectResult
            Issue.record("expected handshake rejection to throw")
        } catch let error as DeviceClientError {
            if case let .handshakeFailed(reason) = error {
                #expect(reason == "DEVICE_AUTH_NOT_AUTHORIZED")
            } else {
                Issue.record("expected .handshakeFailed, got \(error)")
            }
        }

        // The client is terminal; isConnected must be false and any
        // further send attempt must be refused.
        #expect(await client.isConnected == false)
        var req = Catlaser_App_V1_AppRequest()
        req.getStatus = Catlaser_App_V1_GetStatusRequest()
        do {
            _ = try await client.request(req)
            Issue.record("expected post-rejection request to throw")
        } catch let error as DeviceClientError {
            #expect(error == .notConnected)
        }
    }

    // MARK: - Handshake response verification (Ed25519)

    @Test
    func authRequestCarriesANonceOfCorrectLength() async throws {
        // The client-side nonce is 16 bytes — matches the device's
        // NONCE_LENGTH constant. A different length would make the
        // device reject the handshake with DEVICE_AUTH_NONCE_INVALID.
        let (client, transport, signer) = makeAuthenticatedClient()
        async let connectResult: Void = client.connect(handshake: { "header" })
        let auth = try await transport.nextAppRequest(timeout: 2.0)
        #expect(auth.auth.nonce.count == 16)

        // Reply with a properly-signed ok response so the handshake
        // completes — production-shape handshake requires a verifier
        // and a verifying signature on the response.
        let reply = try Self.signedAuthResponseEvent(
            nonce: auth.auth.nonce,
            requestID: auth.requestID,
            signer: signer,
        )
        try transport.deliver(event: reply)
        try await connectResult
        await client.disconnect()
    }

    @Test
    func handshakeRejectsResponseFromWrongSigningKey() async throws {
        // Wire a verifier that expects signatures under pubkey A; the
        // device server (mock) signs with pubkey B. The client must
        // reject with `.handshakeSignatureInvalid` and refuse to
        // transition to `.connected`.
        let genuineKey = Curve25519.Signing.PrivateKey()
        let impostorKey = Curve25519.Signing.PrivateKey()
        let verifier = HandshakeResponseVerifier(
            devicePublicKey: genuineKey.publicKey.rawRepresentation,
        )
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(
            transport: transport,
            requestTimeout: 2.0,
            responseVerifier: verifier,
        )
        async let connectResult: Void = client.connect(handshake: { "header" })
        let auth = try await transport.nextAppRequest(timeout: 2.0)

        // Forge an AuthResponse signed by the WRONG key.
        let signedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        let transcript = HandshakeResponseVerifier.buildTranscript(
            nonce: auth.auth.nonce,
            signedAtUnixNs: signedAt,
            ok: true,
            reason: "",
        )
        let badSignature = try impostorKey.signature(for: transcript)
        var reply = Catlaser_App_V1_DeviceEvent()
        reply.requestID = auth.requestID
        reply.authResponse = Catlaser_App_V1_AuthResponse()
        reply.authResponse.ok = true
        reply.authResponse.nonce = auth.auth.nonce
        reply.authResponse.signature = badSignature
        reply.authResponse.signedAtUnixNs = signedAt
        try transport.deliver(event: reply)

        do {
            try await connectResult
            Issue.record("expected throw when impostor signs response")
        } catch let error as DeviceClientError {
            #expect(error == .handshakeSignatureInvalid)
        }
        #expect(await client.isConnected == false)
    }

    @Test
    func handshakeAcceptsResponseFromCorrectKey() async throws {
        let genuineKey = Curve25519.Signing.PrivateKey()
        let verifier = HandshakeResponseVerifier(
            devicePublicKey: genuineKey.publicKey.rawRepresentation,
        )
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(
            transport: transport,
            requestTimeout: 2.0,
            responseVerifier: verifier,
        )
        async let connectResult: Void = client.connect(handshake: { "header" })
        let auth = try await transport.nextAppRequest(timeout: 2.0)

        let signedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        let transcript = HandshakeResponseVerifier.buildTranscript(
            nonce: auth.auth.nonce,
            signedAtUnixNs: signedAt,
            ok: true,
            reason: "",
        )
        let signature = try genuineKey.signature(for: transcript)
        var reply = Catlaser_App_V1_DeviceEvent()
        reply.requestID = auth.requestID
        reply.authResponse = Catlaser_App_V1_AuthResponse()
        reply.authResponse.ok = true
        reply.authResponse.nonce = auth.auth.nonce
        reply.authResponse.signature = signature
        reply.authResponse.signedAtUnixNs = signedAt
        try transport.deliver(event: reply)

        try await connectResult
        #expect(await client.isConnected == true)
        await client.disconnect()
    }

    @Test
    func handshakeRejectsReplayedResponseAgainstFreshNonce() async throws {
        // A captured AuthResponse (valid signature, from the real
        // device) cannot be replayed against a *fresh* AuthRequest
        // because the fresh request's nonce differs from the one the
        // signature binds to. The verifier's nonce-echo check
        // catches this before crypto work.
        let genuineKey = Curve25519.Signing.PrivateKey()
        let verifier = HandshakeResponseVerifier(
            devicePublicKey: genuineKey.publicKey.rawRepresentation,
        )
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(
            transport: transport,
            requestTimeout: 2.0,
            responseVerifier: verifier,
        )
        async let connectResult: Void = client.connect(handshake: { "header" })
        let auth = try await transport.nextAppRequest(timeout: 2.0)

        // Sign a response bound to a DIFFERENT nonce (what a
        // captured-response attacker would have on hand). Both
        // transcript nonce and echoed nonce are the old value.
        let oldNonce = Data(repeating: 0xAA, count: 16)
        let signedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        let transcript = HandshakeResponseVerifier.buildTranscript(
            nonce: oldNonce,
            signedAtUnixNs: signedAt,
            ok: true,
            reason: "",
        )
        let signature = try genuineKey.signature(for: transcript)
        var reply = Catlaser_App_V1_DeviceEvent()
        reply.requestID = auth.requestID
        reply.authResponse = Catlaser_App_V1_AuthResponse()
        reply.authResponse.ok = true
        reply.authResponse.nonce = oldNonce // echoes the OLD nonce
        reply.authResponse.signature = signature
        reply.authResponse.signedAtUnixNs = signedAt
        try transport.deliver(event: reply)

        do {
            try await connectResult
            Issue.record("expected replay to be rejected")
        } catch let error as DeviceClientError {
            #expect(error == .handshakeNonceMismatch)
        }
    }

    @Test
    func handshakeRejectsResponseSignedLongAgo() async throws {
        // The attacker replayed a perfectly-valid response whose
        // timestamp is outside the ±5-minute skew window. Even if a
        // nonce collision somehow occurred (2⁻¹²⁸), the timestamp
        // covered by the signature gives the verifier a second line
        // of defence.
        let genuineKey = Curve25519.Signing.PrivateKey()
        let verifier = HandshakeResponseVerifier(
            devicePublicKey: genuineKey.publicKey.rawRepresentation,
        )
        let transport = InMemoryDeviceTransport()
        let client = DeviceClient(
            transport: transport,
            requestTimeout: 2.0,
            responseVerifier: verifier,
        )
        async let connectResult: Void = client.connect(handshake: { "header" })
        let auth = try await transport.nextAppRequest(timeout: 2.0)

        // Sign a response whose signed_at is 10 minutes in the past.
        let staleSignedAt: Int64 = Int64((Date().timeIntervalSince1970 - 600) * 1_000_000_000)
        let transcript = HandshakeResponseVerifier.buildTranscript(
            nonce: auth.auth.nonce,
            signedAtUnixNs: staleSignedAt,
            ok: true,
            reason: "",
        )
        let signature = try genuineKey.signature(for: transcript)
        var reply = Catlaser_App_V1_DeviceEvent()
        reply.requestID = auth.requestID
        reply.authResponse = Catlaser_App_V1_AuthResponse()
        reply.authResponse.ok = true
        reply.authResponse.nonce = auth.auth.nonce
        reply.authResponse.signature = signature
        reply.authResponse.signedAtUnixNs = staleSignedAt
        try transport.deliver(event: reply)

        do {
            try await connectResult
            Issue.record("expected stale timestamp to be rejected")
        } catch let error as DeviceClientError {
            #expect(error == .handshakeSkewExceeded)
        }
    }
}

/// Test-only gate used to stall a handshake builder until the test
/// explicitly releases it. Mirrors the role of a real
/// `DeviceAttestationProviding` that could take a non-trivial time
/// to produce a signed header, giving us a controlled window in
/// which to exercise the `.handshaking` state.
private actor HandshakeGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
    }

    func release() {
        released = true
        let snap = waiters
        waiters.removeAll()
        for c in snap { c.resume() }
    }
}
