import Foundation

/// Minimal protocol view models import to record breadcrumbs.
///
/// Decoupling the protocol from the concrete ``Observability`` facade
/// means a view model's module (``CatLaserPairing``, ``CatLaserLive``,
/// …) can depend on ``CatLaserObservability`` without pulling in the
/// full facade — the test target can substitute a stub without
/// constructing an entire observability pipeline, and the view model's
/// public init stays typed against a protocol rather than a concrete
/// actor.
///
/// Every method is fire-and-forget: recording a breadcrumb MUST never
/// fail the caller, and MUST return synchronously from the caller's
/// perspective. Concrete implementations either hop onto a private
/// actor (the production ``Observability`` facade) or no-op.
public protocol BreadcrumbRecorder: Sendable {
    /// Record a pre-built breadcrumb. The concrete implementation
    /// captures wall + monotonic timestamps internally if the caller
    /// did not; callers that already have a trusted timestamp pass
    /// the breadcrumb through as-is.
    func record(_ breadcrumb: Breadcrumb)
}

public extension BreadcrumbRecorder {
    /// Convenience helper — build and record a breadcrumb in one
    /// call. The wall clock is the current `Date`, monotonic
    /// millis are taken from ``ProcessInfo/systemUptime``.
    func record(
        _ kind: Breadcrumb.Kind,
        _ name: String,
        attributes: [String: String] = [:],
    ) {
        let monotonic = UInt64(ProcessInfo.processInfo.systemUptime * 1000)
        let crumb = Breadcrumb(
            monotonicMillis: monotonic,
            wallTimestamp: Date(),
            kind: kind,
            name: name,
            attributes: attributes,
        )
        record(crumb)
    }
}

/// No-op recorder. Used as the default for view models that haven't
/// been wired up to a real observability pipeline, and by tests that
/// don't need to assert breadcrumb content.
public struct NoopBreadcrumbRecorder: BreadcrumbRecorder {
    public init() {}
    public func record(_: Breadcrumb) {}
}

/// Recorder backed by a ``BreadcrumbRing``. Test-friendly — a test
/// can construct the ring, hand this wrapper to a view model, and
/// then snapshot the ring afterwards.
public struct RingBreadcrumbRecorder: BreadcrumbRecorder {
    private let ring: BreadcrumbRing

    public init(ring: BreadcrumbRing) {
        self.ring = ring
    }

    public func record(_ breadcrumb: Breadcrumb) {
        Task { [ring] in
            await ring.record(breadcrumb)
        }
    }
}
