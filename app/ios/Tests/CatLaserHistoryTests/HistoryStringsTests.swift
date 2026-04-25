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

    /// The queue-aware naming-sheet title surfaces both numbers so a
    /// user who was away while multiple new cats were detected
    /// understands the sheet is going to re-present N-1 more times —
    /// not looping or stuck.
    @Test
    func namingSheetTitleWithQueueContainsBothPositionals() {
        let title = HistoryStrings.namingSheetTitleWithQueue(index: 2, total: 5)
        #expect(title.contains("2"),
                "the title must contain the 1-based queue index")
        #expect(title.contains("5"),
                "the title must contain the queue total")
        #expect(!title.isEmpty)
    }

    /// Positional argument order in ``String(format:)`` is fragile —
    /// a future localisation that drops the ``%1$d`` / ``%2$d`` index
    /// markers and instead uses bare ``%d`` will silently swap the
    /// index and total at runtime (C-style positional fallback reads
    /// the varargs in call order, which Swift already satisfies, but
    /// it only takes one localisation merge that reorders the numbers
    /// in-copy to break the expansion). This test assertion protects
    /// the expansion at refactor time.
    @Test
    func namingSheetTitleWithQueueRendersIndexBeforeTotal() {
        let title = HistoryStrings.namingSheetTitleWithQueue(index: 1, total: 3)
        let indexPosition = title.range(of: "1")?.lowerBound
        let totalPosition = title.range(of: "3")?.lowerBound
        guard let indexPosition, let totalPosition else {
            Issue.record("expected both 1 and 3 to appear in \(title)")
            return
        }
        #expect(indexPosition < totalPosition,
                "queue index must render before queue total")
    }

    // MARK: - Session celebration

    /// Single-cat body must interpolate the cat's name at the
    /// position the user reads it. A localisation that drops the
    /// ``%@`` placeholder would silently render "just played." with
    /// no subject; pin the contract here.
    @Test
    func celebrationBodySingleCatInterpolatesName() {
        let body = HistoryStrings.celebrationBodySingleCat(name: "Pancake")
        #expect(body.contains("Pancake"))
        #expect(body.contains("just played"))
    }

    /// Multi-cat body interpolates the joined-name list verbatim;
    /// the join itself is owned by ``CatProfileFormatter`` so the
    /// localisation surface here is just the surrounding sentence.
    @Test
    func celebrationBodyMultipleCatsInterpolatesJoinedNames() {
        let body = HistoryStrings.celebrationBodyMultipleCats(joinedNames: "Pancake and Waffle")
        #expect(body.contains("Pancake and Waffle"))
        #expect(body.contains("just played"))
    }

    /// Unknown-cat fallback is the only branch that should never
    /// surface a name. The body must read as a complete sentence on
    /// its own — no orphaned ``%@`` placeholder, no leading article
    /// missing.
    @Test
    func celebrationBodyUnknownCatStandsAlone() {
        let body = HistoryStrings.celebrationBodyUnknownCat
        #expect(!body.isEmpty)
        #expect(!body.contains("%@"))
        #expect(body.contains("just played"))
    }

    /// All four stat-row labels must resolve to non-empty user-facing
    /// copy. A refactor that dropped a ``NSLocalizedString`` key
    /// would otherwise ship an unlabelled stat tile.
    @Test
    func celebrationStatLabelsAllNonEmpty() {
        #expect(!HistoryStrings.celebrationEngagementLabel.isEmpty)
        #expect(!HistoryStrings.celebrationDurationLabel.isEmpty)
        #expect(!HistoryStrings.celebrationPouncesLabel.isEmpty)
        #expect(!HistoryStrings.celebrationTreatsLabel.isEmpty)
        #expect(!HistoryStrings.celebrationDismissButton.isEmpty)
        #expect(!HistoryStrings.celebrationTitle.isEmpty)
    }
}
