import Foundation

/// Non-empty set of LiveKit hostnames the app will dial for live video.
///
/// The `StreamOffer` received from the device carries a `livekit_url`
/// field (see `proto/catlaser/app/v1/app.proto`) that the app passes
/// directly to the LiveKit SDK's `room.connect(url:token:...)`. Without
/// an allowlist at this boundary, a compromised or mis-provisioned
/// device could steer the app to an attacker-controlled LiveKit host —
/// the subscriber JWT's signature is generated on the device, so an
/// attacker who controls both the URL and the LiveKit project would be
/// accepted by their own LiveKit server. The allowlist makes that
/// impossible: any URL whose host is not in this set is refused before
/// the LiveKit SDK is ever handed the dial target.
///
/// The type is deliberately a tiny value type with a single required
/// non-empty set. Construction fails loudly on an empty allowlist so a
/// composition root that "forgot to set it" cannot end up bypassing
/// the check with a permissive default. The app target owns deciding
/// which hosts belong in here — typically a single operator-managed
/// LiveKit deployment URL, read from a compile-time constant or an
/// `Info.plist` key, never from user input.
///
/// Host matching is case-insensitive (DNS names are case-insensitive on
/// the wire) but otherwise exact: a leading `.` / port suffix / wildcard
/// is NOT supported. Callers that need a wildcard must expand it
/// themselves at construction time, so the allowlist's membership is
/// always a finite, auditable list.
public struct LiveKitHostAllowlist: Sendable, Equatable {
    private let normalizedHosts: Set<String>

    /// Construct from a set of hostnames. Each host is lowercased and
    /// trimmed; empty entries and the empty set are rejected.
    ///
    /// - Throws: `LiveKitHostAllowlistError.empty` if no valid entries
    ///   survive normalization. Fail-loud because a "no allowed hosts"
    ///   allowlist would silently permit zero — which, composed with
    ///   the default behavior of LiveKit's SDK accepting any host it
    ///   is handed, would allow everything instead.
    public init(hosts: some Sequence<String>) throws(LiveKitHostAllowlistError) {
        var seen: Set<String> = []
        for raw in hosts {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { continue }
            seen.insert(trimmed)
        }
        guard !seen.isEmpty else {
            throw .empty
        }
        self.normalizedHosts = seen
    }

    /// Convenience for composition roots wiring a single operator host.
    public init(singleHost: String) throws(LiveKitHostAllowlistError) {
        try self.init(hosts: [singleHost])
    }

    /// Return true iff `host` matches a normalized entry in the set.
    /// Case-insensitive; exact match, no wildcarding.
    public func contains(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalized.isEmpty && normalizedHosts.contains(normalized)
    }

    /// Sorted list of allowed hosts (for diagnostics only — production
    /// code paths compare via `contains(_:)`).
    public var sortedHosts: [String] { normalizedHosts.sorted() }
}

public enum LiveKitHostAllowlistError: Error, Equatable, Sendable {
    /// Construction received zero non-empty hosts. A live-video app
    /// that runs with an empty allowlist would either reject every
    /// stream (denial of service) or — worse, if a future refactor
    /// added a "fall back to accept" branch — permit everything. Both
    /// outcomes are bad; construction refusing is the safest one.
    case empty
}
