import Foundation
import SwiftProtobuf
import Testing

@testable import CatLaserProto

@Suite("Oneof variants")
struct OneofTests {
    // MARK: AppRequest

    static let appRequestCases: [(name: String, requestID: UInt32, request: Catlaser_App_V1_AppRequest.OneOf_Request)] = [
        ("startSession", 1001, .startSession(Catlaser_App_V1_StartSessionRequest())),
        ("stopSession", 1002, .stopSession(Catlaser_App_V1_StopSessionRequest())),
        ("getStatus", 1003, .getStatus(Catlaser_App_V1_GetStatusRequest())),
        ("getCatProfiles", 1004, .getCatProfiles(Catlaser_App_V1_GetCatProfilesRequest())),
        ("updateCatProfile", 1005, .updateCatProfile({
            var r = Catlaser_App_V1_UpdateCatProfileRequest()
            r.profile.catID = "cat-update"
            r.profile.name = "Updated"
            return r
        }())),
        ("deleteCatProfile", 1006, .deleteCatProfile({
            var r = Catlaser_App_V1_DeleteCatProfileRequest()
            r.catID = "cat-delete"
            return r
        }())),
        ("getPlayHistory", 1007, .getPlayHistory({
            var r = Catlaser_App_V1_GetPlayHistoryRequest()
            r.startTime = 1_700_000_000
            r.endTime = 1_700_086_400
            return r
        }())),
        ("startStream", 1008, .startStream(Catlaser_App_V1_StartStreamRequest())),
        ("stopStream", 1009, .stopStream(Catlaser_App_V1_StopStreamRequest())),
        ("setSchedule", 1010, .setSchedule({
            var r = Catlaser_App_V1_SetScheduleRequest()
            var e = Catlaser_App_V1_ScheduleEntry()
            e.entryID = "morning"
            e.startMinute = 480
            e.durationMin = 10
            e.days = [.monday]
            e.enabled = true
            r.entries = [e]
            return r
        }())),
        ("identifyNewCat", 1011, .identifyNewCat({
            var r = Catlaser_App_V1_IdentifyNewCatRequest()
            r.trackIDHint = 321
            r.name = "Named"
            return r
        }())),
        ("runDiagnostic", 1012, .runDiagnostic({
            var r = Catlaser_App_V1_RunDiagnosticRequest()
            r.diagnosticType = .full
            return r
        }())),
        ("getSchedule", 1013, .getSchedule(Catlaser_App_V1_GetScheduleRequest())),
        ("registerPushToken", 1014, .registerPushToken({
            var r = Catlaser_App_V1_RegisterPushTokenRequest()
            r.token = "tok-apns"
            r.platform = .apns
            return r
        }())),
        ("unregisterPushToken", 1015, .unregisterPushToken({
            var r = Catlaser_App_V1_UnregisterPushTokenRequest()
            r.token = "tok-apns"
            return r
        }())),
    ]

    @Test(arguments: appRequestCases)
    func appRequestRoundTrip(name: String, requestID: UInt32, request: Catlaser_App_V1_AppRequest.OneOf_Request) throws {
        var msg = Catlaser_App_V1_AppRequest()
        msg.requestID = requestID
        msg.request = request

        let decoded = try Catlaser_App_V1_AppRequest(serializedData: msg.serializedData())
        #expect(decoded.requestID == requestID, "\(name) request_id not preserved")
        #expect(decoded.request == request, "\(name) oneof mismatch after round-trip")
    }

    @Test
    func appRequestAllCasesCovered() {
        let covered = Set(OneofTests.appRequestCases.map(\.name))
        let expected: Set<String> = [
            "startSession", "stopSession", "getStatus", "getCatProfiles",
            "updateCatProfile", "deleteCatProfile", "getPlayHistory",
            "startStream", "stopStream", "setSchedule", "identifyNewCat",
            "runDiagnostic", "getSchedule", "registerPushToken",
            "unregisterPushToken",
        ]
        #expect(covered == expected)
        #expect(covered.count == 15)
    }

    @Test
    func appRequestUnsetOneofDecodesNil() throws {
        var msg = Catlaser_App_V1_AppRequest()
        msg.requestID = 77

        let decoded = try Catlaser_App_V1_AppRequest(serializedData: msg.serializedData())
        #expect(decoded.request == nil)
        #expect(decoded.requestID == 77)
    }

    @Test
    func appRequestZeroRequestID() throws {
        // Fire-and-forget: request_id == 0 must survive round-trip.
        var msg = Catlaser_App_V1_AppRequest()
        msg.requestID = 0
        msg.request = .startSession(Catlaser_App_V1_StartSessionRequest())

        let decoded = try Catlaser_App_V1_AppRequest(serializedData: msg.serializedData())
        #expect(decoded.requestID == 0)
        #expect(decoded.request == .startSession(Catlaser_App_V1_StartSessionRequest()))
    }

    // MARK: DeviceEvent

    static let deviceEventCases: [(name: String, requestID: UInt32, event: Catlaser_App_V1_DeviceEvent.OneOf_Event)] = [
        ("statusUpdate", 0, .statusUpdate({
            var u = Catlaser_App_V1_StatusUpdate()
            u.hopperLevel = .ok
            u.sessionActive = false
            u.uptimeSec = 3600
            u.firmwareVersion = "1.0.0"
            return u
        }())),
        ("catProfileList", 2001, .catProfileList({
            var l = Catlaser_App_V1_CatProfileList()
            var p = Catlaser_App_V1_CatProfile()
            p.catID = "cat-list"
            p.name = "Listed"
            l.profiles = [p]
            return l
        }())),
        ("playHistory", 2002, .playHistory({
            var r = Catlaser_App_V1_PlayHistoryResponse()
            var s = Catlaser_App_V1_PlaySession()
            s.sessionID = "s-1"
            s.durationSec = 600
            r.sessions = [s]
            return r
        }())),
        ("streamOffer", 2003, .streamOffer({
            var o = Catlaser_App_V1_StreamOffer()
            o.livekitURL = "wss://livekit"
            o.subscriberToken = "tok"
            return o
        }())),
        ("sessionSummary", 0, .sessionSummary({
            var s = Catlaser_App_V1_SessionSummary()
            s.catIds = ["cat-summary"]
            s.durationSec = 900
            s.engagementScore = 0.75
            s.treatsDispensed = 2
            s.pounceCount = 18
            s.endedAt = 1_700_000_000
            return s
        }())),
        ("newCatDetected", 0, .newCatDetected({
            var n = Catlaser_App_V1_NewCatDetected()
            n.trackIDHint = 9001
            n.thumbnail = Data([0xff, 0xd8, 0xff])
            n.confidence = 0.82
            return n
        }())),
        ("hopperEmpty", 0, .hopperEmpty(Catlaser_App_V1_HopperEmpty())),
        ("diagnosticResult", 2004, .diagnosticResult({
            var d = Catlaser_App_V1_DiagnosticResult()
            d.diagnosticType = .laserTest
            d.passed = true
            d.details = "ok"
            return d
        }())),
        ("error", 2005, .error({
            var e = Catlaser_App_V1_DeviceError()
            e.code = 500
            e.message = "internal"
            return e
        }())),
        ("schedule", 2006, .schedule({
            var l = Catlaser_App_V1_ScheduleList()
            var entry = Catlaser_App_V1_ScheduleEntry()
            entry.entryID = "e-1"
            entry.startMinute = 540
            entry.durationMin = 12
            entry.days = [.thursday]
            entry.enabled = true
            l.entries = [entry]
            return l
        }())),
        ("pushTokenAck", 2007, .pushTokenAck(Catlaser_App_V1_PushTokenAck())),
    ]

    @Test(arguments: deviceEventCases)
    func deviceEventRoundTrip(name: String, requestID: UInt32, event: Catlaser_App_V1_DeviceEvent.OneOf_Event) throws {
        var msg = Catlaser_App_V1_DeviceEvent()
        msg.requestID = requestID
        msg.event = event

        let decoded = try Catlaser_App_V1_DeviceEvent(serializedData: msg.serializedData())
        #expect(decoded.requestID == requestID, "\(name) request_id not preserved")
        #expect(decoded.event == event, "\(name) oneof mismatch after round-trip")
    }

    @Test
    func deviceEventAllCasesCovered() {
        let covered = Set(OneofTests.deviceEventCases.map(\.name))
        let expected: Set<String> = [
            "statusUpdate", "catProfileList", "playHistory", "streamOffer",
            "sessionSummary", "newCatDetected", "hopperEmpty", "diagnosticResult",
            "error", "schedule", "pushTokenAck",
        ]
        #expect(covered == expected)
        #expect(covered.count == 11)
    }

    @Test
    func deviceEventUnsetOneofDecodesNil() throws {
        var msg = Catlaser_App_V1_DeviceEvent()
        msg.requestID = 42

        let decoded = try Catlaser_App_V1_DeviceEvent(serializedData: msg.serializedData())
        #expect(decoded.event == nil)
        #expect(decoded.requestID == 42)
    }

    @Test
    func deviceEventZeroRequestID() throws {
        // Unsolicited push: request_id == 0 must survive round-trip.
        var msg = Catlaser_App_V1_DeviceEvent()
        msg.requestID = 0
        msg.event = .hopperEmpty(Catlaser_App_V1_HopperEmpty())

        let decoded = try Catlaser_App_V1_DeviceEvent(serializedData: msg.serializedData())
        #expect(decoded.requestID == 0)
        #expect(decoded.event == .hopperEmpty(Catlaser_App_V1_HopperEmpty()))
    }
}
