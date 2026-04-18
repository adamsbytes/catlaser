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

    public init(
        url: URL,
        token: String,
        allowlist: LiveKitHostAllowlist,
    ) throws(LiveStreamCredentialsError) {
        // Signaling must be TLS-encrypted. LiveKit's subscriber JWT grants
        // room-join rights for the duration of the token; on a plaintext
        // `ws://` connection that JWT — and the signaling channel that
        // carries SDP and ICE metadata — is visible to every network hop
        // between the app and the LiveKit server. For a product that
        // streams video of the user's home, the allowlist is a single
        // scheme. No http, no ws, no local-dev escape hatch compiled into
        // shipping code — a debug build that needs plaintext must patch
        // this file, not flip a flag.
        guard let scheme = url.scheme?.lowercased(), scheme == "wss" else {
            throw .invalidURLScheme
        }
        guard let host = url.host, !host.isEmpty else {
            throw .invalidURL
        }
        // The host MUST be in the operator-provisioned allowlist.
        // Without this check a compromised device could hand the app
        // an attacker-controlled `wss://` URL; the LiveKit SDK has
        // no notion of "which hosts are ours" and would dial happily.
        // The allowlist is an app-target constant, not a `StreamOffer`
        // field, so the device cannot influence it.
        guard allowlist.contains(host) else {
            throw .hostNotAllowed(host)
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw .missingToken
        }
        self.url = url
        self.token = trimmed
    }

    /// Convenience initializer from the proto envelope.
    public init(
        offer: Catlaser_App_V1_StreamOffer,
        allowlist: LiveKitHostAllowlist,
    ) throws(LiveStreamCredentialsError) {
        guard let url = URL(string: offer.livekitURL), !offer.livekitURL.isEmpty else {
            throw .invalidURL
        }
        try self.init(url: url, token: offer.subscriberToken, allowlist: allowlist)
    }
}

public enum LiveStreamCredentialsError: Error, Equatable, Sendable {
    case invalidURL
    case invalidURLScheme
    case missingToken
    /// The `StreamOffer`'s host is not in the app's LiveKit allowlist.
    /// Most common cause: a misprovisioned device or a tampered stream
    /// offer. The carried `String` is the rejected host, for
    /// diagnostics — never echoed to the user as-is.
    case hostNotAllowed(String)
}
