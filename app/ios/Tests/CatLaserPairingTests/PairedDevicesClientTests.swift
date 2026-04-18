import CatLaserAuth
import CatLaserDevice
import CatLaserPairing
import Foundation
import Testing

@Suite("PairedDevicesClient")
struct PairedDevicesClientTests {
    private let baseURL = URL(string: "https://api.example.com")!

    // MARK: - Happy paths

    @Test
    func parsesEmptyListOnSuccess() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse.json(["ok": true, "data": ["devices": []]])),
        ])
        let client = PairedDevicesClient(baseURL: baseURL, http: http)
        let devices = try await client.list()
        #expect(devices.isEmpty)

        let recorded = await http.requests()
        #expect(recorded.count == 1)
        #expect(recorded.first?.method == "GET")
        // The client MUST NOT invent `Authorization`, `x-device-
        // attestation`, or `Idempotency-Key` — those are
        // `SignedHTTPClient`'s job and tests pin that header is absent
        // here so a future refactor cannot duplicate them on the wire.
        #expect(recorded.first?.header("Authorization") == nil)
        #expect(recorded.first?.header("x-device-attestation") == nil)
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
                    ],
                ],
            ],
        ]
        let http = MockHTTPClient(outcomes: [.response(HTTPResponse.json(body))])
        let client = PairedDevicesClient(baseURL: baseURL, http: http)
        let devices = try await client.list()
        #expect(devices.count == 1)
        let device = try #require(devices.first)
        #expect(device.id == "cat-alpha")
        #expect(device.name == "Kitchen")
        #expect(device.endpoint.host == "100.64.0.42")
        #expect(device.endpoint.port == 9820)
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
                    ],
                ],
            ],
        ]
        let http = MockHTTPClient(outcomes: [.response(HTTPResponse.json(body))])
        let client = PairedDevicesClient(baseURL: baseURL, http: http)
        let devices = try await client.list()
        #expect(devices.first?.name == "")
    }

    // MARK: - Error mapping

    @Test
    func missingSessionOn401() async throws {
        let http = MockHTTPClient(outcomes: [
            .response(HTTPResponse.json(
                ["ok": false, "error": ["code": "SESSION_REQUIRED", "message": "no session"]],
                status: 401,
            )),
        ])
        let client = PairedDevicesClient(baseURL: baseURL, http: http)
        do {
            _ = try await client.list()
            Issue.record("expected throw")
        } catch {
            #expect(error == .missingSession)
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
        let client = PairedDevicesClient(baseURL: baseURL, http: http)
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
        let client = PairedDevicesClient(baseURL: baseURL, http: http)
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
        let client = PairedDevicesClient(baseURL: baseURL, http: http)
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
        let client = PairedDevicesClient(baseURL: baseURL, http: http)
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
        let client = PairedDevicesClient(baseURL: baseURL, http: http)
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
        let client = PairedDevicesClient(baseURL: baseURL, http: http)
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
        let client = PairedDevicesClient(baseURL: baseURL, http: http)
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
