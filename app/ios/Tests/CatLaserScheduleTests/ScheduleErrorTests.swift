import CatLaserDevice
import Foundation
import Testing

@testable import CatLaserSchedule

/// Mapping table for ``ScheduleError.from(_:)``. The history-screen
/// companion (``HistoryErrorTests``) has the same shape — the
/// mapping is the single seam between the device-client error
/// space and the screen presentation space, and a regression that,
/// say, collapsed ``requestTimedOut`` into ``transportFailure``
/// would lose the "the device MAY have already written" distinction
/// the UI needs to render a "refresh to verify" hint rather than a
/// generic retry prompt.
@Suite("ScheduleError mapping")
struct ScheduleErrorTests {
    @Test
    func notConnectedAndClosedByPeerMapToNotConnected() {
        #expect(ScheduleError.from(.notConnected) == .notConnected)
        #expect(ScheduleError.from(.closedByPeer) == .notConnected)
    }

    @Test
    func transportErrorsCarryReason() {
        if case let .transportFailure(reason) = ScheduleError.from(.transport("ECONNRESET")) {
            #expect(reason == "ECONNRESET")
        } else {
            Issue.record("expected .transportFailure")
        }
        if case let .transportFailure(reason) = ScheduleError.from(.connectFailed("no route")) {
            #expect(reason == "no route")
        } else {
            Issue.record("expected .transportFailure for .connectFailed")
        }
    }

    @Test
    func timeoutMapsToTimeout() {
        #expect(ScheduleError.from(.requestTimedOut) == .timeout)
    }

    @Test
    func remoteErrorsRetainCodeAndMessage() {
        let mapped = ScheduleError.from(.remote(code: 99, message: "boom"))
        if case let .deviceError(code, message) = mapped {
            #expect(code == 99)
            #expect(message == "boom")
        } else {
            Issue.record("expected .deviceError, got \(mapped)")
        }
    }

    @Test
    func wrongEventKindRetainsExpectedAndGot() {
        let mapped = ScheduleError.from(.wrongEventKind(expected: "schedule", got: "status_update"))
        if case let .wrongEventKind(expected, got) = mapped {
            #expect(expected == "schedule")
            #expect(got == "status_update")
        } else {
            Issue.record("expected .wrongEventKind, got \(mapped)")
        }
    }

    @Test
    func malformedFrameMapsToInternalFailure() {
        if case .internalFailure = ScheduleError.from(.malformedFrame("bad varint")) {
            // good
        } else {
            Issue.record("expected .internalFailure for .malformedFrame")
        }
    }

    @Test
    func frameTooLargeCarriesBounds() {
        let mapped = ScheduleError.from(.frameTooLarge(length: 1_000, limit: 512))
        if case let .internalFailure(reason) = mapped {
            #expect(reason.contains("1000"))
            #expect(reason.contains("512"))
        } else {
            Issue.record("expected .internalFailure for .frameTooLarge")
        }
    }

    @Test
    func handshakeFailuresCollapseToTransportFailure() {
        // Supervisor owns re-pair / clock-sync routing; at the
        // schedule screen layer we collapse to "can't talk to the
        // device" so the user just sees the retry affordance.
        for clientError: DeviceClientError in [
            .handshakeNonceMismatch,
            .handshakeSkewExceeded,
            .handshakeSignatureInvalid,
        ] {
            if case .transportFailure = ScheduleError.from(clientError) {
                // good
            } else {
                Issue.record("expected .transportFailure for \(clientError)")
            }
        }
        if case .transportFailure = ScheduleError.from(.handshakeFailed(reason: "DEVICE_AUTH_NOT_AUTHORIZED")) {
            // good
        } else {
            Issue.record("expected .transportFailure for handshakeFailed")
        }
        if case .transportFailure = ScheduleError.from(.authRevoked(message: "kicked")) {
            // good
        } else {
            Issue.record("expected .transportFailure for authRevoked")
        }
    }

    @Test
    func handshakeVerifierMissingMapsToInternalFailure() {
        if case .internalFailure = ScheduleError.from(.handshakeVerifierMissing) {
            // good
        } else {
            Issue.record("expected .internalFailure for handshakeVerifierMissing")
        }
    }

    @Test
    func cancelledMapsToInternalFailure() {
        if case .internalFailure = ScheduleError.from(.cancelled) {
            // good
        } else {
            Issue.record("expected .internalFailure for cancelled")
        }
    }

    @Test
    func alreadyConnectedMapsToInternalFailure() {
        if case .internalFailure = ScheduleError.from(.alreadyConnected) {
            // good
        } else {
            Issue.record("expected .internalFailure for alreadyConnected")
        }
    }

    @Test
    func encodingFailedMapsToInternalFailure() {
        if case .internalFailure = ScheduleError.from(.encodingFailed("bad proto")) {
            // good
        } else {
            Issue.record("expected .internalFailure for encodingFailed")
        }
    }
}
