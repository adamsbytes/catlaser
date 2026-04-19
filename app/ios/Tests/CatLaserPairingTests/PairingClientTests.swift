import CatLaserAuth
import Foundation
import Testing

@testable import CatLaserPairing

@Suite("PairingClient")
struct PairingClientTests {
    private let baseURL = URL(string: "https://api.example.com")!
    private let clock = Date(timeIntervalSince1970: 1_712_345_678)

    /// Raw 32-byte Ed25519 public key used as a test fixture. The
    /// base64url-no-pad encoding is what the coordination server
    /// returns in `device_public_key`.
    private static let samplePublicKey = Data(repeating: 0x42, count: 32)
    private static let samplePublicKeyB64URL = samplePublicKey
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")

    private func makeCode() throws -> PairingCode {
        try PairingCode(code: "ABCDEFGHIJKLMNOP", deviceID: "cat-001")
    }

    private func makeClient(http: MockHTTPClient) -> PairingClient {
        PairingClient(baseURL: baseURL, http: signedTestClient(wrapping: http))
    }

    // MARK: - Happy path

    @Test
    func exchangeReturnsPairedDeviceOn200() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.json([
            "device_id": "cat-001",
            "device_name": "Kitchen",
            "host": "100.64.1.7",
            "port": 9820,
            "device_public_key": Self.samplePublicKeyB64URL,
        ])))
        let client = makeClient(http: http)
        let paired = try await client.exchange(code: try makeCode(), now: clock)

        #expect(paired.id == "cat-001")
        #expect(paired.name == "Kitchen")
        #expect(paired.endpoint.host == "100.64.1.7")
        #expect(paired.endpoint.port == 9820)
        #expect(paired.pairedAt == clock)
        #expect(paired.devicePublicKey == Self.samplePublicKey)
    }

    @Test
    func exchangePostsCanonicalBody() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.json([
            "device_id": "cat-001",
            "host": "100.64.1.7",
            "port": 9820,
            "device_public_key": Self.samplePublicKeyB64URL,
        ])))
        let client = makeClient(http: http)
        _ = try await client.exchange(code: try makeCode(), now: clock)

        let requests = await http.requests()
        #expect(requests.count == 1)
        let r = requests[0]
        #expect(r.method == "POST")
        #expect(r.url?.absoluteString == "https://api.example.com/api/v1/devices/pair")
        #expect(r.header("Content-Type") == "application/json")
        #expect(r.header("Accept") == "application/json")
        let bodyObject = try JSONSerialization.jsonObject(with: r.body ?? Data()) as? [String: Any]
        #expect(bodyObject?["code"] as? String == "ABCDEFGHIJKLMNOP")
        #expect(bodyObject?["device_id"] as? String == "cat-001")
    }

    @Test
    func exchangeAcceptsMissingDeviceName() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.json([
            "device_id": "cat-001",
            "host": "100.64.1.7",
            "port": 9820,
            "device_public_key": Self.samplePublicKeyB64URL,
        ])))
        let client = makeClient(http: http)
        let paired = try await client.exchange(code: try makeCode(), now: clock)
        #expect(paired.name == "")
    }

    @Test
    func exchangeRejectsResponseWithMissingPublicKey() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.json([
            "device_id": "cat-001",
            "host": "100.64.1.7",
            "port": 9820,
        ])))
        let client = makeClient(http: http)
        do {
            _ = try await client.exchange(code: try makeCode())
            Issue.record("expected throw — missing device_public_key must fail pairing")
        } catch let error as PairingError {
            if case .invalidServerResponse = error {
                // good — decode failure path
            } else {
                Issue.record("expected .invalidServerResponse, got \(error)")
            }
        }
    }

    @Test
    func exchangeRejectsResponseWithWrongLengthPublicKey() async throws {
        // A 31-byte key decodes cleanly as base64url but fails the
        // length gate — Curve25519.Signing.PublicKey would reject
        // downstream, but the pairing boundary catches it first so
        // the app never persists an unverifiable row.
        let shortKey = Data(repeating: 0x42, count: 31)
        let shortKeyB64URL = shortKey
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let http = MockHTTPClient()
        await http.enqueue(.response(.json([
            "device_id": "cat-001",
            "host": "100.64.1.7",
            "port": 9820,
            "device_public_key": shortKeyB64URL,
        ])))
        let client = makeClient(http: http)
        do {
            _ = try await client.exchange(code: try makeCode())
            Issue.record("expected throw — short pubkey must fail pairing")
        } catch let error as PairingError {
            if case let .invalidServerResponse(msg) = error {
                #expect(msg.contains("device_public_key"))
            } else {
                Issue.record("expected .invalidServerResponse, got \(error)")
            }
        }
    }

    // MARK: - Status-code mapping

    @Test
    func maps400ToInvalidServerResponse() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.json(["message": "bad payload"], status: 400)))
        let client = makeClient(http: http)
        do {
            _ = try await client.exchange(code: try makeCode())
            Issue.record("expected throw")
        } catch let error as PairingError {
            if case .invalidServerResponse = error {
                // good
            } else {
                Issue.record("expected .invalidServerResponse, got \(error)")
            }
        }
    }

    @Test
    func maps401ToSessionExpired() async throws {
        // A 401 from the server indicates the bearer was rejected, not
        // that the local bearer store was empty. The distinction
        // matters: `.sessionExpired` routes to "sign in again" without
        // disturbing any paired-device state, whereas `.missingSession`
        // (local empty-store) routes to the full sign-in/pair flow.
        let http = MockHTTPClient()
        await http.enqueue(.response(.json(["message": "expired"], status: 401)))
        let client = makeClient(http: http)
        do {
            _ = try await client.exchange(code: try makeCode())
            Issue.record("expected throw")
        } catch let error as PairingError {
            if case let .sessionExpired(message) = error {
                #expect(message == "expired")
            } else {
                Issue.record("expected .sessionExpired, got \(error)")
            }
        }
    }

    @Test
    func maps404ToCodeNotFound() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.json(["message": "unknown code"], status: 404)))
        let client = makeClient(http: http)
        do {
            _ = try await client.exchange(code: try makeCode())
            Issue.record("expected throw")
        } catch let error as PairingError {
            if case let .codeNotFound(message) = error {
                #expect(message == "unknown code")
            } else {
                Issue.record("expected .codeNotFound, got \(error)")
            }
        }
    }

    @Test
    func maps409ToCodeAlreadyUsed() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.json(["message": "already claimed"], status: 409)))
        let client = makeClient(http: http)
        do {
            _ = try await client.exchange(code: try makeCode())
            Issue.record("expected throw")
        } catch let error as PairingError {
            if case let .codeAlreadyUsed(message) = error {
                #expect(message == "already claimed")
            } else {
                Issue.record("expected .codeAlreadyUsed, got \(error)")
            }
        }
    }

    @Test
    func maps410ToCodeExpired() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.empty(status: 410)))
        let client = makeClient(http: http)
        do {
            _ = try await client.exchange(code: try makeCode())
            Issue.record("expected throw")
        } catch let error as PairingError {
            if case .codeExpired = error {
                // good
            } else {
                Issue.record("expected .codeExpired, got \(error)")
            }
        }
    }

    @Test
    func maps429ToRateLimited() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.json(["message": "too many"], status: 429)))
        let client = makeClient(http: http)
        do {
            _ = try await client.exchange(code: try makeCode())
            Issue.record("expected throw")
        } catch let error as PairingError {
            if case let .rateLimited(message) = error {
                #expect(message == "too many")
            } else {
                Issue.record("expected .rateLimited, got \(error)")
            }
        }
    }

    @Test
    func maps5xxToServerError() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.empty(status: 503)))
        let client = makeClient(http: http)
        do {
            _ = try await client.exchange(code: try makeCode())
            Issue.record("expected throw")
        } catch let error as PairingError {
            if case let .serverError(status, _) = error {
                #expect(status == 503)
            } else {
                Issue.record("expected .serverError, got \(error)")
            }
        }
    }

    @Test
    func mapsUnknownStatusToServerError() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.empty(status: 418)))
        let client = makeClient(http: http)
        do {
            _ = try await client.exchange(code: try makeCode())
            Issue.record("expected throw")
        } catch let error as PairingError {
            if case let .serverError(status, _) = error {
                #expect(status == 418)
            } else {
                Issue.record("expected .serverError, got \(error)")
            }
        }
    }

    @Test
    func mapsAuthErrorNetworkToNetwork() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.failure(AuthError.network(NetworkFailure("offline"))))
        let client = makeClient(http: http)
        do {
            _ = try await client.exchange(code: try makeCode())
            Issue.record("expected throw")
        } catch let error as PairingError {
            #expect(error == .network("offline"))
        }
    }

    @Test
    func mapsAuthErrorAttestationFailedToAttestation() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.failure(AuthError.attestationFailed("SE busy")))
        let client = makeClient(http: http)
        do {
            _ = try await client.exchange(code: try makeCode())
            Issue.record("expected throw")
        } catch let error as PairingError {
            #expect(error == .attestation("SE busy"))
        }
    }

    // MARK: - Response validation

    @Test
    func rejectsResponseWithBadHost() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.json([
            "device_id": "cat-001",
            "host": "https://notahost.example",
            "port": 9820,
        ])))
        let client = makeClient(http: http)
        do {
            _ = try await client.exchange(code: try makeCode())
            Issue.record("expected throw")
        } catch let error as PairingError {
            if case .invalidServerResponse = error {
                // good
            } else {
                Issue.record("expected .invalidServerResponse, got \(error)")
            }
        }
    }

    @Test
    func rejectsResponseWithZeroPort() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.json([
            "device_id": "cat-001",
            "host": "100.64.1.7",
            "port": 0,
        ])))
        let client = makeClient(http: http)
        do {
            _ = try await client.exchange(code: try makeCode())
            Issue.record("expected throw")
        } catch let error as PairingError {
            if case .invalidServerResponse = error {
                // good
            } else {
                Issue.record("expected .invalidServerResponse, got \(error)")
            }
        }
    }

    @Test
    func rejectsResponseWithEmptyDeviceID() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.json([
            "device_id": "  ",
            "host": "100.64.1.7",
            "port": 9820,
        ])))
        let client = makeClient(http: http)
        do {
            _ = try await client.exchange(code: try makeCode())
            Issue.record("expected throw")
        } catch let error as PairingError {
            if case .invalidServerResponse = error {
                // good
            } else {
                Issue.record("expected .invalidServerResponse, got \(error)")
            }
        }
    }

    @Test
    func rejectsResponseWithMissingHost() async throws {
        let http = MockHTTPClient()
        await http.enqueue(.response(.json([
            "device_id": "cat-001",
            "port": 9820,
        ])))
        let client = makeClient(http: http)
        do {
            _ = try await client.exchange(code: try makeCode())
            Issue.record("expected throw")
        } catch let error as PairingError {
            if case .invalidServerResponse = error {
                // good
            } else {
                Issue.record("expected .invalidServerResponse, got \(error)")
            }
        }
    }
}
