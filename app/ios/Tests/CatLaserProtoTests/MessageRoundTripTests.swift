import Foundation
import SwiftProtobuf
import Testing

@testable import CatLaserProto

@Suite("Message round-trip")
struct MessageRoundTripTests {
    @Test
    func catProfile() throws {
        var msg = Catlaser_App_V1_CatProfile()
        msg.catID = "cat-7f3a9c"
        msg.name = "Mochi"
        msg.thumbnail = Data([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0xff, 0xd9])
        msg.preferredSpeed = 0.72
        msg.preferredSmoothing = 0.45
        msg.patternRandomness = 0.31
        msg.totalSessions = 184
        msg.totalPlayTimeSec = 72_540
        msg.totalTreats = 563
        msg.createdAt = 1_700_000_000

        let decoded = try Catlaser_App_V1_CatProfile(serializedData: msg.serializedData())
        #expect(decoded == msg)
    }

    @Test
    func playSession() throws {
        var msg = Catlaser_App_V1_PlaySession()
        msg.sessionID = "sess-2026-04-16T18:00:00Z"
        msg.startTime = 1_744_826_400
        msg.endTime = 1_744_827_240
        msg.catIds = ["cat-7f3a9c", "cat-b1d204"]
        msg.durationSec = 840
        msg.engagementScore = 0.87
        msg.treatsDispensed = 3
        msg.pounceCount = 42

        let decoded = try Catlaser_App_V1_PlaySession(serializedData: msg.serializedData())
        #expect(decoded == msg)
    }

    @Test
    func scheduleEntry() throws {
        var msg = Catlaser_App_V1_ScheduleEntry()
        msg.entryID = "sched-evening"
        msg.startMinute = 18 * 60 + 30
        msg.durationMin = 15
        msg.days = [.monday, .wednesday, .friday]
        msg.enabled = true

        let decoded = try Catlaser_App_V1_ScheduleEntry(serializedData: msg.serializedData())
        #expect(decoded == msg)
    }

    @Test
    func statusUpdate() throws {
        var msg = Catlaser_App_V1_StatusUpdate()
        msg.hopperLevel = .low
        msg.sessionActive = true
        msg.activeCatIds = ["cat-7f3a9c", "cat-b1d204"]
        msg.uptimeSec = 86_400 * 3 + 1800
        msg.firmwareVersion = "1.2.3-rc4"

        let decoded = try Catlaser_App_V1_StatusUpdate(serializedData: msg.serializedData())
        #expect(decoded == msg)
    }

    @Test
    func sessionSummary() throws {
        var msg = Catlaser_App_V1_SessionSummary()
        msg.catIds = ["cat-7f3a9c", "cat-b1d204"]
        msg.durationSec = 840
        msg.engagementScore = 0.87
        msg.treatsDispensed = 3
        msg.pounceCount = 42
        msg.endedAt = 1_744_827_240

        let decoded = try Catlaser_App_V1_SessionSummary(serializedData: msg.serializedData())
        #expect(decoded == msg)
    }

    @Test
    func newCatDetected() throws {
        var msg = Catlaser_App_V1_NewCatDetected()
        msg.trackIDHint = 9001
        msg.thumbnail = Data((0 ..< 256).map { UInt8($0) })
        msg.confidence = 0.9123

        let decoded = try Catlaser_App_V1_NewCatDetected(serializedData: msg.serializedData())
        #expect(decoded == msg)
    }

    @Test
    func diagnosticResult() throws {
        var msg = Catlaser_App_V1_DiagnosticResult()
        msg.diagnosticType = .dispenserCycle
        msg.passed = false
        msg.details = "disc stalled at rotation 3 of 5"

        let decoded = try Catlaser_App_V1_DiagnosticResult(serializedData: msg.serializedData())
        #expect(decoded == msg)
    }

    @Test
    func streamOffer() throws {
        var msg = Catlaser_App_V1_StreamOffer()
        msg.livekitURL = "wss://livekit.example.com"
        msg.subscriberToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.sig"

        let decoded = try Catlaser_App_V1_StreamOffer(serializedData: msg.serializedData())
        #expect(decoded == msg)
    }

    @Test
    func deviceError() throws {
        var msg = Catlaser_App_V1_DeviceError()
        msg.code = 42
        msg.message = "hopper jammed; manual intervention required"

        let decoded = try Catlaser_App_V1_DeviceError(serializedData: msg.serializedData())
        #expect(decoded == msg)
    }

    @Test
    func identifyNewCatRequest() throws {
        var msg = Catlaser_App_V1_IdentifyNewCatRequest()
        msg.trackIDHint = 9001
        msg.name = "Biscuit"

        let decoded = try Catlaser_App_V1_IdentifyNewCatRequest(serializedData: msg.serializedData())
        #expect(decoded == msg)
    }

    @Test
    func runDiagnosticRequest() throws {
        var msg = Catlaser_App_V1_RunDiagnosticRequest()
        msg.diagnosticType = .full

        let decoded = try Catlaser_App_V1_RunDiagnosticRequest(serializedData: msg.serializedData())
        #expect(decoded == msg)
    }

    @Test
    func registerPushTokenRequest() throws {
        var msg = Catlaser_App_V1_RegisterPushTokenRequest()
        msg.token = "f9b28c0a3e1d7f24_apns"
        msg.platform = .apns

        let decoded = try Catlaser_App_V1_RegisterPushTokenRequest(serializedData: msg.serializedData())
        #expect(decoded == msg)
    }

    @Test
    func unregisterPushTokenRequest() throws {
        var msg = Catlaser_App_V1_UnregisterPushTokenRequest()
        msg.token = "f9b28c0a3e1d7f24_apns"

        let decoded = try Catlaser_App_V1_UnregisterPushTokenRequest(serializedData: msg.serializedData())
        #expect(decoded == msg)
    }

    @Test
    func deleteCatProfileRequest() throws {
        var msg = Catlaser_App_V1_DeleteCatProfileRequest()
        msg.catID = "cat-7f3a9c"

        let decoded = try Catlaser_App_V1_DeleteCatProfileRequest(serializedData: msg.serializedData())
        #expect(decoded == msg)
    }

    @Test
    func getPlayHistoryRequest() throws {
        var msg = Catlaser_App_V1_GetPlayHistoryRequest()
        msg.startTime = 1_744_000_000
        msg.endTime = 1_744_900_000

        let decoded = try Catlaser_App_V1_GetPlayHistoryRequest(serializedData: msg.serializedData())
        #expect(decoded == msg)
    }

    @Test
    func setScheduleRequest() throws {
        var entry1 = Catlaser_App_V1_ScheduleEntry()
        entry1.entryID = "morning"
        entry1.startMinute = 7 * 60
        entry1.durationMin = 10
        entry1.days = [.saturday, .sunday]
        entry1.enabled = true

        var entry2 = Catlaser_App_V1_ScheduleEntry()
        entry2.entryID = "evening"
        entry2.startMinute = 18 * 60 + 30
        entry2.durationMin = 15
        entry2.days = [.monday, .wednesday, .friday]
        entry2.enabled = false

        var msg = Catlaser_App_V1_SetScheduleRequest()
        msg.entries = [entry1, entry2]

        let decoded = try Catlaser_App_V1_SetScheduleRequest(serializedData: msg.serializedData())
        #expect(decoded == msg)
    }

    @Test
    func updateCatProfileRequest() throws {
        var profile = Catlaser_App_V1_CatProfile()
        profile.catID = "cat-7f3a9c"
        profile.name = "Mochi"
        profile.preferredSpeed = 0.72

        var msg = Catlaser_App_V1_UpdateCatProfileRequest()
        msg.profile = profile

        let decoded = try Catlaser_App_V1_UpdateCatProfileRequest(serializedData: msg.serializedData())
        #expect(decoded == msg)
        #expect(decoded.hasProfile)
        #expect(decoded.profile == profile)
    }

    @Test
    func updateCatProfileRequestUnset() throws {
        let msg = Catlaser_App_V1_UpdateCatProfileRequest()
        let decoded = try Catlaser_App_V1_UpdateCatProfileRequest(serializedData: msg.serializedData())
        #expect(!decoded.hasProfile)
    }

    @Test(arguments: [
        ("StartSessionRequest", Catlaser_App_V1_StartSessionRequest.self as any SwiftProtobuf.Message.Type),
        ("StopSessionRequest", Catlaser_App_V1_StopSessionRequest.self),
        ("GetStatusRequest", Catlaser_App_V1_GetStatusRequest.self),
        ("GetCatProfilesRequest", Catlaser_App_V1_GetCatProfilesRequest.self),
        ("StartStreamRequest", Catlaser_App_V1_StartStreamRequest.self),
        ("StopStreamRequest", Catlaser_App_V1_StopStreamRequest.self),
        ("GetScheduleRequest", Catlaser_App_V1_GetScheduleRequest.self),
        ("HopperEmpty", Catlaser_App_V1_HopperEmpty.self),
        ("PushTokenAck", Catlaser_App_V1_PushTokenAck.self),
    ])
    func emptyMessage(_ name: String, _ type: any SwiftProtobuf.Message.Type) throws {
        let original = type.init()
        let bytes = try original.serializedData()
        #expect(bytes.isEmpty, "\(name) empty instance must encode to zero bytes")

        let decoded = try type.init(serializedData: bytes)
        #expect(decoded.isEqualTo(message: original), "\(name) round-trip mismatch")
    }

    @Test
    func catProfileListEmpty() throws {
        let msg = Catlaser_App_V1_CatProfileList()
        let decoded = try Catlaser_App_V1_CatProfileList(serializedData: msg.serializedData())
        #expect(decoded == msg)
        #expect(decoded.profiles.isEmpty)
    }

    @Test
    func catProfileListPopulated() throws {
        var a = Catlaser_App_V1_CatProfile()
        a.catID = "cat-a"
        a.name = "Alpha"
        var b = Catlaser_App_V1_CatProfile()
        b.catID = "cat-b"
        b.name = "Beta"

        var msg = Catlaser_App_V1_CatProfileList()
        msg.profiles = [a, b]

        let decoded = try Catlaser_App_V1_CatProfileList(serializedData: msg.serializedData())
        #expect(decoded == msg)
        #expect(decoded.profiles.count == 2)
    }

    @Test
    func playHistoryResponseEmpty() throws {
        let msg = Catlaser_App_V1_PlayHistoryResponse()
        let decoded = try Catlaser_App_V1_PlayHistoryResponse(serializedData: msg.serializedData())
        #expect(decoded == msg)
        #expect(decoded.sessions.isEmpty)
    }

    @Test
    func playHistoryResponsePopulated() throws {
        var s1 = Catlaser_App_V1_PlaySession()
        s1.sessionID = "s1"
        s1.durationSec = 300
        var s2 = Catlaser_App_V1_PlaySession()
        s2.sessionID = "s2"
        s2.durationSec = 600

        var msg = Catlaser_App_V1_PlayHistoryResponse()
        msg.sessions = [s1, s2]

        let decoded = try Catlaser_App_V1_PlayHistoryResponse(serializedData: msg.serializedData())
        #expect(decoded == msg)
        #expect(decoded.sessions.count == 2)
    }

    @Test
    func scheduleListEmpty() throws {
        let msg = Catlaser_App_V1_ScheduleList()
        let decoded = try Catlaser_App_V1_ScheduleList(serializedData: msg.serializedData())
        #expect(decoded == msg)
        #expect(decoded.entries.isEmpty)
    }

    @Test
    func scheduleListPopulated() throws {
        var e1 = Catlaser_App_V1_ScheduleEntry()
        e1.entryID = "e1"
        e1.startMinute = 420
        e1.durationMin = 10
        e1.days = [.tuesday]
        e1.enabled = true

        var e2 = Catlaser_App_V1_ScheduleEntry()
        e2.entryID = "e2"
        e2.startMinute = 1110
        e2.durationMin = 15
        e2.days = [.saturday, .sunday]
        e2.enabled = false

        var msg = Catlaser_App_V1_ScheduleList()
        msg.entries = [e1, e2]

        let decoded = try Catlaser_App_V1_ScheduleList(serializedData: msg.serializedData())
        #expect(decoded == msg)
        #expect(decoded.entries.count == 2)
    }
}
