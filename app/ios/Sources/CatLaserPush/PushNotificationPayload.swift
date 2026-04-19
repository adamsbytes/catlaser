import Foundation

/// Typed parse of the FCM `data` dictionary emitted by the device's
/// ``catlaser_brain.network.push.PushNotifier``.
///
/// The four outbound FCM message types sent by ``push.py`` map to the
/// same number of enum cases. A fifth ``unknown`` case absorbs anything
/// the device might emit in the future without crashing the client —
/// the app still renders whatever the OS banner carries, but the deep
/// link falls back to the app's default screen. This is the shape the
/// server-side sender is documented to produce; any drift lands as
/// ``unknown`` rather than as a runtime trap.
///
/// Parsing is fail-open on optional fields and fail-closed on the
/// ``type`` discriminator. Missing numeric fields default to zero (not
/// to a crash) because the device occasionally emits a partial payload
/// in a transitional state (e.g. a hopper-empty push before the first
/// session summary has populated the session counters). The banner is
/// still meaningful; the UI just renders the defaulted zeros.
public enum PushNotificationPayload: Sendable, Equatable {
    case sessionSummary(SessionSummary)
    case sessionStarted(SessionStarted)
    case hopperEmpty
    case newCatDetected(NewCatDetected)
    case unknown(type: String)

    /// `data` dict key every push carries (matches the
    /// ``"type": ...`` field ``push.py`` writes on every outbound
    /// message).
    public static let typeKey = "type"

    /// Map the four known type strings to typed payloads. Mirrors
    /// ``_PUSH_PLATFORM_MAP`` in the Python dispatcher: a typed surface
    /// means a drift on either side surfaces as an explicit case add,
    /// not as a silent wrong-banner rendering.
    public static let sessionSummaryType = "session_summary"
    public static let sessionStartedType = "session_started"
    public static let hopperEmptyType = "hopper_empty"
    public static let newCatDetectedType = "new_cat_detected"

    public struct SessionSummary: Sendable, Equatable {
        /// Comma-joined cat-display-names (``push.py``:
        /// ``",".join(cat_names)``). Empty strings map to an empty
        /// ``catNames`` array.
        public var catNames: [String]
        public var durationSec: UInt32
        public var engagementScore: Double
        public var treatsDispensed: UInt32
        public var pounceCount: UInt32

        public init(
            catNames: [String],
            durationSec: UInt32,
            engagementScore: Double,
            treatsDispensed: UInt32,
            pounceCount: UInt32,
        ) {
            self.catNames = catNames
            self.durationSec = durationSec
            self.engagementScore = engagementScore
            self.treatsDispensed = treatsDispensed
            self.pounceCount = pounceCount
        }
    }

    public struct SessionStarted: Sendable, Equatable {
        public var catNames: [String]
        public var trigger: String

        public init(catNames: [String], trigger: String) {
            self.catNames = catNames
            self.trigger = trigger
        }
    }

    public struct NewCatDetected: Sendable, Equatable {
        public var trackIDHint: UInt32
        public var confidence: Double

        public init(trackIDHint: UInt32, confidence: Double) {
            self.trackIDHint = trackIDHint
            self.confidence = confidence
        }
    }

    /// Parse a raw FCM `data` dictionary into a typed payload.
    ///
    /// The dictionary shape matches every ``PushNotifier.notify_*``
    /// method in ``python/catlaser_brain/network/push.py``:
    ///
    /// * ``type`` — always present. Missing or empty → ``.unknown("")``.
    /// * Numeric fields — parsed permissively. A non-numeric value is
    ///   treated as zero rather than a failure; the banner already
    ///   shows its own title/body and the in-app surfaces that re-fetch
    ///   authoritative values do so via the device channel anyway.
    ///
    /// The returned value is never nil — an unparseable payload lands
    /// in ``.unknown`` so the UN delegate can still route to the
    /// default deep link (nothing). Returning nil would push the
    /// "what do we do when the type is unrecognised?" question up into
    /// the caller for zero benefit.
    public static func parse(data: [String: String]) -> PushNotificationPayload {
        let type = data[typeKey] ?? ""
        switch type {
        case sessionSummaryType:
            let catNames = splitNames(data["cat_names"])
            let payload = SessionSummary(
                catNames: catNames,
                durationSec: parseUInt32(data["duration_sec"]),
                engagementScore: parseDouble(data["engagement_score"]),
                treatsDispensed: parseUInt32(data["treats_dispensed"]),
                pounceCount: parseUInt32(data["pounce_count"]),
            )
            return .sessionSummary(payload)
        case sessionStartedType:
            let catNames = splitNames(data["cat_names"])
            let trigger = data["trigger"] ?? ""
            return .sessionStarted(SessionStarted(catNames: catNames, trigger: trigger))
        case hopperEmptyType:
            return .hopperEmpty
        case newCatDetectedType:
            return .newCatDetected(
                NewCatDetected(
                    trackIDHint: parseUInt32(data["track_id_hint"]),
                    confidence: parseDouble(data["confidence"]),
                ),
            )
        default:
            return .unknown(type: type)
        }
    }

    // MARK: - Parsing helpers

    /// Split ``"a,b,c"`` into ``["a", "b", "c"]``. Empty input or a
    /// trailing/leading comma produces an empty element, which we
    /// drop — the sender emits ``",".join(cat_names)`` over a list
    /// that is already filtered to non-empty display names, but a
    /// defensive filter here costs nothing and tolerates a future
    /// change on the server side that drops the filter.
    private static func splitNames(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func parseUInt32(_ raw: String?) -> UInt32 {
        guard let raw, let value = UInt32(raw) else { return 0 }
        return value
    }

    private static func parseDouble(_ raw: String?) -> Double {
        guard let raw, let value = Double(raw) else { return 0 }
        return value
    }
}
