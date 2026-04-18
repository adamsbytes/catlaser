import CatLaserDevice
import CatLaserProto
import Foundation
import SwiftProtobuf

/// Deterministic synthetic device for integration-style `DeviceClient`
/// tests. Binds to one `InMemoryDeviceTransport`; reacts to outbound
/// `AppRequest` messages according to a caller-supplied closure.
///
/// Usage:
///
/// ```swift
/// let transport = InMemoryDeviceTransport()
/// let client = DeviceClient(transport: transport)
/// let server = ScriptedDeviceServer(transport: transport) { request in
///     switch request.request {
///     case .startStream:
///         var offer = Catlaser_App_V1_StreamOffer()
///         offer.livekitURL = "wss://livekit.test"
///         offer.subscriberToken = "abc"
///         return .reply(.init(streamOffer: offer))
///     default:
///         return .error(code: 2, message: "unknown")
///     }
/// }
/// await server.run()
/// ```
///
/// The handler returns a `Response` that maps cleanly onto the server
/// contract: one reply, one remote error, or silence (for tests that
/// want to check timeout / no-response behaviour).
public actor ScriptedDeviceServer {
    public enum Response: Sendable {
        case reply(Catlaser_App_V1_DeviceEvent)
        case error(code: UInt32, message: String)
        case silent
    }

    public typealias Handler = @Sendable (Catlaser_App_V1_AppRequest) -> Response

    private let transport: InMemoryDeviceTransport
    private let handler: Handler
    private var running = false
    private var loopTask: Task<Void, Never>?

    public init(transport: InMemoryDeviceTransport, handler: @escaping Handler) {
        self.transport = transport
        self.handler = handler
    }

    /// Start the server loop. Each call to `transport.send(_:)` from
    /// the client flows through the handler; the returned `Response`
    /// is framed and delivered back.
    public func run() {
        guard !running else { return }
        running = true
        loopTask = Task { [transport, handler] in
            while !Task.isCancelled {
                let request: Catlaser_App_V1_AppRequest
                do {
                    request = try await transport.nextAppRequest(timeout: 30)
                } catch {
                    return
                }
                switch handler(request) {
                case var .reply(event):
                    event.requestID = request.requestID
                    try? transport.deliver(event: event)
                case let .error(code, message):
                    var event = Catlaser_App_V1_DeviceEvent()
                    event.requestID = request.requestID
                    var error = Catlaser_App_V1_DeviceError()
                    error.code = code
                    error.message = message
                    event.error = error
                    try? transport.deliver(event: event)
                case .silent:
                    continue
                }
            }
        }
    }

    public func stop() {
        running = false
        loopTask?.cancel()
        loopTask = nil
    }

    /// Send an unsolicited event (e.g. `status_update`, `hopper_empty`)
    /// from the test harness side.
    public nonisolated func push(_ event: Catlaser_App_V1_DeviceEvent) throws {
        try transport.deliver(event: event)
    }
}
