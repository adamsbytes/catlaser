import CatLaserDevice
import Foundation
import Testing

@testable import CatLaserHistory

/// Mapping table for ``HistoryError.from(_:)``. The mapping is the
/// single seam between the device-client error space and the
/// history-screen presentation space; a regression that, say,
/// collapsed ``requestTimedOut`` into ``transportFailure`` would lose
/// the "device may have side-effected, retry is risky" distinction
/// the UI needs to render different copy.
@Suite("HistoryError mapping")
struct HistoryErrorTests {
    @Test
    func notConnectedMapsToNotConnected() {
        #expect(HistoryError.from(.notConnected) == .notConnected)
        #expect(HistoryError.from(.closedByPeer) == .notConnected)
    }

    @Test
    func transportErrorsCarryReason() {
        let underlying = "ECONNRESET"
        if case let .transportFailure(reason) = HistoryError.from(.transport(underlying)) {
            #expect(reason == underlying)
        } else {
            Issue.record("expected .transportFailure, got \(HistoryError.from(.transport(underlying)))")
        }
        if case let .transportFailure(reason) = HistoryError.from(.connectFailed("no route")) {
            #expect(reason == "no route")
        } else {
            Issue.record("expected .transportFailure for .connectFailed")
        }
    }

    @Test
    func timeoutMapsToTimeout() {
        #expect(HistoryError.from(.requestTimedOut) == .timeout)
    }

    @Test
    func notFoundCodeFoldsIntoTypedNotFound() {
        // The device handler emits code 4 = `_ERR_NOT_FOUND`. The
        // mapping must fold it into the typed ``notFound`` so the UI
        // can render its specific "list out of date, refreshing"
        // message rather than the generic device-error banner.
        let mapped = HistoryError.from(.remote(code: HistoryError.notFoundCode, message: "cat xyz not found"))
        if case let .notFound(message) = mapped {
            #expect(message == "cat xyz not found")
        } else {
            Issue.record("expected .notFound, got \(mapped)")
        }
    }

    @Test
    func nonNotFoundDeviceErrorsRetainCodeAndMessage() {
        let mapped = HistoryError.from(.remote(code: 99, message: "boom"))
        if case let .deviceError(code, message) = mapped {
            #expect(code == 99)
            #expect(message == "boom")
        } else {
            Issue.record("expected .deviceError, got \(mapped)")
        }
    }

    @Test
    func wrongEventKindRetainsExpectedAndGot() {
        let mapped = HistoryError.from(.wrongEventKind(expected: "play_history", got: "status_update"))
        if case let .wrongEventKind(expected, got) = mapped {
            #expect(expected == "play_history")
            #expect(got == "status_update")
        } else {
            Issue.record("expected .wrongEventKind, got \(mapped)")
        }
    }

    @Test
    func malformedFrameMapsToInternalFailure() {
        if case .internalFailure = HistoryError.from(.malformedFrame("bad varint")) {
            // good
        } else {
            Issue.record("expected .internalFailure for .malformedFrame")
        }
    }

    @Test
    func handshakeFailuresCollapseToTransportFailure() {
        // The supervisor in ``ConnectionManager`` owns the actual
        // re-pair / clock-sync routing. At the history-screen layer
        // the user just needs a "can't talk to the device right
        // now" message + a retry; folding the typed handshake errors
        // into ``transportFailure`` keeps the screen out of that
        // routing decision.
        for clientError: DeviceClientError in [
            .handshakeNonceMismatch,
            .handshakeSkewExceeded,
            .handshakeSignatureInvalid,
        ] {
            if case .transportFailure = HistoryError.from(clientError) {
                // good
            } else {
                Issue.record("expected .transportFailure for \(clientError)")
            }
        }
        if case .transportFailure = HistoryError.from(.handshakeFailed(reason: "DEVICE_AUTH_NOT_AUTHORIZED")) {
            // good
        } else {
            Issue.record("expected .transportFailure for handshakeFailed")
        }
        if case .transportFailure = HistoryError.from(.authRevoked(message: "kicked")) {
            // good
        } else {
            Issue.record("expected .transportFailure for authRevoked")
        }
    }

    @Test
    func handshakeVerifierMissingMapsToInternalFailure() {
        if case .internalFailure = HistoryError.from(.handshakeVerifierMissing) {
            // good
        } else {
            Issue.record("expected .internalFailure for handshakeVerifierMissing")
        }
    }

    @Test
    func cancelledIsClassifiedAsInternalFailureNotTransport() {
        // ``cancelled`` only reaches the screen layer if the actor
        // tore the call down without a typed remote / transport
        // cause — i.e. a client-side bug rather than a network
        // event. Mapping to ``internalFailure`` keeps the
        // observability classification correct.
        if case .internalFailure = HistoryError.from(.cancelled) {
            // good
        } else {
            Issue.record("expected .internalFailure for cancelled")
        }
    }
}
