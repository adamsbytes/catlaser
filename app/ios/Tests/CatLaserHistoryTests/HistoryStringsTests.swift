import Foundation
import Testing

@testable import CatLaserHistory

/// The localisation surface guarantees that every ``HistoryError``
/// case resolves to a non-empty user-facing message. A refactor that
/// adds a new error case without an accompanying localisation row
/// would otherwise ship to users as an empty banner — the assertion
/// here is what catches that mistake before it reaches a release.
@Suite("HistoryStrings")
struct HistoryStringsTests {
    /// Every variant the screen can surface. Update this list when
    /// new error cases are added.
    private let cases: [HistoryError] = [
        .notConnected,
        .transportFailure("ECONNRESET"),
        .timeout,
        .deviceError(code: 42, message: "device boom"),
        .deviceError(code: 42, message: ""),
        .notFound("cat xyz not found"),
        .wrongEventKind(expected: "cat_profile_list", got: "status_update"),
        .validation(HistoryStrings.validationNameEmpty),
        .internalFailure("client bug"),
    ]

    @Test
    func everyErrorResolvesToNonEmptyMessage() {
        for error in cases {
            let message = HistoryStrings.message(for: error)
            #expect(!message.isEmpty, "empty message for \(error)")
            // Internal-failure / generic messages must NOT echo the
            // underlying technical reason — those belong in logs,
            // not the UI banner. The presence-check below is a soft
            // belt-and-braces: a refactor that started wrapping the
            // associated string into the message would alert here.
            switch error {
            case let .internalFailure(reason),
                 let .transportFailure(reason):
                #expect(!message.contains(reason),
                        "user-facing message must not echo developer reason: \(message)")
            case let .deviceError(_, deviceMessage) where !deviceMessage.isEmpty:
                #expect(!message.contains(deviceMessage),
                        "user-facing message must not echo device-side message: \(message)")
            default:
                break
            }
        }
    }

    @Test
    func deviceErrorMessageNeverLeaksServerString() {
        // The device-side message is a developer artefact (Python
        // traceback fragments, protocol diagnostics). The screen always
        // surfaces the stable generic copy regardless of whether a
        // message was supplied — the device handler is NOT a presentation
        // policy owner.
        let withMessage = HistoryStrings.message(for: .deviceError(code: 9, message: "internal: foo"))
        let withoutMessage = HistoryStrings.message(for: .deviceError(code: 9, message: ""))
        #expect(withMessage == withoutMessage)
        #expect(!withMessage.contains("internal"))
        #expect(!withMessage.contains("foo"))
        #expect(!withMessage.isEmpty)
    }

    @Test
    func validationMessageRoundtripsField() {
        // The validation message is surfaced verbatim because it is
        // already localised at the point it is produced (by
        // ``HistoryViewModel.validateName(_:)``).
        let custom = "Use letters only."
        let message = HistoryStrings.message(for: .validation(custom))
        #expect(message == custom)
    }
}
