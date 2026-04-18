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
}
