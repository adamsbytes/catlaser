//! WebRTC video publisher using str0m and `LiveKit` signaling.
//!
//! Connects to a `LiveKit` room via WebSocket signaling, negotiates a WebRTC
//! peer connection using str0m, and publishes pre-encoded H.264 video frames
//! received from the encoder via a crossbeam channel.
//!
//! Runs on a dedicated thread with str0m's synchronous polling API — no
//! Tokio runtime required.

use std::net::UdpSocket;
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, Sender};
use str0m::format::Codec;
use str0m::media::{MediaTime, Mid};
use str0m::net::{Protocol, Receive};
use str0m::{Event, Input, Output, Rtc};
use tungstenite::Message as WsMessage;

use super::error::StreamError;
use super::signaling::{
    self, AddTrackRequest, SessionDescription, SignalRequest, SignalTarget, TrackSource, TrackType,
};
use crate::encoder::EncodedFrame;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Client track ID used in `AddTrackRequest`. Matched against
/// `TrackPublishedResponse.cid` to confirm publication.
const VIDEO_TRACK_CID: &str = "catlaser-video";

/// H.264 clock rate (90 kHz) per RFC 6184.
const H264_CLOCK_RATE: u64 = 90_000;

/// str0m polling timeout when waiting for network events.
const POLL_TIMEOUT: Duration = Duration::from_millis(50);

// ---------------------------------------------------------------------------
// Publisher state
// ---------------------------------------------------------------------------

/// Current state of the streaming publisher.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PublisherState {
    /// Not connected. Ready to start.
    Idle,
    /// WebSocket connected, SDP negotiation in progress.
    Connecting,
    /// ICE connected, media flowing.
    Publishing,
    /// Encountered an error. Call `stop()` to reset.
    Error,
}

impl PublisherState {
    /// Returns a static string for logging and error messages.
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Connecting => "connecting",
            Self::Publishing => "publishing",
            Self::Error => "error",
        }
    }
}

// ---------------------------------------------------------------------------
// Stream configuration
// ---------------------------------------------------------------------------

/// Configuration for a streaming session.
#[derive(Debug, Clone)]
pub(crate) struct StreamConfig {
    /// `LiveKit` server URL (e.g. `wss://livekit.example.com`).
    pub livekit_url: String,
    /// JWT token for the publisher to join the room.
    pub publisher_token: String,
    /// Room name (for logging).
    pub room_name: String,
    /// Target video bitrate in bits per second.
    pub target_bitrate_bps: u32,
    /// Video width (for the `AddTrackRequest`).
    pub width: u32,
    /// Video height.
    pub height: u32,
}

// ---------------------------------------------------------------------------
// Publisher run loop
// ---------------------------------------------------------------------------

/// Runs the streaming publisher on the current thread.
///
/// Connects to `LiveKit`, negotiates WebRTC, and streams encoded frames
/// from the channel until the channel is disconnected (signaling stop)
/// or a fatal error occurs. Forwards every WebRTC keyframe request from
/// the receiver to `keyframe_tx` so the encoder on the main pipeline
/// thread can produce an IDR on the next encode.
///
/// This function blocks until streaming ends. Designed to be called from
/// a dedicated thread spawned by the pipeline.
pub(crate) fn run_publisher(
    config: &StreamConfig,
    frame_rx: &Receiver<EncodedFrame>,
    state_tx: &Sender<PublisherState>,
    keyframe_tx: &Sender<()>,
) -> Result<(), StreamError> {
    let _ = state_tx.send(PublisherState::Connecting);

    let (mut ws, mut rtc, mid, socket, local_addr) = negotiate_session(config)?;

    // Switch WebSocket to non-blocking for the poll loop.
    if let tungstenite::stream::MaybeTlsStream::Plain(stream) = ws.get_ref() {
        drop(stream.set_nonblocking(true));
    }

    let _ = state_tx.send(PublisherState::Publishing);
    tracing::info!(room = %config.room_name, "streaming started");

    let frame_count = stream_loop(
        &mut rtc,
        &mut ws,
        mid,
        &socket,
        local_addr,
        frame_rx,
        state_tx,
        keyframe_tx,
    )?;

    let _ = state_tx.send(PublisherState::Idle);
    tracing::info!(frames = frame_count, "streaming stopped");
    Ok(())
}

// ---------------------------------------------------------------------------
// Session negotiation
// ---------------------------------------------------------------------------

/// Type alias for the WebSocket connection used by the publisher.
type WsConn = tungstenite::WebSocket<tungstenite::stream::MaybeTlsStream<std::net::TcpStream>>;

/// Connects to the `LiveKit` signaling server, negotiates SDP, and returns
/// the established session components.
fn negotiate_session(
    config: &StreamConfig,
) -> Result<(WsConn, Rtc, Mid, UdpSocket, std::net::SocketAddr), StreamError> {
    // --- WebSocket connect ---
    let ws_url = signaling::signaling_url(&config.livekit_url, &config.publisher_token);
    let (mut ws, _response) =
        tungstenite::connect(&ws_url).map_err(|err| StreamError::SignalingConnect {
            reason: err.to_string(),
        })?;

    // --- Wait for JoinResponse ---
    let join = loop {
        let msg = ws.read().map_err(|err| StreamError::Signaling {
            reason: err.to_string(),
        })?;
        if let WsMessage::Binary(data) = msg {
            let resp = signaling::decode_signal_response(&data)?;
            if let Some(join) = resp.join {
                break join;
            }
        }
    };

    tracing::info!(
        ice_servers = join.ice_servers.len(),
        subscriber_primary = join.subscriber_primary,
        fast_publish = join.fast_publish,
        "joined LiveKit room"
    );

    // --- Create str0m peer connection ---
    let mut rtc = Rtc::builder().build(Instant::now());

    // Bind a UDP socket for media transport.
    let socket = UdpSocket::bind("0.0.0.0:0").map_err(|err| StreamError::SignalingConnect {
        reason: format!("UDP bind: {err}"),
    })?;
    socket
        .set_nonblocking(true)
        .map_err(|err| StreamError::SignalingConnect {
            reason: format!("UDP set_nonblocking: {err}"),
        })?;

    let local_addr = socket
        .local_addr()
        .map_err(|err| StreamError::SignalingConnect {
            reason: format!("local_addr: {err}"),
        })?;

    // Add local candidate (the UDP socket we bound).
    let local_candidate = str0m::Candidate::host(local_addr, Protocol::Udp).map_err(|err| {
        StreamError::SdpNegotiation {
            reason: format!("local candidate: {err}"),
        }
    })?;
    rtc.add_local_candidate(local_candidate);

    // Publish the video track, exchange SDP, and apply the answer.
    let mid = exchange_sdp(&mut ws, &mut rtc, config)?;

    Ok((ws, rtc, mid, socket, local_addr))
}

// ---------------------------------------------------------------------------
// SDP exchange
// ---------------------------------------------------------------------------

/// Sends an `AddTrackRequest`, creates an SDP offer, waits for the answer,
/// and applies it to the RTC peer connection.
#[expect(
    clippy::as_conversions,
    reason = "prost Enumeration repr(i32) enums require `as i32` for field assignment"
)]
fn exchange_sdp(ws: &mut WsConn, rtc: &mut Rtc, config: &StreamConfig) -> Result<Mid, StreamError> {
    // Request to publish video track.
    let add_track = SignalRequest {
        offer: None,
        answer: None,
        trickle: None,
        add_track: Some(AddTrackRequest {
            cid: String::from(VIDEO_TRACK_CID),
            name: String::from("camera"),
            r#type: TrackType::Video as i32,
            width: config.width,
            height: config.height,
            source: TrackSource::Camera as i32,
        }),
    };
    ws.send(WsMessage::Binary(
        signaling::encode_signal_request(&add_track).into(),
    ))
    .map_err(|err| StreamError::Signaling {
        reason: format!("send AddTrack: {err}"),
    })?;

    // Create SDP offer.
    let mut change = rtc.sdp_api();
    let mid = change.add_media(
        str0m::media::MediaKind::Video,
        str0m::media::Direction::SendOnly,
        None,
        None,
        None,
    );
    let Some((offer, pending)) = change.apply() else {
        return Err(StreamError::SdpNegotiation {
            reason: String::from("SDP change produced no offer"),
        });
    };

    let offer_sdp = offer.to_sdp_string();

    // Send SDP offer to LiveKit.
    let offer_req = SignalRequest {
        offer: Some(SessionDescription {
            r#type: String::from("offer"),
            sdp: offer_sdp,
        }),
        answer: None,
        trickle: None,
        add_track: None,
    };
    ws.send(WsMessage::Binary(
        signaling::encode_signal_request(&offer_req).into(),
    ))
    .map_err(|err| StreamError::Signaling {
        reason: format!("send SDP offer: {err}"),
    })?;

    // Wait for SDP answer, relaying trickle candidates along the way.
    let answer_sdp = loop {
        let msg = ws.read().map_err(|err| StreamError::Signaling {
            reason: format!("read SDP answer: {err}"),
        })?;
        if let WsMessage::Binary(data) = msg {
            let resp = signaling::decode_signal_response(&data)?;
            if let Some(answer) = resp.answer {
                break answer.sdp;
            }
            relay_trickle_candidate(resp.trickle, rtc);
        }
    };

    // Apply the SDP answer.
    let answer = str0m::change::SdpAnswer::from_sdp_string(&answer_sdp).map_err(|err| {
        StreamError::SdpNegotiation {
            reason: format!("parse SDP answer: {err}"),
        }
    })?;
    rtc.sdp_api()
        .accept_answer(pending, answer)
        .map_err(|err| StreamError::Webrtc { source: err })?;

    Ok(mid)
}

// ---------------------------------------------------------------------------
// Trickle ICE helper
// ---------------------------------------------------------------------------

/// Relays a trickle ICE candidate from the signaling server to the RTC peer
/// connection, if it targets the publisher.
#[expect(
    clippy::as_conversions,
    reason = "prost Enumeration repr(i32) enum: SignalTarget::Publisher discriminant comparison"
)]
fn relay_trickle_candidate(trickle: Option<signaling::TrickleRequest>, rtc: &mut Rtc) {
    if let Some(trickle) = trickle
        && trickle.target == SignalTarget::Publisher as i32
        && let Ok(candidate) = str0m::Candidate::from_sdp_string(&trickle.candidate_init)
    {
        rtc.add_remote_candidate(candidate);
    }
}

// ---------------------------------------------------------------------------
// Streaming loop
// ---------------------------------------------------------------------------

/// Runs the main frame-sending and event-polling loop.
///
/// Returns the total number of frames sent on success.
#[expect(
    clippy::too_many_arguments,
    reason = "the publisher loop owns a synchronous state machine across str0m, the WebSocket, \
              the UDP socket, and three channels; bundling them into a struct is a refactor for \
              another day and would not improve clarity"
)]
fn stream_loop(
    rtc: &mut Rtc,
    ws: &mut WsConn,
    mid: Mid,
    socket: &UdpSocket,
    local_addr: std::net::SocketAddr,
    frame_rx: &Receiver<EncodedFrame>,
    state_tx: &Sender<PublisherState>,
    keyframe_tx: &Sender<()>,
) -> Result<u64, StreamError> {
    let start = Instant::now();
    let mut buf = vec![0_u8; 2000];
    let mut frame_count = 0_u64;

    loop {
        // Check for new encoded frames from the encoder.
        match frame_rx.try_recv() {
            Ok(frame) => {
                write_frame(rtc, mid, &frame, start);
                frame_count = frame_count.saturating_add(1_u64);
            }
            Err(crossbeam_channel::TryRecvError::Empty) => {}
            Err(crossbeam_channel::TryRecvError::Disconnected) => {
                tracing::info!(frames = frame_count, "frame channel closed, stopping");
                break;
            }
        }

        // Drive str0m's event loop.
        match rtc.poll_output() {
            Ok(Output::Transmit(transmit)) => {
                drop(socket.send_to(&transmit.contents, transmit.destination));
            }
            Ok(Output::Timeout(deadline)) => {
                let timeout = deadline.saturating_duration_since(Instant::now());
                let sleep = timeout.min(POLL_TIMEOUT);
                std::thread::sleep(sleep);
            }
            Ok(Output::Event(event)) => {
                handle_event(&event, keyframe_tx);
            }
            Err(err) => {
                tracing::error!(%err, "str0m error");
                let _ = state_tx.send(PublisherState::Error);
                return Err(StreamError::Webrtc { source: err });
            }
        }

        // Read incoming UDP packets.
        loop {
            match socket.recv_from(&mut buf) {
                Ok((n, source)) => {
                    if let Some(data) = buf.get(..n) {
                        let receive = Receive::new(Protocol::Udp, source, local_addr, data);
                        if let Ok(receive) = receive {
                            drop(rtc.handle_input(Input::Receive(Instant::now(), receive)));
                        }
                    }
                }
                Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(_) => break,
            }
        }

        // Read signaling messages (non-blocking).
        match ws.read() {
            Ok(WsMessage::Binary(data)) => {
                if let Ok(resp) = signaling::decode_signal_response(&data) {
                    relay_trickle_candidate(resp.trickle, rtc);
                }
            }
            Ok(WsMessage::Close(_)) => {
                tracing::info!("LiveKit signaling closed");
                break;
            }
            Err(tungstenite::Error::Io(err)) if err.kind() == std::io::ErrorKind::WouldBlock => {
                // No message available, continue.
            }
            Err(_) => {
                // Signaling error — the media connection may still work
                // via ICE keepalive, so log but don't abort.
                tracing::warn!("signaling read error, continuing");
            }
            _ => {}
        }

        // Check ICE state.
        if !rtc.is_connected() && frame_count > 0_u64 {
            tracing::info!("ICE connection lost");
            break;
        }
    }

    Ok(frame_count)
}

// ---------------------------------------------------------------------------
// Frame writing
// ---------------------------------------------------------------------------

/// Writes an encoded H.264 frame to the str0m media track.
fn write_frame(rtc: &mut Rtc, mid: Mid, frame: &EncodedFrame, start: Instant) {
    let Some(writer) = rtc.writer(mid) else {
        return;
    };

    // Compute RTP timestamp from wall clock offset at 90kHz.
    let elapsed = frame.timestamp().saturating_duration_since(start);
    let rtp_time_90khz = elapsed
        .as_micros()
        .saturating_mul(u128::from(H264_CLOCK_RATE))
        .checked_div(1_000_000)
        .unwrap_or(0);

    #[expect(
        clippy::as_conversions,
        clippy::cast_possible_truncation,
        reason = "u128 -> u64: at 90kHz, overflow requires ~6.5 million years of continuous \
                  streaming. Truncation is intentional -- RTP timestamps wrap at 2^32 and \
                  str0m handles the wrap internally."
    )]
    let rtp_time = rtp_time_90khz as u64;

    // Find the H.264 payload type from the negotiated codec parameters.
    let pt = writer
        .payload_params()
        .find(|p| p.spec().codec == Codec::H264)
        .map(str0m::format::PayloadParams::pt);

    let Some(pt) = pt else {
        tracing::warn!("no H.264 payload type negotiated");
        return;
    };

    let freq = str0m::media::Frequency::NINETY_KHZ;
    let media_time = MediaTime::new(rtp_time, freq);

    if let Err(err) = writer.write(pt, frame.timestamp(), media_time, frame.data()) {
        tracing::warn!(%err, "failed to write frame to str0m");
    }
}

// ---------------------------------------------------------------------------
// Event handling
// ---------------------------------------------------------------------------

/// Handles str0m events (ICE candidates, keyframe requests, etc.).
///
/// On every keyframe request from the WebRTC receiver, posts a
/// non-blocking notification to `keyframe_tx`. The pipeline thread drains
/// the channel each frame and forces an IDR via the encoder. A full
/// channel (capacity 1) means a request is already pending — the next
/// IDR will satisfy both, so dropping the notification is correct.
fn handle_event(event: &Event, keyframe_tx: &Sender<()>) {
    match event {
        Event::IceConnectionStateChange(state) => {
            tracing::info!(?state, "ICE state changed");
        }
        Event::KeyframeRequest(req) => {
            tracing::debug!(?req, "keyframe requested by receiver");
            // Non-blocking: capacity 1 with coalescing semantics.
            let _ = keyframe_tx.try_send(());
        }
        _ => {}
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_publisher_state_as_str() {
        assert_eq!(PublisherState::Idle.as_str(), "idle", "idle state string");
        assert_eq!(
            PublisherState::Connecting.as_str(),
            "connecting",
            "connecting state string"
        );
        assert_eq!(
            PublisherState::Publishing.as_str(),
            "publishing",
            "publishing state string"
        );
        assert_eq!(
            PublisherState::Error.as_str(),
            "error",
            "error state string"
        );
    }

    #[test]
    fn test_stream_config_construction() {
        let config = StreamConfig {
            livekit_url: String::from("wss://test"),
            publisher_token: String::from("tok"),
            room_name: String::from("room"),
            target_bitrate_bps: 500_000,
            width: 640,
            height: 480,
        };
        assert_eq!(config.width, 640, "width");
        assert_eq!(config.height, 480, "height");
        assert_eq!(config.target_bitrate_bps, 500_000, "bitrate");
    }
}
