import CatLaserObservability
import Foundation
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("HTTPObservabilityTransport")
struct HTTPObservabilityTransportTests {
    private func sampleBatch() -> UploadBatch {
        UploadBatch(
            context: ObservabilityContext(
                deviceIDHash: "hash",
                sessionID: "sess",
                appVersion: "1.0.0",
                buildNumber: "1",
                bundleID: "com.catlaser.app",
                platform: "iOS",
                osVersion: "17.0",
                deviceModel: "iPhone15,2",
                locale: "en_US",
            ),
            events: [
                EventEnvelope(
                    id: "id-1",
                    name: "app_launched",
                    attributes: ["cold_start": "true"],
                    monotonicNS: 0,
                    wallTimeUTC: "1970-01-01T00:00:00.000Z",
                ),
            ],
        )
    }

    @Test
    func successfulUploadAttachesHeadersAndBody() async throws {
        let client = RecordingClient(status: 204)
        let transport = HTTPObservabilityTransport(
            uploadURL: URL(string: "https://api.example.com/api/v1/observability/events")!,
            httpClient: client,
            bearerProvider: { "test-bearer" },
        )
        try await transport.upload(sampleBatch())
        let captured = await client.captured
        #expect(captured.count == 1)
        let request = captured[0]
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "x-device-id-hash") == "hash")
        #expect(request.value(forHTTPHeaderField: "x-session-id") == "sess")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-bearer")
        #expect(request.httpBody?.isEmpty == false)
    }

    @Test
    func missingBearerOmitsAuthorizationHeader() async throws {
        let client = RecordingClient(status: 204)
        let transport = HTTPObservabilityTransport(
            uploadURL: URL(string: "https://api.example.com/api/v1/observability/events")!,
            httpClient: client,
            bearerProvider: { nil },
        )
        try await transport.upload(sampleBatch())
        let captured = await client.captured
        #expect(captured[0].value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func rateLimitMapsToTransientError() async {
        let client = RecordingClient(status: 429)
        let transport = HTTPObservabilityTransport(
            uploadURL: URL(string: "https://api.example.com/events")!,
            httpClient: client,
            bearerProvider: { nil },
        )
        do {
            try await transport.upload(sampleBatch())
            Issue.record("expected throw on 429")
        } catch ObservabilityError.uploadTransient {
            // ok
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test
    func fiveHundredMapsToTransientError() async {
        let client = RecordingClient(status: 502)
        let transport = HTTPObservabilityTransport(
            uploadURL: URL(string: "https://api.example.com/events")!,
            httpClient: client,
            bearerProvider: { nil },
        )
        do {
            try await transport.upload(sampleBatch())
            Issue.record("expected throw on 502")
        } catch ObservabilityError.uploadTransient {
            // ok
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test
    func fourHundredMapsToRejectedError() async {
        let client = RecordingClient(status: 400)
        let transport = HTTPObservabilityTransport(
            uploadURL: URL(string: "https://api.example.com/events")!,
            httpClient: client,
            bearerProvider: { nil },
        )
        do {
            try await transport.upload(sampleBatch())
            Issue.record("expected throw on 400")
        } catch let ObservabilityError.uploadRejected(status) {
            #expect(status == 400)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test
    func networkErrorMapsToUnreachable() async {
        let client = FailingClient(error: URLError(.notConnectedToInternet))
        let transport = HTTPObservabilityTransport(
            uploadURL: URL(string: "https://api.example.com/events")!,
            httpClient: client,
            bearerProvider: { nil },
        )
        do {
            try await transport.upload(sampleBatch())
            Issue.record("expected throw on network error")
        } catch ObservabilityError.uploadUnreachable {
            // ok
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }
}

@Suite("InMemoryObservabilityTransport")
struct InMemoryObservabilityTransportTests {
    @Test
    func recordsEveryBatch() async throws {
        let transport = InMemoryObservabilityTransport()
        let batch = UploadBatch(
            context: ObservabilityContext(
                deviceIDHash: "", sessionID: "",
                appVersion: "", buildNumber: "", bundleID: "",
                platform: "", osVersion: "", deviceModel: "", locale: "",
            ),
            events: [],
        )
        try await transport.upload(batch)
        try await transport.upload(batch)
        let recorded = await transport.uploaded
        #expect(recorded.count == 2)
    }

    @Test
    func failingBehaviorPropagatesError() async {
        let transport = InMemoryObservabilityTransport(
            behavior: .fail(.uploadRejected(statusCode: 403)),
        )
        let batch = UploadBatch(
            context: ObservabilityContext(
                deviceIDHash: "", sessionID: "",
                appVersion: "", buildNumber: "", bundleID: "",
                platform: "", osVersion: "", deviceModel: "", locale: "",
            ),
            events: [],
        )
        do {
            try await transport.upload(batch)
            Issue.record("expected throw")
        } catch let ObservabilityError.uploadRejected(status) {
            #expect(status == 403)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }
}

// MARK: - Test doubles

private actor RecordingClient: ObservabilityHTTPClient {
    let status: Int
    private(set) var captured: [URLRequest] = []

    init(status: Int) {
        self.status = status
    }

    func send(_ request: URLRequest) async throws -> ObservabilityHTTPResponse {
        captured.append(request)
        return ObservabilityHTTPResponse(
            statusCode: status,
            headers: [:],
            body: Data(),
        )
    }
}

private actor FailingClient: ObservabilityHTTPClient {
    let error: any Error

    init(error: any Error) {
        self.error = error
    }

    func send(_: URLRequest) async throws -> ObservabilityHTTPResponse {
        throw error
    }
}
