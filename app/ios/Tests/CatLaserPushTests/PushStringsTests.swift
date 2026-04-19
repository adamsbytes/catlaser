import Foundation
import Testing

@testable import CatLaserPush

@Suite("PushStrings")
struct PushStringsTests {
    /// Every error category must resolve to a non-empty message so
    /// the failure banner never renders blank. A refactor that adds
    /// a new ``PushError`` case without a localisation row is caught
    /// here.
    @Test
    func everyErrorCaseHasANonEmptyMessage() {
        let cases: [PushError] = [
            .notConnected,
            .transportFailure("tcp dropped"),
            .timeout,
            .deviceError(code: 2, message: "unsupported push platform"),
            .deviceError(code: 99, message: ""),
            .wrongEventKind(expected: "push_token_ack", got: "error"),
            .authorizationDenied,
            .apnsRegistrationFailed("no internet"),
            .invalidToken(reason: "too short"),
            .internalFailure("encoding glitch"),
        ]
        for error in cases {
            let message = PushStrings.message(for: error)
            #expect(!message.isEmpty, "empty message for \(error)")
        }
    }

    @Test
    func deviceErrorWithMessageSurfacesVerbatim() {
        // A non-empty device-supplied message reaches the banner
        // unchanged so the user sees the server's diagnostic. An
        // empty message falls back to the generic string.
        let withMessage = PushStrings.message(
            for: .deviceError(code: 42, message: "unsupported push platform: 0"),
        )
        #expect(withMessage == "unsupported push platform: 0")

        let empty = PushStrings.message(for: .deviceError(code: 99, message: ""))
        #expect(!empty.isEmpty)
        #expect(empty != "unsupported push platform: 0")
    }
}
