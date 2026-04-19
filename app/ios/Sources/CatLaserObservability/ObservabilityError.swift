import Foundation

/// Error surface for the observability pipeline.
///
/// Every path that can fail — encoding a breadcrumb, writing the
/// persistent queue, uploading a batch — surfaces through this enum
/// so the facade actor has a single error taxonomy to reason about.
/// The pipeline never throws these errors to the caller that emitted
/// an event (recording must never fail the caller); they are logged
/// via the facade's diagnostic surface and, where relevant, persisted
/// so a later batch upload can attach the most recent failure.
public enum ObservabilityError: Error, Equatable, Sendable {
    /// Queue file IO failed (disk full, permission denied, corrupted).
    case queueIOFailed(String)
    /// JSON encoding of an event or crash payload failed. Reported so
    /// a misconfigured event schema (adding an attr that cannot round-
    /// trip through `JSONEncoder`) is surfaced rather than silently
    /// dropped.
    case encodingFailed(String)
    /// Upload transport returned an HTTP status that indicates the
    /// batch was rejected and must not be retried (4xx other than 429).
    case uploadRejected(statusCode: Int)
    /// Upload transport returned a transient failure (5xx, 429, or
    /// network error). Callers retry with backoff.
    case uploadTransient(String)
    /// The configured upload endpoint is unreachable — DNS failure,
    /// broken TLS, offline. Distinct from ``uploadTransient`` so the
    /// uploader can distinguish "retry soon" from "retry on the next
    /// network-up event".
    case uploadUnreachable(String)
    /// Consent was withdrawn while a drain was in flight. The drained
    /// batch is discarded; subsequent calls no-op.
    case consentWithdrawn
    /// Observability was not configured before a call was made — the
    /// composition root forgot to call ``Observability/install``.
    case notConfigured
}
