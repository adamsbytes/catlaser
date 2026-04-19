import CatLaserObservability
import Foundation
import Observation

/// View model for the first-launch privacy consent screen.
///
/// Holds the two toggle bindings and commits the chosen state to the
/// injected ``ConsentStore``. Separating the VM from the view means
/// the composition root can drive the same VM from a future Settings
/// screen without rebuilding the flow.
///
/// The VM ALSO records the resulting telemetry event via the injected
/// ``Observability`` facade — but only if the user opted in. A decline
/// still records a `consent_declined` event via the pre-opt-in path
/// described in ``Observability/record(event:)``: that call short-
/// circuits on `state.telemetryEnabled == false`, so the event is
/// dropped; we therefore cannot rely on it for the "user declined"
/// signal. Instead the caller (the composition root) writes a
/// breadcrumb on the outcome and that breadcrumb is attached to the
/// next crash upload if crash reporting was accepted.
@Observable
@MainActor
public final class PrivacyConsentViewModel {
    public var crashReportingEnabled: Bool
    public var telemetryEnabled: Bool
    public private(set) var isCommitting: Bool = false
    public private(set) var didCommit: Bool = false

    private let consentStore: any ConsentStore
    private let observability: Observability?
    private let onCompletion: @MainActor () -> Void

    public init(
        consentStore: any ConsentStore,
        observability: Observability?,
        initialCrashReporting: Bool = true,
        initialTelemetry: Bool = true,
        onCompletion: @escaping @MainActor () -> Void,
    ) {
        self.consentStore = consentStore
        self.observability = observability
        self.crashReportingEnabled = initialCrashReporting
        self.telemetryEnabled = initialTelemetry
        self.onCompletion = onCompletion
    }

    public func commit() async {
        guard !isCommitting else { return }
        isCommitting = true
        defer { isCommitting = false }

        let newState: ConsentState
        if !crashReportingEnabled, !telemetryEnabled {
            newState = .declined
        } else {
            newState = .granted(
                crashReporting: crashReportingEnabled,
                telemetry: telemetryEnabled,
            )
        }
        await consentStore.save(newState)

        if let observability {
            await observability.record(
                event: .consentGranted(
                    crashReporting: crashReportingEnabled,
                    telemetry: telemetryEnabled,
                ),
            )
            // Write a breadcrumb regardless of telemetry consent so a
            // subsequent crash upload (if crash reporting is on) can
            // surface the final choice.
            observability.record(
                .userAction,
                "consent.committed",
                attributes: [
                    "crash_reporting": crashReportingEnabled ? "true" : "false",
                    "telemetry": telemetryEnabled ? "true" : "false",
                ],
            )
        }

        didCommit = true
        onCompletion()
    }
}
