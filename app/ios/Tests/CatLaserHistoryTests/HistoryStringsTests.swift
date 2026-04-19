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
            default:
                break
            }
        }
    }

    @Test
    func deviceErrorMessageSurfacesServerStringWhenPresent() {
        // Server-supplied messages on typed device errors are
        // surfaced verbatim — the device handler is the policy
        // owner. An empty message falls back to the generic.
        let withMessage = HistoryStrings.message(for: .deviceError(code: 9, message: "something"))
        let withoutMessage = HistoryStrings.message(for: .deviceError(code: 9, message: ""))
        #expect(withMessage == "something")
        #expect(!withoutMessage.isEmpty)
        #expect(withMessage != withoutMessage)
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
