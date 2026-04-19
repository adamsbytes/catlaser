import Foundation

/// Single audit-trail record captured by the observability pipeline.
///
/// A breadcrumb is a structured hint about what the app was doing
/// just before a crash, a session expiry, or any other diagnostic
/// event worth explaining. The ring buffer holds the last N
/// breadcrumbs in memory; the persistent mirror survives process
/// death so a crash handler can attach the trailing breadcrumbs to a
/// tombstone file even if the crash is delivered on the next launch
/// via ``MetricKit``.
///
/// Breadcrumbs are strictly typed — a ``Kind`` enum with a fixed set
/// of causes and a bounded attribute dictionary. Freeform strings
/// would invite PII leaks and schema drift; the closed enum keeps the
/// surface auditable and the backend parser simple.
public struct Breadcrumb: Sendable, Codable, Equatable {
    /// What the breadcrumb represents. Every concrete breadcrumb the
    /// app emits matches one of these cases — a new category requires
    /// a code change here, which is the point.
    public enum Kind: String, Sendable, Codable, Equatable, CaseIterable {
        /// Screen or state transition in the UI.
        case navigation
        /// Authentication state change — sign-in, sign-out, session
        /// expired, token refresh.
        case auth
        /// Device pairing lifecycle — QR scanned, exchange started,
        /// paired, unpaired.
        case pairing
        /// Connection manager state change — connecting, connected,
        /// reconnecting, disconnected.
        case connection
        /// Live-stream lifecycle — start, offer received, streaming,
        /// stop, error.
        case live
        /// Background task — APNs registration, schedule sync,
        /// history refresh.
        case background
        /// User-initiated action — tapped a button, toggled a
        /// setting.
        case userAction
        /// Non-fatal error the app handled but wanted to record.
        case error
        /// Diagnostic note — everything else.
        case note
    }

    /// Monotonic millisecond timestamp captured at record time. Used
    /// to order breadcrumbs within a single process lifetime; not an
    /// absolute wall clock (the wall time is captured separately as
    /// ``wallTimestamp`` for post-hoc correlation).
    public let monotonicMillis: UInt64
    /// Wall-clock timestamp at record time (UTC, ISO-8601). Kept
    /// alongside the monotonic clock so a breadcrumb delivered via
    /// next-launch crash processing still carries its absolute time.
    public let wallTimestamp: Date
    public let kind: Kind
    /// Short machine-parseable event name. Uses the `kind.name` dotted
    /// form (e.g. `auth.signInStarted`) — stable across builds.
    public let name: String
    /// Bounded string → string attribute dictionary. Each value is
    /// capped at 256 chars at record time; the whole dictionary is
    /// capped at 16 keys. Overflow is silently truncated (with a
    /// `_truncated = "true"` key added) to prevent a misbehaving call
    /// site from blowing out a breadcrumb into kilobytes.
    public let attributes: [String: String]

    public init(
        monotonicMillis: UInt64,
        wallTimestamp: Date,
        kind: Kind,
        name: String,
        attributes: [String: String] = [:],
    ) {
        self.monotonicMillis = monotonicMillis
        self.wallTimestamp = wallTimestamp
        self.kind = kind
        self.name = name
        self.attributes = Self.sanitize(attributes: attributes)
    }

    /// Maximum number of attribute keys per breadcrumb.
    public static let maxAttributeKeys = 16
    /// Maximum length of each attribute value (in characters).
    public static let maxAttributeValueLength = 256

    private static func sanitize(attributes: [String: String]) -> [String: String] {
        var trimmed: [String: String] = [:]
        trimmed.reserveCapacity(min(attributes.count, maxAttributeKeys))
        var truncated = false

        // Keep a deterministic order — sort by key — so a breadcrumb
        // encoded today and decoded after an OS update still has the
        // same structural hash for dedup purposes.
        let keys = attributes.keys.sorted()
        for key in keys.prefix(maxAttributeKeys) {
            guard let raw = attributes[key] else { continue }
            if raw.count > maxAttributeValueLength {
                trimmed[key] = String(raw.prefix(maxAttributeValueLength))
                truncated = true
            } else {
                trimmed[key] = raw
            }
        }
        if keys.count > maxAttributeKeys {
            truncated = true
        }
        if truncated {
            trimmed["_truncated"] = "true"
        }
        return trimmed
    }
}
