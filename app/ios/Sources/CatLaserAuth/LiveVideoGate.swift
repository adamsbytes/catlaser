import Foundation

/// Narrow protocol for the pre-stream user-presence gate.
///
/// The ``LiveViewModel``'s `AuthGate` closure in production is bound
/// to ``GatedBearerTokenStore/requireLiveVideo()`` via
/// ``AppComposition``. That method is Darwin-only because it depends
/// on ``LocalAuthentication``; the ``AppComposition`` itself builds
/// on every platform so the composition-invariants test suite can
/// run on Linux CI as well as Darwin. Extracting the narrow
/// "require live video" surface into a protocol lets the
/// cross-platform composition call it without depending on
/// ``GatedBearerTokenStore`` directly.
///
/// Conformance:
/// * ``GatedBearerTokenStore`` (Darwin) — always prompts biometric /
///   passcode, regardless of the in-memory bearer cache's freshness.
/// * Test doubles on any platform — a stub that records invocations
///   or injects a specific failure mode so the composition's
///   mapping from ``requireLiveVideo`` throws to
///   ``LiveAuthGateOutcome`` can be exercised deterministically.
public protocol LiveVideoGate: Sendable {
    /// Prompt the user for the strict re-auth required before a live
    /// stream begins. Throws on cancellation, unavailability, or any
    /// other non-success outcome; returns on an explicit approval.
    ///
    /// The composition maps ``AuthError/cancelled`` to
    /// ``LiveAuthGateOutcome/cancelled`` and every other thrown error
    /// to ``LiveAuthGateOutcome/denied(_:)`` so a failure to obtain
    /// user presence never default-allows the stream.
    func requireLiveVideo() async throws
}

#if canImport(LocalAuthentication) && canImport(Security) && canImport(Darwin)
extension GatedBearerTokenStore: LiveVideoGate {}
#endif
