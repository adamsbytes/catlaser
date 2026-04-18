import CatLaserProto
import Foundation

/// Subscribe-side LiveKit credentials handed to the app by the device.
///
/// Derived from `Catlaser_App_V1_StreamOffer` (`app.proto`) when the
/// device responds to `StartStreamRequest`. The device's behavior
/// engine owns token minting (see `python/catlaser_brain/network/streaming.py`);
/// the app never sees the LiveKit API key/secret — only a short-lived
/// JWT scoped to the subscriber role.
///
/// This struct validates the wire values at construction so a `LiveKit`
/// connect call does not have to re-check them. Invalid offers turn
/// into `LiveViewError.streamOfferMissing` at the view-model layer.
public struct LiveStreamCredentials: Sendable, Equatable {
    /// `wss://...` URL the LiveKit client should dial.
    public let url: URL

    /// Short-lived LiveKit access token (JWT) scoped to `canSubscribe`.
    public let token: String

    public init(url: URL, token: String) throws(LiveStreamCredentialsError) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "wss" || scheme == "ws" || scheme == "https" || scheme == "http"
        else {
            throw .invalidURLScheme
        }
        guard url.host?.isEmpty == false else {
            throw .invalidURL
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw .missingToken
        }
        self.url = url
        self.token = trimmed
    }

    /// Convenience initializer from the proto envelope.
    public init(offer: Catlaser_App_V1_StreamOffer) throws(LiveStreamCredentialsError) {
        guard let url = URL(string: offer.livekitURL), !offer.livekitURL.isEmpty else {
            throw .invalidURL
        }
        try self.init(url: url, token: offer.subscriberToken)
    }
}

public enum LiveStreamCredentialsError: Error, Equatable, Sendable {
    case invalidURL
    case invalidURLScheme
    case missingToken
}
