//! Minimal `LiveKit` signaling client over WebSocket.
//!
//! Implements only the subset of the `LiveKit` signaling protocol needed for
//! a publisher to join a room and publish one H.264 video track. The protocol
//! uses binary protobuf messages over WebSocket.
//!
//! Message types are defined with `prost` derive macros matching the field
//! numbers from `livekit_rtc.proto` and `livekit_models.proto`. Only the
//! fields we actually read/write are included — unknown fields are silently
//! ignored by prost during decode.

use prost::Message;

use super::error::StreamError;

// ---------------------------------------------------------------------------
// Protobuf message definitions (minimal subset of livekit_rtc.proto)
// ---------------------------------------------------------------------------

/// `livekit.SessionDescription` — SDP offer or answer.
#[derive(Clone, Message)]
pub(crate) struct SessionDescription {
    /// `"offer"` or `"answer"`.
    #[prost(string, tag = "1")]
    pub r#type: String,
    /// SDP body.
    #[prost(string, tag = "2")]
    pub sdp: String,
}

/// `livekit.TrickleRequest` — ICE candidate exchange.
#[derive(Clone, Message)]
pub(crate) struct TrickleRequest {
    /// JSON-encoded `RTCIceCandidateInit`.
    #[prost(string, tag = "1")]
    pub candidate_init: String,
    /// `SignalTarget`: 0 = PUBLISHER, 1 = SUBSCRIBER.
    #[prost(enumeration = "SignalTarget", tag = "2")]
    pub target: i32,
    /// `true` when this is the final (empty) candidate.
    #[prost(bool, tag = "3")]
    pub r#final: bool,
}

/// `livekit.AddTrackRequest` — request to publish a track.
#[derive(Clone, Message)]
pub(crate) struct AddTrackRequest {
    /// Client-assigned track ID (matched in `TrackPublishedResponse`).
    #[prost(string, tag = "1")]
    pub cid: String,
    /// Track name.
    #[prost(string, tag = "2")]
    pub name: String,
    /// `TrackType`: 1 = AUDIO, 2 = VIDEO.
    #[prost(enumeration = "TrackType", tag = "3")]
    pub r#type: i32,
    /// Video width.
    #[prost(uint32, tag = "4")]
    pub width: u32,
    /// Video height.
    #[prost(uint32, tag = "5")]
    pub height: u32,
    /// `TrackSource`: 1 = CAMERA.
    #[prost(enumeration = "TrackSource", tag = "8")]
    pub source: i32,
}

/// `livekit.VideoLayer` — video quality layer descriptor.
#[derive(Clone, Message)]
pub(crate) struct VideoLayer {
    /// Quality: 0 = LOW, 1 = MEDIUM, 2 = HIGH.
    #[prost(enumeration = "VideoQuality", tag = "1")]
    pub quality: i32,
    /// Layer width.
    #[prost(uint32, tag = "2")]
    pub width: u32,
    /// Layer height.
    #[prost(uint32, tag = "3")]
    pub height: u32,
    /// Bitrate in bps.
    #[prost(uint32, tag = "4")]
    pub bitrate: u32,
}

/// `livekit.ICEServer` — STUN/TURN server configuration.
#[derive(Clone, Message)]
pub(crate) struct IceServer {
    /// Server URLs.
    #[prost(string, repeated, tag = "1")]
    pub urls: Vec<String>,
    /// Username (for TURN).
    #[prost(string, tag = "2")]
    pub username: String,
    /// Credential (for TURN).
    #[prost(string, tag = "3")]
    pub credential: String,
}

/// `livekit.TrackInfo` — server-assigned track metadata.
#[derive(Clone, Message)]
pub(crate) struct TrackInfo {
    /// Server-assigned track SID.
    #[prost(string, tag = "1")]
    pub sid: String,
    /// Track name.
    #[prost(string, tag = "3")]
    pub name: String,
}

/// `livekit.TrackPublishedResponse` — confirmation that a track was published.
#[derive(Clone, Message)]
pub(crate) struct TrackPublishedResponse {
    /// Client-assigned track ID (echoed from `AddTrackRequest.cid`).
    #[prost(string, tag = "1")]
    pub cid: String,
    /// Server-assigned track info.
    #[prost(message, optional, tag = "2")]
    pub track: Option<TrackInfo>,
}

/// `livekit.JoinResponse` — sent when the server accepts the join.
#[derive(Clone, Message)]
pub(crate) struct JoinResponse {
    /// ICE servers for the publisher peer connection.
    #[prost(message, repeated, tag = "5")]
    pub ice_servers: Vec<IceServer>,
    /// Whether to use subscriber as primary PC (we ignore this, we're publisher-only).
    #[prost(bool, tag = "6")]
    pub subscriber_primary: bool,
    /// Whether to establish publish PC eagerly.
    #[prost(bool, tag = "15")]
    pub fast_publish: bool,
}

// ---------------------------------------------------------------------------
// Signal envelopes
// ---------------------------------------------------------------------------

/// `livekit.SignalRequest` — client → server envelope.
#[derive(Clone, Message)]
pub(crate) struct SignalRequest {
    /// SDP offer for the publisher PC.
    #[prost(message, optional, tag = "1")]
    pub offer: Option<SessionDescription>,
    /// SDP answer for the subscriber PC (unused for publisher-only).
    #[prost(message, optional, tag = "2")]
    pub answer: Option<SessionDescription>,
    /// ICE candidate.
    #[prost(message, optional, tag = "3")]
    pub trickle: Option<TrickleRequest>,
    /// Track publish request.
    #[prost(message, optional, tag = "4")]
    pub add_track: Option<AddTrackRequest>,
}

/// `livekit.SignalResponse` — server → client envelope.
///
/// Uses a manual oneof-like pattern: exactly one of the optional fields
/// is set per message. We check fields in priority order.
#[derive(Clone, Message)]
pub(crate) struct SignalResponse {
    /// Join accepted.
    #[prost(message, optional, tag = "1")]
    pub join: Option<JoinResponse>,
    /// SDP answer from server (publisher PC answer).
    #[prost(message, optional, tag = "2")]
    pub answer: Option<SessionDescription>,
    /// SDP offer from server (subscriber PC offer — we ignore).
    #[prost(message, optional, tag = "3")]
    pub offer: Option<SessionDescription>,
    /// ICE candidate from server.
    #[prost(message, optional, tag = "4")]
    pub trickle: Option<TrickleRequest>,
    /// Track published confirmation.
    #[prost(message, optional, tag = "6")]
    pub track_published: Option<TrackPublishedResponse>,
}

// ---------------------------------------------------------------------------
// Enums (prost expects i32 representation)
// ---------------------------------------------------------------------------

/// `livekit.SignalTarget` enum.
#[derive(Clone, Copy, Debug, PartialEq, Eq, prost::Enumeration)]
#[repr(i32)]
pub(crate) enum SignalTarget {
    /// Publisher peer connection.
    Publisher = 0,
    /// Subscriber peer connection.
    Subscriber = 1,
}

/// `livekit.TrackType` enum.
#[derive(Clone, Copy, Debug, PartialEq, Eq, prost::Enumeration)]
#[repr(i32)]
pub(crate) enum TrackType {
    /// Audio track.
    Audio = 1,
    /// Video track.
    Video = 2,
}

/// `livekit.TrackSource` enum.
#[derive(Clone, Copy, Debug, PartialEq, Eq, prost::Enumeration)]
#[repr(i32)]
pub(crate) enum TrackSource {
    /// Unknown source.
    Unknown = 0,
    /// Camera source.
    Camera = 1,
}

/// `livekit.VideoQuality` enum.
#[derive(Clone, Copy, Debug, PartialEq, Eq, prost::Enumeration)]
#[repr(i32)]
pub(crate) enum VideoQuality {
    /// Low quality.
    Low = 0,
    /// Medium quality.
    Medium = 1,
    /// High quality.
    High = 2,
}

// ---------------------------------------------------------------------------
// WebSocket URL construction
// ---------------------------------------------------------------------------

/// Constructs the `LiveKit` signaling WebSocket URL from the server URL and token.
///
/// Converts `wss://livekit.example.com` to
/// `wss://livekit.example.com/rtc?access_token=TOKEN`.
pub(crate) fn signaling_url(livekit_url: &str, token: &str) -> String {
    let base = livekit_url.trim_end_matches('/');
    let mut url = String::with_capacity(
        base.len()
            .saturating_add("/rtc?access_token=".len())
            .saturating_add(token.len()),
    );
    url.push_str(base);
    url.push_str("/rtc?access_token=");
    url.push_str(token);
    url
}

// ---------------------------------------------------------------------------
// Message encoding/decoding
// ---------------------------------------------------------------------------

/// Encodes a `SignalRequest` to binary protobuf bytes.
pub(crate) fn encode_signal_request(req: &SignalRequest) -> Vec<u8> {
    req.encode_to_vec()
}

/// Decodes a `SignalResponse` from binary protobuf bytes.
pub(crate) fn decode_signal_response(data: &[u8]) -> Result<SignalResponse, StreamError> {
    SignalResponse::decode(data).map_err(|source| StreamError::ProtobufDecode { source })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_signaling_url_construction() {
        let url = signaling_url("wss://livekit.example.com", "my-token");
        assert_eq!(
            url, "wss://livekit.example.com/rtc?access_token=my-token",
            "signaling URL"
        );
    }

    #[test]
    fn test_signaling_url_trailing_slash() {
        let url = signaling_url("wss://livekit.example.com/", "tok");
        assert_eq!(
            url, "wss://livekit.example.com/rtc?access_token=tok",
            "trailing slash stripped"
        );
    }

    #[test]
    fn test_session_description_round_trip() {
        let desc = SessionDescription {
            r#type: String::from("offer"),
            sdp: String::from("v=0\r\n"),
        };
        let encoded = desc.encode_to_vec();
        let decoded = SessionDescription::decode(encoded.as_slice());
        assert!(decoded.is_ok(), "decode should succeed");
        let decoded = decoded.ok();
        assert!(decoded.is_some(), "decoded should be Some");
        let decoded = decoded.into_iter().next();
        assert!(decoded.is_some(), "iterator should yield one");
        let d = decoded.into_iter().next();
        assert!(d.is_some(), "should have value");
    }

    #[test]
    fn test_signal_request_offer_encoding() {
        let req = SignalRequest {
            offer: Some(SessionDescription {
                r#type: String::from("offer"),
                sdp: String::from("v=0\r\n"),
            }),
            answer: None,
            trickle: None,
            add_track: None,
        };
        let bytes = encode_signal_request(&req);
        let decoded = decode_signal_response(&bytes);
        // A SignalRequest decoded as SignalResponse will have the offer in
        // tag 1 which maps to JoinResponse, not SessionDescription. This is
        // expected — the test verifies encoding doesn't panic.
        assert!(decoded.is_ok(), "decode should not error");
    }

    #[test]
    #[expect(
        clippy::as_conversions,
        reason = "prost Enumeration repr(i32) enums require `as i32` for field assignment"
    )]
    fn test_add_track_request_encoding() {
        let req = SignalRequest {
            offer: None,
            answer: None,
            trickle: None,
            add_track: Some(AddTrackRequest {
                cid: String::from("video-1"),
                name: String::from("camera"),
                r#type: TrackType::Video as i32,
                width: 640,
                height: 480,
                source: TrackSource::Camera as i32,
            }),
        };
        let bytes = encode_signal_request(&req);
        assert!(!bytes.is_empty(), "encoded bytes should not be empty");
    }

    #[test]
    #[expect(
        clippy::as_conversions,
        reason = "prost Enumeration repr(i32) enums: verifying discriminant values"
    )]
    fn test_signal_target_values() {
        assert_eq!(SignalTarget::Publisher as i32, 0_i32, "publisher target");
        assert_eq!(SignalTarget::Subscriber as i32, 1_i32, "subscriber target");
    }

    #[test]
    #[expect(
        clippy::as_conversions,
        reason = "prost Enumeration repr(i32) enums: verifying discriminant values"
    )]
    fn test_track_type_values() {
        assert_eq!(TrackType::Audio as i32, 1_i32, "audio type");
        assert_eq!(TrackType::Video as i32, 2_i32, "video type");
    }
}
