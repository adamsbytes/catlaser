//! WebRTC live streaming via `LiveKit` and str0m.
//!
//! Provides the [`StreamHandle`] for managing the lifecycle of a video
//! stream from the vision pipeline to app viewers via a `LiveKit` SFU.
//!
//! Architecture:
//! - The main pipeline thread encodes H.264 frames via the RKMPI VENC
//!   hardware encoder and sends them to the streaming thread via a
//!   crossbeam channel.
//! - The streaming thread runs str0m's synchronous WebRTC stack, connected
//!   to a `LiveKit` room via WebSocket signaling. It reads encoded frames
//!   from the channel and writes them to the WebRTC media track.
//! - The streaming thread observes WebRTC keyframe requests (PLI/FIR from
//!   subscribers) and posts them on a control channel back to the main
//!   thread; the next encode forces an IDR via [`crate::encoder::Encoder::request_idr`].
//! - Python controls the lifecycle: it tells Rust when to start/stop
//!   publishing via IPC `StreamControl` messages, which include the
//!   `LiveKit` URL and publisher token.
//!
//! No Tokio runtime is used. str0m's Sans-IO design and tungstenite's
//! synchronous WebSocket client keep the dependency footprint minimal for
//! the constrained RV1106 (256MB RAM, single Cortex-A7 core).

pub(crate) mod error;
pub(crate) mod publisher;
pub(crate) mod signaling;

use std::thread::{self, JoinHandle};

use crossbeam_channel::{Receiver, Sender};

pub(crate) use error::StreamError;
pub(crate) use publisher::{PublisherState, StreamConfig};

use crate::encoder::EncodedFrame;

// ---------------------------------------------------------------------------
// Stream handle
// ---------------------------------------------------------------------------

/// Handle for managing the streaming publisher thread.
///
/// Created by [`StreamHandle::start`], which spawns a dedicated thread for
/// the WebRTC publisher. The handle owns the frame sender channel —
/// dropping it (via [`stop`](Self::stop)) signals the publisher to exit.
#[derive(Debug)]
pub(crate) struct StreamHandle {
    /// Sender for encoded frames. The publisher reads from the other end.
    /// `Option` so [`stop`](Self::stop) can drop it to signal the publisher thread.
    frame_tx: Option<Sender<EncodedFrame>>,
    /// Receiver for publisher state changes posted by the streaming thread.
    state_rx: Receiver<PublisherState>,
    /// Receiver for keyframe-request notifications posted by the streaming
    /// thread on every WebRTC PLI/FIR. The pipeline drains this each frame
    /// and forces an IDR on the next encode.
    keyframe_rx: Receiver<()>,
    /// Join handle for the publisher thread.
    thread: Option<JoinHandle<Result<(), StreamError>>>,
    /// Most recent state observed via [`poll_state_change`](Self::poll_state_change).
    last_state: PublisherState,
}

impl StreamHandle {
    /// Starts the streaming publisher on a dedicated thread.
    ///
    /// Returns a handle that can send encoded frames and observe state
    /// transitions. The publisher connects to `LiveKit` and begins streaming.
    pub(crate) fn start(config: StreamConfig) -> Self {
        // Frame channel buffer. At 15 FPS with 2 slots, the publisher is
        // never more than ~133 ms behind before the main thread drops a
        // frame in `send_frame` — bounded latency over completeness.
        let (frame_tx, frame_rx) = crossbeam_channel::bounded(2);
        // State channel buffer. State transitions are sparse (Connecting →
        // Publishing → Idle/Error), so 8 is comfortably oversized.
        let (state_tx, state_rx) = crossbeam_channel::bounded(8);
        // Keyframe-request channel. Capacity 1 — the publisher only needs
        // to register that AT LEAST ONE PLI is pending; coalescing many
        // PLIs into one IDR is correct (a single IDR resyncs everyone).
        let (keyframe_tx, keyframe_rx) = crossbeam_channel::bounded(1);

        let thread = thread::Builder::new()
            .name(String::from("catlaser-stream"))
            .spawn(move || publisher::run_publisher(&config, &frame_rx, &state_tx, &keyframe_tx))
            .ok();

        Self {
            frame_tx: Some(frame_tx),
            state_rx,
            keyframe_rx,
            thread,
            last_state: PublisherState::Connecting,
        }
    }

    /// Sends an encoded frame to the publisher.
    ///
    /// Non-blocking: if the channel is full (publisher is slow), the frame
    /// is dropped. At 15 FPS with a 2-frame buffer, this means the publisher
    /// is at least 2 frames behind — dropping is the correct behavior to
    /// maintain low latency.
    pub(crate) fn send_frame(&self, frame: EncodedFrame) {
        if let Some(tx) = &self.frame_tx {
            // Use try_send to avoid blocking the pipeline thread.
            drop(tx.try_send(frame));
        }
    }

    /// Returns the latest publisher state observed since the previous call,
    /// or `None` if no state transition has happened.
    ///
    /// Drains every queued state on each call; the most recent value
    /// becomes the new "last reported" state and is returned. Callers
    /// forward each observed change to Python over IPC.
    pub(crate) fn poll_state_change(&mut self) -> Option<PublisherState> {
        let mut latest: Option<PublisherState> = None;
        while let Ok(state) = self.state_rx.try_recv() {
            latest = Some(state);
        }
        let observed = latest?;
        if observed == self.last_state {
            return None;
        }
        self.last_state = observed;
        Some(observed)
    }

    /// Drains and reports whether the publisher requested at least one
    /// keyframe since the last call.
    ///
    /// Returning `true` means the next encode must produce an IDR. Multiple
    /// pending PLIs collapse into a single IDR — the receiver only needs
    /// the next refresh point, not one IDR per request.
    pub(crate) fn take_keyframe_request(&self) -> bool {
        let mut pending = false;
        while self.keyframe_rx.try_recv().is_ok() {
            pending = true;
        }
        pending
    }

    /// Stops the publisher by dropping the frame channel and joining the thread.
    pub(crate) fn stop(mut self) {
        // Drop the sender to signal the publisher to exit.
        self.frame_tx = None;
        if let Some(handle) = self.thread.take() {
            drop(handle.join());
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn unreachable_config() -> StreamConfig {
        StreamConfig {
            livekit_url: String::from("wss://unreachable.invalid"),
            publisher_token: String::from("fake"),
            room_name: String::from("test"),
            target_bitrate_bps: 500_000,
            width: 640,
            height: 480,
        }
    }

    #[test]
    fn test_stream_handle_state_initial() {
        // Start spawns a thread that will fail to connect, but the
        // handle construction itself must not panic.
        let handle = StreamHandle::start(unreachable_config());
        assert_eq!(
            handle.last_state,
            PublisherState::Connecting,
            "initial state must be Connecting before any drain"
        );
        handle.stop();
    }

    #[test]
    fn test_take_keyframe_request_starts_empty() {
        let handle = StreamHandle::start(unreachable_config());
        assert!(
            !handle.take_keyframe_request(),
            "fresh handle must report no pending keyframe request"
        );
        handle.stop();
    }
}
