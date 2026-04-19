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
        try self.init(rawURLString: url.absoluteString, token: token, allowlist: allowlist)
    }

    /// Convenience initializer from the proto envelope.
    public init(
        offer: Catlaser_App_V1_StreamOffer,
        allowlist: LiveKitHostAllowlist,
    ) throws(LiveStreamCredentialsError) {
        try self.init(
            rawURLString: offer.livekitURL,
            token: offer.subscriberToken,
            allowlist: allowlist,
        )
    }

    /// Validate a raw LiveKit URL string and rebuild the canonical
    /// `wss://host[:port]/path[?query]` form from its validated
    /// components.
    ///
    /// ## Why we don't pass the raw URL through
    ///
    /// `LiveKitStreamSession` hands the LiveKit SDK
    /// `credentials.url.absoluteString`. The SDK re-parses that string
    /// with its own URL logic, which is not guaranteed to agree with
    /// Foundation's `URL(string:)` on edge-case inputs:
    ///
    /// * userinfo: `wss://allowed.example.com\@attacker.com/`
    ///   — Foundation may extract `allowed.example.com` as host, but a
    ///   different parser may take `attacker.com`.
    /// * percent-encoded host bytes: `wss://allowed%2eexample%2ecom/`
    ///   — some parsers normalise; some don't.
    /// * trailing dot: `wss://allowed.example.com./`
    ///   — `URL.host` may include the dot; the allowlist's exact match
    ///   then fails locally but the SDK might still resolve it.
    /// * IPv6 with embedded port + userinfo: `wss://[::1]:443@attacker/`.
    /// * fragment: `wss://allowed.example.com/#@attacker.com`
    ///   — fragments have no place in a `wss://` dial target.
    ///
    /// The allowlist check is meaningful only if the host the app
    /// validated is the host the SDK ultimately dials. Reconstructing
    /// the URL from individually-validated `URLComponents` fields
    /// closes the gap: the string we hand the SDK contains exactly
    /// the scheme, host, port, path, and query we approved — no
    /// userinfo, no fragment, no smuggled authority.
    private init(
        rawURLString: String,
        token: String,
        allowlist: LiveKitHostAllowlist,
    ) throws(LiveStreamCredentialsError) {
        guard !rawURLString.isEmpty,
              let components = URLComponents(string: rawURLString)
        else {
            throw .invalidURL
        }

        // Signaling must be TLS-encrypted. LiveKit's subscriber JWT grants
        // room-join rights for the duration of the token; on a plaintext
        // `ws://` connection that JWT — and the signaling channel that
        // carries SDP and ICE metadata — is visible to every network hop
        // between the app and the LiveKit server. For a product that
        // streams video of the user's home, the allowlist is a single
        // scheme. No http, no ws, no local-dev escape hatch compiled into
        // shipping code — a debug build that needs plaintext must patch
        // this file, not flip a flag.
        guard let scheme = components.scheme?.lowercased(), scheme == "wss" else {
            throw .invalidURLScheme
        }

        // No userinfo and no fragment — both are suspicious in a wss
        // dial target and are the most common parser-disagreement
        // vector. Refuse rather than try to sanitise.
        guard components.user == nil, components.password == nil else {
            throw .invalidURL
        }
        guard components.fragment == nil else {
            throw .invalidURL
        }

        // `URLComponents.host` is the authoritative host according to
        // Foundation's RFC 3986 parser. Lowercasing matches the
        // case-insensitive DNS contract and the allowlist's
        // normalisation.
        guard let rawHost = components.host?.lowercased(), !rawHost.isEmpty else {
            throw .invalidURL
        }
        // Strip a trailing root-domain dot before checking the
        // allowlist — `example.com.` and `example.com` resolve to the
        // same hostname but exact-string match would otherwise reject
        // the FQDN form. Stripping at this single boundary keeps the
        // allowlist a finite, auditable list of bare hostnames.
        let host: String
        if rawHost.hasSuffix("."), rawHost.count > 1 {
            host = String(rawHost.dropLast())
        } else {
            host = rawHost
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

        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw .missingToken
        }

        // Rebuild from scratch using only validated components. The
        // resulting URL string is what `LiveKitStreamSession` hands
        // the SDK — guaranteed not to contain any field that didn't
        // pass through this validator.
        var rebuilt = URLComponents()
        rebuilt.scheme = "wss"
        rebuilt.host = host
        if let port = components.port {
            rebuilt.port = port
        }
        rebuilt.path = components.path
        if let queryItems = components.queryItems, !queryItems.isEmpty {
            rebuilt.queryItems = queryItems
        }
        guard let rebuiltURL = rebuilt.url else {
            throw .invalidURL
        }

        self.url = rebuiltURL
        self.token = trimmedToken
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
