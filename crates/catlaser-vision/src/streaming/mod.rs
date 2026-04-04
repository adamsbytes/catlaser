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
/// dropping it signals the publisher to stop.
#[derive(Debug)]
pub(crate) struct StreamHandle {
    /// Sender for encoded frames. The publisher reads from the other end.
    /// `Option` so `stop()` can drop it to signal the publisher thread.
    frame_tx: Option<Sender<EncodedFrame>>,
    /// Receiver for publisher state changes.
    state_rx: Receiver<PublisherState>,
    /// Join handle for the publisher thread.
    thread: Option<JoinHandle<Result<(), StreamError>>>,
    /// Last known publisher state.
    last_state: PublisherState,
}

impl StreamHandle {
    /// Starts the streaming publisher on a dedicated thread.
    ///
    /// Returns a handle that can send encoded frames and monitor state.
    /// The publisher connects to `LiveKit` and begins streaming.
    pub(crate) fn start(config: StreamConfig) -> Self {
        let (frame_tx, frame_rx) = crossbeam_channel::bounded(2);
        let (state_tx, state_rx) = crossbeam_channel::bounded(8);

        let thread = thread::Builder::new()
            .name(String::from("catlaser-stream"))
            .spawn(move || publisher::run_publisher(&config, &frame_rx, &state_tx))
            .ok();

        Self {
            frame_tx: Some(frame_tx),
            state_rx,
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

    /// Returns the current publisher state, polling for updates.
    pub(crate) fn state(&mut self) -> PublisherState {
        // Drain all pending state updates, keep the latest.
        while let Ok(state) = self.state_rx.try_recv() {
            self.last_state = state;
        }
        self.last_state
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

    #[test]
    fn test_stream_handle_state_initial() {
        let config = StreamConfig {
            livekit_url: String::from("wss://unreachable.invalid"),
            publisher_token: String::from("fake"),
            room_name: String::from("test"),
            target_bitrate_bps: 500_000,
            width: 640,
            height: 480,
        };
        // Start will spawn a thread that will fail to connect, but the
        // handle construction itself should not panic.
        let handle = StreamHandle::start(config);
        // Initial state is Connecting.
        assert_eq!(
            handle.last_state,
            PublisherState::Connecting,
            "initial state"
        );
        handle.stop();
    }
}
