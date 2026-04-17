import Foundation
import SwiftProtobuf
import Testing

@testable import CatLaserProto

@Suite("Enums")
struct EnumTests {
    // MARK: HopperLevel

    @Test
    func hopperLevelAllCases() {
        #expect(Catlaser_App_V1_HopperLevel.allCases == [.unspecified, .ok, .low, .empty])
    }

    @Test
    func hopperLevelDefault() {
        #expect(Catlaser_App_V1_HopperLevel() == .unspecified)
    }

    @Test
    func hopperLevelRawValues() {
        #expect(Catlaser_App_V1_HopperLevel.unspecified.rawValue == 0)
        #expect(Catlaser_App_V1_HopperLevel.ok.rawValue == 1)
        #expect(Catlaser_App_V1_HopperLevel.low.rawValue == 2)
        #expect(Catlaser_App_V1_HopperLevel.empty.rawValue == 3)
    }

    @Test
    func hopperLevelUnrecognized() throws {
        let unknown = Catlaser_App_V1_HopperLevel(rawValue: 99)
        #expect(unknown == .UNRECOGNIZED(99))
        #expect(unknown?.rawValue == 99)
    }

    @Test(arguments: [
        Catlaser_App_V1_HopperLevel.unspecified,
        .ok, .low, .empty,
    ])
    func hopperLevelRoundTrips(value: Catlaser_App_V1_HopperLevel) throws {
        var msg = Catlaser_App_V1_StatusUpdate()
        msg.hopperLevel = value

        let decoded = try Catlaser_App_V1_StatusUpdate(serializedData: msg.serializedData())
        #expect(decoded.hopperLevel == value)
    }

    // MARK: DiagnosticType

    @Test
    func diagnosticTypeAllCases() {
        #expect(Catlaser_App_V1_DiagnosticType.allCases == [
            .unspecified, .servoSweep, .laserTest, .cameraCheck, .dispenserCycle, .full,
        ])
    }

    @Test
    func diagnosticTypeDefault() {
        #expect(Catlaser_App_V1_DiagnosticType() == .unspecified)
    }

    @Test
    func diagnosticTypeRawValues() {
        #expect(Catlaser_App_V1_DiagnosticType.unspecified.rawValue == 0)
        #expect(Catlaser_App_V1_DiagnosticType.servoSweep.rawValue == 1)
        #expect(Catlaser_App_V1_DiagnosticType.laserTest.rawValue == 2)
        #expect(Catlaser_App_V1_DiagnosticType.cameraCheck.rawValue == 3)
        #expect(Catlaser_App_V1_DiagnosticType.dispenserCycle.rawValue == 4)
        #expect(Catlaser_App_V1_DiagnosticType.full.rawValue == 5)
    }

    @Test
    func diagnosticTypeUnrecognized() {
        let unknown = Catlaser_App_V1_DiagnosticType(rawValue: 128)
        #expect(unknown == .UNRECOGNIZED(128))
        #expect(unknown?.rawValue == 128)
    }

    @Test(arguments: [
        Catlaser_App_V1_DiagnosticType.unspecified,
        .servoSweep, .laserTest, .cameraCheck, .dispenserCycle, .full,
    ])
    func diagnosticTypeRoundTrips(value: Catlaser_App_V1_DiagnosticType) throws {
        var msg = Catlaser_App_V1_DiagnosticResult()
        msg.diagnosticType = value
        msg.passed = true
        msg.details = "ok"

        let decoded = try Catlaser_App_V1_DiagnosticResult(serializedData: msg.serializedData())
        #expect(decoded.diagnosticType == value)
    }

    // MARK: PushPlatform

    @Test
    func pushPlatformAllCases() {
        #expect(Catlaser_App_V1_PushPlatform.allCases == [.unspecified, .fcm, .apns])
    }

    @Test
    func pushPlatformDefault() {
        #expect(Catlaser_App_V1_PushPlatform() == .unspecified)
    }

    @Test
    func pushPlatformRawValues() {
        #expect(Catlaser_App_V1_PushPlatform.unspecified.rawValue == 0)
        #expect(Catlaser_App_V1_PushPlatform.fcm.rawValue == 1)
        #expect(Catlaser_App_V1_PushPlatform.apns.rawValue == 2)
    }

    @Test
    func pushPlatformUnrecognized() {
        let unknown = Catlaser_App_V1_PushPlatform(rawValue: 42)
        #expect(unknown == .UNRECOGNIZED(42))
        #expect(unknown?.rawValue == 42)
    }

    @Test(arguments: [
        Catlaser_App_V1_PushPlatform.unspecified,
        .fcm, .apns,
    ])
    func pushPlatformRoundTrips(value: Catlaser_App_V1_PushPlatform) throws {
        var msg = Catlaser_App_V1_RegisterPushTokenRequest()
        msg.token = "tok"
        msg.platform = value

        let decoded = try Catlaser_App_V1_RegisterPushTokenRequest(serializedData: msg.serializedData())
        #expect(decoded.platform == value)
    }

    // MARK: DayOfWeek

    @Test
    func dayOfWeekAllCases() {
        #expect(Catlaser_App_V1_DayOfWeek.allCases == [
            .unspecified, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday,
        ])
    }

    @Test
    func dayOfWeekDefault() {
        #expect(Catlaser_App_V1_DayOfWeek() == .unspecified)
    }

    @Test
    func dayOfWeekRawValues() {
        #expect(Catlaser_App_V1_DayOfWeek.unspecified.rawValue == 0)
        #expect(Catlaser_App_V1_DayOfWeek.monday.rawValue == 1)
        #expect(Catlaser_App_V1_DayOfWeek.tuesday.rawValue == 2)
        #expect(Catlaser_App_V1_DayOfWeek.wednesday.rawValue == 3)
        #expect(Catlaser_App_V1_DayOfWeek.thursday.rawValue == 4)
        #expect(Catlaser_App_V1_DayOfWeek.friday.rawValue == 5)
        #expect(Catlaser_App_V1_DayOfWeek.saturday.rawValue == 6)
        #expect(Catlaser_App_V1_DayOfWeek.sunday.rawValue == 7)
    }

    @Test
    func dayOfWeekUnrecognized() {
        let unknown = Catlaser_App_V1_DayOfWeek(rawValue: 12)
        #expect(unknown == .UNRECOGNIZED(12))
        #expect(unknown?.rawValue == 12)
    }

    @Test(arguments: [
        Catlaser_App_V1_DayOfWeek.unspecified,
        .monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday,
    ])
    func dayOfWeekRoundTrips(value: Catlaser_App_V1_DayOfWeek) throws {
        var msg = Catlaser_App_V1_ScheduleEntry()
        msg.entryID = "e"
        msg.days = [value]

        let decoded = try Catlaser_App_V1_ScheduleEntry(serializedData: msg.serializedData())
        #expect(decoded.days == [value])
    }
}
