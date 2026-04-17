import Foundation

/// Persistent, device-bound installation identifier. Generated lazily on first
/// use and kept stable for the lifetime of the app install. Implementations
/// must be thread-safe: fingerprint capture can race with the coordinator
/// during sign-in and verify flows.
public protocol InstallIDStoring: Sendable {
    func currentID() async throws -> String
    func reset() async throws
}

public actor InMemoryInstallIDStore: InstallIDStoring {
    private var identifier: String?
    private let generator: @Sendable () -> String

    public init(initial: String? = nil) {
        self.identifier = initial
        self.generator = { UUID().uuidString }
    }

    init(initial: String? = nil, generator: @escaping @Sendable () -> String) {
        self.identifier = initial
        self.generator = generator
    }

    public func currentID() async throws -> String {
        if let existing = identifier {
            return existing
        }
        let generated = generator()
        identifier = generated
        return generated
    }

    public func reset() async throws {
        identifier = nil
    }
}
