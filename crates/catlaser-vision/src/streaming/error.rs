//! Streaming subsystem error types.

/// Errors from the WebRTC live streaming publisher.
#[derive(Debug, thiserror::Error)]
pub enum StreamError {
    /// WebSocket connection to the `LiveKit` server failed.
    #[error("LiveKit WebSocket connection failed: {reason}")]
    SignalingConnect {
        /// Human-readable connection failure reason.
        reason: String,
    },

    /// WebSocket send/receive error during signaling.
    #[error("LiveKit signaling error: {reason}")]
    Signaling {
        /// Human-readable error detail.
        reason: String,
    },

    /// Protobuf decode error on a received signaling message.
    #[error("signaling protobuf decode error: {source}")]
    ProtobufDecode {
        /// Underlying prost decode error.
        source: prost::DecodeError,
    },

    /// The `LiveKit` server rejected the join request.
    #[error("LiveKit join rejected: {reason}")]
    JoinRejected {
        /// Rejection reason from the server.
        reason: String,
    },

    /// str0m WebRTC error during ICE/DTLS/SRTP negotiation or media transport.
    #[error("WebRTC error: {source}")]
    Webrtc {
        /// Underlying str0m error.
        source: str0m::RtcError,
    },

    /// The SDP offer/answer exchange failed.
    #[error("SDP negotiation failed: {reason}")]
    SdpNegotiation {
        /// Human-readable failure detail.
        reason: String,
    },

    /// The streaming thread panicked or exited unexpectedly.
    #[error("streaming thread exited: {reason}")]
    ThreadExit {
        /// Exit reason.
        reason: String,
    },

    /// The encoded frame channel was disconnected.
    #[error("encoder frame channel disconnected")]
    ChannelDisconnected,

    /// The publisher is not in a state to accept the requested operation.
    #[error("invalid publisher state for {operation}: currently {state}")]
    InvalidState {
        /// Operation that was attempted.
        operation: &'static str,
        /// Current publisher state.
        state: &'static str,
    },
}
