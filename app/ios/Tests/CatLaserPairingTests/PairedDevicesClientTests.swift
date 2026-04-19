import CatLaserAuth
import CatLaserDevice
import CatLaserPairing
import Foundation
import Testing

@Suite("PairedDevicesClient")
struct PairedDevicesClientTests {
    private let baseURL = URL(string: "https://api.example.com")!

    private static let samplePublicKey = Data(repeating: 0x42, count: 32)
    private static let samplePublicKeyB64URL = samplePublicKey
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")

    // MARK: - Happy paths

    @Test
    func parsesEmptyListOnSuccess() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse.json(["ok": true, "data": ["devices": []]])),
        ])
        let client = PairedDevicesClient(baseURL: baseURL, http: signedTestClient(wrapping: http))
        let devices = try await client.list()
        #expect(devices.isEmpty)

        let recorded = await http.requests()
        #expect(recorded.count == 1)
        #expect(recorded.first?.method == "GET")
        // End-to-end: the test wraps the mock in a real `SignedHTTPClient`
        // via `signedTestClient(wrapping:)`, so the mock observes the
        // same wire the coordination server would see. `Authorization`
        // and `x-device-attestation` MUST be present (attached by the
        // signer); `Idempotency-Key` MUST be absent on a read.
        #expect(recorded.first?.header("Authorization") == "Bearer pairing-test-bearer")
        #expect(recorded.first?.header("x-device-attestation") != nil)
        #expect(recorded.first?.header("Idempotency-Key") == nil)
        let expectedURL = baseURL.appendingPathComponent(PairedDevicesClient.pairedPath)
        #expect(recorded.first?.url == expectedURL)
    }

    @Test
    func parsesSingleDeviceResponse() async throws {
        let body: [String: Any] = [
            "ok": true,
            "data": [
                "devices": [
                    [
                        "device_id": "cat-alpha",
                        "device_name": "Kitchen",
                        "host": "100.64.0.42",
                        "port": 9820,
                        "paired_at": "2026-03-05T12:34:56Z",
                        "device_public_key": Self.samplePublicKeyB64URL,
                    ],
                ],
            ],
        ]
        let http = MockHTTPClient(outcomes: [.response(HTTPResponse.json(body))])
        let client = PairedDevicesClient(baseURL: baseURL, http: signedTestClient(wrapping: http))
        let devices = try await client.list()
        #expect(devices.count == 1)
        let device = try #require(devices.first)
        #expect(device.id == "cat-alpha")
        #expect(device.name == "Kitchen")
        #expect(device.endpoint.host == "100.64.0.42")
        #expect(device.endpoint.port == 9820)
        #expect(device.devicePublicKey == Self.samplePublicKey)
    }

    @Test
    func emptyDeviceNameSurvivesAsEmptyString() async throws {
        // Server returns null — the iOS `PairedDevice` coalesces to
        // empty string so the UI can fall back to `id` without a
        // Optional<String> juggle.
        let body: [String: Any] = [
            "ok": true,
            "data": [
                "devices": [
                    [
                        "device_id": "cat-alpha",
                        "device_name": NSNull(),
                        "host": "100.64.0.42",
                        "port": 9820,
                        "paired_at": "2026-03-05T12:34:56Z",
                        "device_public_key": Self.samplePublicKeyB64URL,
                    ],
                ],
            ],
        ]
        let http = MockHTTPClient(outcomes: [.response(HTTPResponse.json(body))])
        let client = PairedDevicesClient(baseURL: baseURL, http: signedTestClient(wrapping: http))
        let devices = try await client.list()
        #expect(devices.first?.name == "")
    }

    @Test
    func rejectsEntryWithoutDevicePublicKey() async throws {
        // A list entry whose device_public_key field is absent
        // cannot be verified, so the app treats the whole response
        // as invalid (the alternative — dropping just the offending
        // entry — risks silently downgrading an otherwise-hardened
        // pairing).
        let body: [String: Any] = [
            "ok": true,
            "data": [
                "devices": [
                    [
                        "device_id": "cat-alpha",
                        "device_name": "Kitchen",
                        "host": "100.64.0.42",
                        "port": 9820,
                        "paired_at": "2026-03-05T12:34:56Z",
                    ],
                ],
            ],
        ]
        let http = MockHTTPClient(outcomes: [.response(HTTPResponse.json(body))])
        let client = PairedDevicesClient(baseURL: baseURL, http: signedTestClient(wrapping: http))
        do {
            _ = try await client.list()
            Issue.record("expected throw — missing device_public_key")
        } catch let error as PairingError {
            if case .invalidServerResponse = error {
                // good
            } else {
                Issue.record("expected .invalidServerResponse, got \(error)")
            }
        }
    }

    // MARK: - Error mapping

    @Test
    func sessionExpiredOn401() async throws {
        // The server rejected the bearer. The client surfaces this as
        // `.sessionExpired`, distinct from `.missingSession` (local
        // bearer store empty). The distinction is load-bearing:
        // `PairingViewModel.reverifyOwnership` treats `.sessionExpired`
        // as indeterminate (keep the cached pairing), whereas the
        // original coalesced `.missingSession` used to wipe the
        // pairing on every bearer expiry. See `PairingError` for the
        // full rationale.
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse.json(
                ["ok": false, "error": ["code": "SESSION_REQUIRED", "message": "no session"]],
                status: 401,
            )),
        ])
        let client = PairedDevicesClient(baseURL: baseURL, http: signedTestClient(wrapping: http))
        do {
            _ = try await client.list()
            Issue.record("expected throw")
        } catch {
            if case let .sessionExpired(message) = error {
                #expect(message == "no session")
            } else {
                Issue.record("expected .sessionExpired, got \(error)")
            }
        }
    }

    @Test
    func rateLimitedOn429() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse.json(
                ["ok": false, "error": ["code": "RATE_LIMITED", "message": "slow down"]],
                status: 429,
            )),
        ])
        let client = PairedDevicesClient(baseURL: baseURL, http: signedTestClient(wrapping: http))
        do {
            _ = try await client.list()
            Issue.record("expected throw")
        } catch {
            if case let .rateLimited(message) = error {
                #expect(message == "slow down")
            } else {
                Issue.record("expected rateLimited, got \(error)")
            }
        }
    }

    @Test
    func serverErrorOn5xx() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse.json(
                ["ok": false, "error": ["code": "INTERNAL", "message": "boom"]],
                status: 503,
            )),
        ])
        let client = PairedDevicesClient(baseURL: baseURL, http: signedTestClient(wrapping: http))
        do {
            _ = try await client.list()
            Issue.record("expected throw")
        } catch {
            if case let .serverError(status, message) = error {
                #expect(status == 503)
                #expect(message == "boom")
            } else {
                Issue.record("expected serverError, got \(error)")
            }
        }
    }

    @Test
    func invalidServerResponseOnUnexpectedStatus() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse.empty(status: 418)),
        ])
        let client = PairedDevicesClient(baseURL: baseURL, http: signedTestClient(wrapping: http))
        do {
            _ = try await client.list()
            Issue.record("expected throw")
        } catch {
            if case .invalidServerResponse = error {
                // good
            } else {
                Issue.record("expected invalidServerResponse, got \(error)")
            }
        }
    }

    @Test
    func rejectsServerPortOutOfRange() async throws {
        let body: [String: Any] = [
            "ok": true,
            "data": [
                "devices": [
                    [
                        "device_id": "cat-alpha",
                        "device_name": NSNull(),
                        "host": "100.64.0.42",
                        "port": 0,
                        "paired_at": "2026-03-05T12:34:56Z",
                    ],
                ],
            ],
        ]
        let http = MockHTTPClient(outcomes: [.response(HTTPResponse.json(body))])
        let client = PairedDevicesClient(baseURL: baseURL, http: signedTestClient(wrapping: http))
        do {
            _ = try await client.list()
            Issue.record("expected throw")
        } catch {
            if case .invalidServerResponse = error {
                // good
            } else {
                Issue.record("expected invalidServerResponse, got \(error)")
            }
        }
    }

    @Test
    func rejectsNonTailnetHost() async throws {
        // If the server regresses and starts returning a non-Tailscale
        // host on this endpoint, the client must refuse to construct a
        // `DeviceEndpoint` for it rather than silently accepting a
        // public address. This pairs with fix #3 — the allowlist has
        // to be enforced on every ingress path that yields a
        // `DeviceEndpoint`, not just the one-shot pair claim.
        let body: [String: Any] = [
            "ok": true,
            "data": [
                "devices": [
                    [
                        "device_id": "cat-alpha",
                        "device_name": NSNull(),
                        "host": "8.8.8.8",
                        "port": 9820,
                        "paired_at": "2026-03-05T12:34:56Z",
                    ],
                ],
            ],
        ]
        let http = MockHTTPClient(outcomes: [.response(HTTPResponse.json(body))])
        let client = PairedDevicesClient(baseURL: baseURL, http: signedTestClient(wrapping: http))
        do {
            _ = try await client.list()
            Issue.record("expected throw")
        } catch {
            if case .invalidServerResponse = error {
                // good
            } else {
                Issue.record("expected invalidServerResponse, got \(error)")
            }
        }
    }

    @Test
    func rejectsMalformedEnvelope() async throws {
        // Missing `data` entirely — not even `ok: true`. Must not
        // silently return an empty array; must surface as decode
        // failure so ownership-recheck callers don't mistake a
        // server-side regression for "user owns nothing."
        let http = MockHTTPClient(outcomes: [.response(HTTPResponse.json(["unexpected": 1]))])
        let client = PairedDevicesClient(baseURL: baseURL, http: signedTestClient(wrapping: http))
        do {
            _ = try await client.list()
            Issue.record("expected throw")
        } catch {
            if case .invalidServerResponse = error {
                // good
            } else {
                Issue.record("expected invalidServerResponse, got \(error)")
            }
        }
    }

    @Test
    func bubblesNetworkFailure() async throws {
        struct ContrivedError: LocalizedError {
            var errorDescription: String? { "hung up" }
        }
        let http = MockHTTPClient(outcomes: [.failure(ContrivedError())])
        let client = PairedDevicesClient(baseURL: baseURL, http: signedTestClient(wrapping: http))
        do {
            _ = try await client.list()
            Issue.record("expected throw")
        } catch {
            if case let .network(message) = error {
                #expect(message.contains("hung up"))
            } else {
                Issue.record("expected network, got \(error)")
            }
        }
    }
}
