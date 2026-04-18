import CatLaserAuth
import Foundation
import Testing

@testable import CatLaserPairing

@Suite("PairingError.from(AuthError)")
struct PairingErrorTests {
    @Test
    func mapsMissingBearerToMissingSession() {
        let mapped = PairingError.from(.missingBearerToken)
        #expect(mapped == .missingSession)
    }

    @Test
    func mapsNetworkToNetwork() {
        let mapped = PairingError.from(.network(NetworkFailure("no route")))
        #expect(mapped == .network("no route"))
    }

    @Test
    func mapsMalformedResponseToInvalidServerResponse() {
        let mapped = PairingError.from(.malformedResponse("bad json"))
        #expect(mapped == .invalidServerResponse("bad json"))
    }

    @Test
    func mapsServerErrorToServerError() {
        let mapped = PairingError.from(.serverError(status: 503, message: "down"))
        #expect(mapped == .serverError(status: 503, message: "down"))
    }

    @Test
    func mapsAttestationFailedToAttestation() {
        let mapped = PairingError.from(.attestationFailed("se busy"))
        #expect(mapped == .attestation("se busy"))
    }

    @Test
    func mapsSecureEnclaveUnavailableToAttestation() {
        let mapped = PairingError.from(.secureEnclaveUnavailable("no SE"))
        #expect(mapped == .attestation("no SE"))
    }

    @Test
    func mapsKeychainToStorage() {
        let mapped = PairingError.from(.keychain(OSStatusCode(-25300)))
        // Any `.storage(_)` is acceptable; match on case.
        if case .storage = mapped {
            // good
        } else {
            Issue.record("expected .storage, got \(mapped)")
        }
    }

    @Test
    func mapsCancelledToInvalidServerResponse() {
        // Cancelled inside the pairing exchange is a protocol bug —
        // pairing never presents a sign-in sheet, so `cancelled`
        // arriving here means something in the signed HTTP pipeline
        // interpreted a flow-control exception as cancel. Surface as
        // invalidServerResponse so it is noisy rather than silent.
        let mapped = PairingError.from(.cancelled)
        if case .invalidServerResponse = mapped {
            // good
        } else {
            Issue.record("expected .invalidServerResponse, got \(mapped)")
        }
    }
}
