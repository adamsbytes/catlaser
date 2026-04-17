import Foundation
import Testing

@testable import CatLaserApp
@testable import CatLaserAuth

@Suite("SignInPhase")
struct SignInPhaseTests {
    @Test
    func idleIsNotBusyAndNotTerminal() {
        #expect(!SignInPhase.idle.isBusy)
        #expect(!SignInPhase.idle.isTerminal)
    }

    @Test
    func authenticatingCasesAreBusy() {
        #expect(SignInPhase.authenticating(.apple).isBusy)
        #expect(SignInPhase.authenticating(.google).isBusy)
    }

    @Test
    func requestingAndVerifyingMagicLinkAreBusy() {
        #expect(SignInPhase.requestingMagicLink.isBusy)
        #expect(SignInPhase.verifyingMagicLink.isBusy)
    }

    @Test
    func resendingMagicLinkIsBusy() {
        #expect(SignInPhase.resendingMagicLink("a@b.com").isBusy)
    }

    @Test
    func emailSentIsNotBusyAndNotTerminal() {
        #expect(!SignInPhase.emailSent("a@b.com").isBusy)
        #expect(!SignInPhase.emailSent("a@b.com").isTerminal)
    }

    @Test
    func succeededIsTerminalAndNotBusy() {
        let session = AuthSession(
            bearerToken: "t",
            user: AuthUser(id: "u", email: nil, name: nil, image: nil, emailVerified: true),
            provider: .apple,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let phase = SignInPhase.succeeded(session)
        #expect(phase.isTerminal)
        #expect(!phase.isBusy)
    }

    @Test
    func failedIsNotTerminalOrBusy() {
        let phase = SignInPhase.failed(.invalidEmail)
        #expect(!phase.isBusy)
        #expect(!phase.isTerminal)
    }

    @Test
    func equalityIsCaseAndPayloadSensitive() {
        #expect(SignInPhase.emailSent("a@b.com") == SignInPhase.emailSent("a@b.com"))
        #expect(SignInPhase.emailSent("a@b.com") != SignInPhase.emailSent("c@d.com"))
        #expect(
            SignInPhase.authenticating(.apple)
                != SignInPhase.authenticating(.google),
        )
        #expect(
            SignInPhase.failed(.invalidEmail)
                != SignInPhase.failed(.cancelled),
        )
    }
}
