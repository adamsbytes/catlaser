import Foundation

/// One outstanding "name this cat" request raised by the device.
///
/// The device pushes ``Catlaser_App_V1_NewCatDetected`` events
/// (typically via APNs but also as in-band ``DeviceEvent`` pushes once
/// the TCP channel is open) when a track was confirmed but did not
/// match any catalogued embedding. The history screen surfaces a
/// modal sheet for each pending prompt so the user can name the cat,
/// which the VM forwards as ``Catlaser_App_V1_IdentifyNewCatRequest``.
///
/// The structure is deliberately a value type — ``HistoryViewModel``
/// holds a queue of these and pops the head when the user dismisses or
/// resolves the prompt. The track-id-hint identifies which pending
/// embedding the device should resolve; sending the wrong hint to
/// ``identify_new_cat`` produces a typed `NOT_FOUND` from the device,
/// which the VM surfaces as ``HistoryError.notFound``.
public struct NewCatPrompt: Identifiable, Sendable, Equatable {
    /// The track id assigned by the vision pipeline at confirmation
    /// time. Stable for the lifetime of the unresolved track and used
    /// as the wire identifier on ``IdentifyNewCatRequest.track_id_hint``.
    /// Used as ``Identifiable.id`` so SwiftUI can drive sheet
    /// presentation off it directly.
    public let trackIDHint: UInt32

    /// JPEG thumbnail crop pushed alongside the event. Held as raw
    /// bytes so the sheet can render via `UIImage(data:)` without the
    /// VM depending on UIKit. Empty for tests / pushes that arrived
    /// without a thumbnail attached.
    public let thumbnail: Data

    /// Identification confidence reported by the device's re-id
    /// model. Currently informational only — used by the sheet to
    /// surface a low-confidence hint, not to gate the naming flow.
    public let confidence: Float

    public var id: UInt32 { trackIDHint }

    public init(trackIDHint: UInt32, thumbnail: Data, confidence: Float) {
        self.trackIDHint = trackIDHint
        self.thumbnail = thumbnail
        self.confidence = confidence
    }
}
