import Foundation

@testable import CatLaserAuth

/// Scripted `AppleIDTokenProviding` that returns a preset list of
/// outcomes in order. One outcome is consumed per call.
actor MockAppleProvider: AppleIDTokenProviding {
    enum Outcome: Sendable {
        case token(ProviderIDToken)
        case failure(AuthError)
    }

    private var outcomes: [Outcome]
    private(set) var receivedHashes: [String] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    nonisolated func requestIDToken(
        nonceHash: String,
        context _: ProviderPresentationContext,
    ) async throws -> ProviderIDToken {
        try await consume(nonceHash: nonceHash)
    }

    private func consume(nonceHash: String) throws -> ProviderIDToken {
        receivedHashes.append(nonceHash)
        guard !outcomes.isEmpty else {
            throw AuthError.providerInternal("MockAppleProvider: no outcomes")
        }
        switch outcomes.removeFirst() {
        case let .token(t): return t
        case let .failure(e): throw e
        }
    }
}

/// Scripted `GoogleIDTokenProviding` that returns a preset list of
/// outcomes in order. One outcome is consumed per call.
actor MockGoogleProvider: GoogleIDTokenProviding {
    enum Outcome: Sendable {
        case token(ProviderIDToken)
        case failure(AuthError)
    }

    private var outcomes: [Outcome]
    private(set) var receivedNonces: [String] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    nonisolated func requestIDToken(
        rawNonce: String,
        context _: ProviderPresentationContext,
    ) async throws -> ProviderIDToken {
        try await consume(rawNonce: rawNonce)
    }

    private func consume(rawNonce: String) throws -> ProviderIDToken {
        receivedNonces.append(rawNonce)
        guard !outcomes.isEmpty else {
            throw AuthError.providerInternal("MockGoogleProvider: no outcomes")
        }
        switch outcomes.removeFirst() {
        case let .token(t): return t
        case let .failure(e): throw e
        }
    }
}

/// `GoogleIDTokenProviding` that blocks inside its `requestIDToken`
/// call until the test releases it. Used to reproduce the "Apple
/// already in flight; user mashes Google" race and observe the VM's
/// reentrancy lock without any real concurrency in the provider
/// itself.
actor PausingGoogleProvider: GoogleIDTokenProviding {
    private var continuation: CheckedContinuation<ProviderIDToken, any Error>?
    private var pendingResolutions: [Result<ProviderIDToken, any Error>] = []
    private(set) var started = false

    nonisolated func requestIDToken(
        rawNonce: String,
        context _: ProviderPresentationContext,
    ) async throws -> ProviderIDToken {
        try await withCheckedThrowingContinuation { cont in
            Task { await self.attach(cont, rawNonce: rawNonce) }
        }
    }

    private func attach(
        _ cont: CheckedContinuation<ProviderIDToken, any Error>,
        rawNonce _: String,
    ) {
        started = true
        if let queued = pendingResolutions.first {
            pendingResolutions.removeFirst()
            cont.resume(with: queued)
            return
        }
        continuation = cont
    }

    func resume(with token: ProviderIDToken) {
        if let c = continuation {
            continuation = nil
            c.resume(returning: token)
        } else {
            pendingResolutions.append(.success(token))
        }
    }

    func fail(with error: any Error) {
        if let c = continuation {
            continuation = nil
            c.resume(throwing: error)
        } else {
            pendingResolutions.append(.failure(error))
        }
    }

    func hasStarted() -> Bool { started }
}
