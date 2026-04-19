#if canImport(MetricKit)
import Foundation
import MetricKit

/// Bridge over ``MXMetricManager`` that translates Apple's
/// diagnostic payloads into ``CrashPayload`` records the
/// observability uploader can ingest.
///
/// ## Delivery model
///
/// Apple schedules diagnostic payload delivery at most once per
/// day, usually on app launch. The subscriber receives
/// ``didReceive(_ payloads: [MXDiagnosticPayload])`` with every
/// payload that has not been delivered before — Apple tracks the
/// delivery receipt inside the OS so the same payload is never
/// delivered twice to the same subscriber.
///
/// ## What we pick off
///
/// Each ``MXDiagnosticPayload`` may carry:
/// - ``MXCrashDiagnostic`` — signal / exception that terminated the
///   process, with symbolicated backtrace, register state, and
///   image load addresses. The most common case.
/// - ``MXHangDiagnostic`` — main-thread hangs. Apple defines a
///   watchdog cutoff that ships the hang as a crash if the user
///   force-kills the app. Useful signal for perf issues.
/// - ``MXCPUExceptionDiagnostic`` — CPU abuse termination.
/// - ``MXDiskWriteExceptionDiagnostic`` — disk write abuse.
///
/// Every diagnostic is serialised via its `jsonRepresentation()` API
/// — Apple's signed JSON format that our backend parses with the
/// same schema Apple publishes. We do not re-format; we pass it
/// through and let the server symbolicate with its own dSYM cache.
///
/// ## Error handling
///
/// The subscriber never throws to MetricKit — that would cause
/// Apple to stop delivering future payloads. Every failure path
/// (`onPayload` handler throws, transport fails) is swallowed and
/// the payload stays in memory only until the next launch when
/// Apple re-delivers (same payload, new subscriber identity after
/// reinstall) or is gone. A persistent on-disk buffer is not
/// warranted: MetricKit's own delivery is already per-app and
/// cached by the OS.
public final class MetricKitBridge: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    /// Handler fired for each batch of diagnostic payloads. The
    /// handler is responsible for turning the payloads into
    /// ``CrashPayload`` instances and enqueuing them onto the
    /// observability uploader.
    public typealias PayloadHandler = @Sendable ([CrashPayload]) -> Void

    private let handler: PayloadHandler

    public init(handler: @escaping PayloadHandler) {
        self.handler = handler
    }

    /// Start receiving diagnostic payloads. Idempotent — adding the
    /// same subscriber twice to ``MXMetricManager`` is a no-op.
    public func register() {
        MXMetricManager.shared.add(self)
    }

    public func deregister() {
        MXMetricManager.shared.remove(self)
    }

    // MARK: - MXMetricManagerSubscriber

    public func didReceive(_ payloads: [MXMetricPayload]) {
        // Regular performance metrics — CPU, memory, battery, disk.
        // We do not upload these today; they are useful later for
        // performance dashboards but not for release gating.
        _ = payloads
    }

    #if canImport(MetricKit)
    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var crashes: [CrashPayload] = []
        for payload in payloads {
            crashes.append(contentsOf: extract(from: payload))
        }
        if !crashes.isEmpty {
            handler(crashes)
        }
    }

    /// Translate a single ``MXDiagnosticPayload`` into zero or more
    /// ``CrashPayload`` records. A single payload can carry multiple
    /// diagnostics of different types — we emit one ``CrashPayload``
    /// per diagnostic so the server sees each one with its own
    /// delivery receipt.
    public func extract(from payload: MXDiagnosticPayload) -> [CrashPayload] {
        var crashes: [CrashPayload] = []
        if let crashDiagnostics = payload.crashDiagnostics {
            for crash in crashDiagnostics {
                let json = String(data: crash.jsonRepresentation(), encoding: .utf8) ?? ""
                crashes.append(
                    CrashPayload(
                        id: UUID().uuidString,
                        source: .metricKit,
                        payload: json,
                        breadcrumbs: [],
                    ),
                )
            }
        }
        if let hangDiagnostics = payload.hangDiagnostics {
            for hang in hangDiagnostics {
                let json = String(data: hang.jsonRepresentation(), encoding: .utf8) ?? ""
                crashes.append(
                    CrashPayload(
                        id: UUID().uuidString,
                        source: .metricKit,
                        payload: json,
                        breadcrumbs: [],
                    ),
                )
            }
        }
        if let cpuDiagnostics = payload.cpuExceptionDiagnostics {
            for cpu in cpuDiagnostics {
                let json = String(data: cpu.jsonRepresentation(), encoding: .utf8) ?? ""
                crashes.append(
                    CrashPayload(
                        id: UUID().uuidString,
                        source: .metricKit,
                        payload: json,
                        breadcrumbs: [],
                    ),
                )
            }
        }
        if let diskDiagnostics = payload.diskWriteExceptionDiagnostics {
            for disk in diskDiagnostics {
                let json = String(data: disk.jsonRepresentation(), encoding: .utf8) ?? ""
                crashes.append(
                    CrashPayload(
                        id: UUID().uuidString,
                        source: .metricKit,
                        payload: json,
                        breadcrumbs: [],
                    ),
                )
            }
        }
        return crashes
    }
    #endif
}
#endif
