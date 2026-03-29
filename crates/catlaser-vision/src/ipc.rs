//! Unix domain socket IPC between the Rust vision daemon and the Python
//! behavior engine.
//!
//! Wire format: `[1 byte: msg type][4 bytes: length (LE u32)][N bytes: protobuf]`
//!
//! The Rust side is the server — it binds a Unix socket and accepts a single
//! client connection from the Python sidecar. The server uses non-blocking
//! accepts and reads so the vision pipeline loop never stalls waiting for
//! Python. Writes are blocking — messages are small and the kernel socket
//! buffer absorbs them at our throughput (~15 frames/sec, ~500 bytes each).
//!
//! # Message types
//!
//! | Direction       | Message            | Frequency    |
//! |-----------------|--------------------|-------------|
//! | Rust → Python   | `DetectionFrame`   | ~15/sec      |
//! | Rust → Python   | `TrackEvent`       | sporadic     |
//! | Rust → Python   | `SessionRequest`   | sporadic     |
//! | Python → Rust   | `BehaviorCommand`  | 1-5/sec      |
//! | Python → Rust   | `SessionAck`       | sporadic     |
//! | Python → Rust   | `IdentityResult`   | sporadic     |

use std::io::{self, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

use buffa::{DecodeOptions, Message};

use crate::proto::detection::{
    BehaviorCommand, DetectionFrame, IdentityResult, SessionAck, SessionRequest, TrackEvent,
};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Default Unix socket path on the target filesystem.
pub(crate) const DEFAULT_SOCKET_PATH: &str = "/run/catlaser/vision.sock";

/// Wire frame header size: 1 byte type + 4 bytes length.
const HEADER_SIZE: usize = 5_usize;

/// Maximum protobuf payload size in bytes (64 KiB).
///
/// A `DetectionFrame` with 15 cats is ~500 bytes. 64 KiB is generous headroom
/// for future message growth without allowing unbounded allocation from a
/// misbehaving client.
const MAX_MESSAGE_SIZE: u32 = 65_536_u32;

/// [`MAX_MESSAGE_SIZE`] as `usize` for buffer sizing and decode options.
#[expect(
    clippy::as_conversions,
    reason = "u32 → usize widening is lossless on all supported targets (32-bit ARM, 64-bit); \
              From::from is not available in const context"
)]
const MAX_MESSAGE_USIZE: usize = MAX_MESSAGE_SIZE as usize;

/// Decode options applied to all inbound protobuf messages.
///
/// Restricts recursion depth and message size to prevent OOM from malformed
/// payloads on the Unix socket.
fn decode_options() -> DecodeOptions {
    DecodeOptions::new()
        .with_recursion_limit(20_u32)
        .with_max_message_size(MAX_MESSAGE_USIZE)
}

// ---------------------------------------------------------------------------
// Wire type
// ---------------------------------------------------------------------------

/// Message type byte in the wire frame header.
///
/// Values match the `MsgType` enum in `detection.proto`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum WireType {
    /// `DetectionFrame` — Rust → Python, steady ~15/sec.
    DetectionFrame = 1,
    /// `TrackEvent` — Rust → Python, sporadic.
    TrackEvent = 2,
    /// `SessionRequest` — Rust → Python, sporadic.
    SessionRequest = 3,
    /// `BehaviorCommand` — Python → Rust, 1-5/sec.
    BehaviorCommand = 4,
    /// `SessionAck` — Python → Rust, sporadic.
    SessionAck = 5,
    /// `IdentityResult` — Python → Rust, sporadic.
    IdentityResult = 6,
}

impl WireType {
    /// Converts to the on-wire byte value.
    #[expect(
        clippy::as_conversions,
        reason = "repr(u8) enum to u8 is a no-op cast — values are 1-6, always valid"
    )]
    pub(crate) const fn to_byte(self) -> u8 {
        self as u8
    }

    /// Parses a wire byte into a `WireType`.
    pub(crate) const fn from_byte(byte: u8) -> Result<Self, IpcError> {
        match byte {
            1 => Ok(Self::DetectionFrame),
            2 => Ok(Self::TrackEvent),
            3 => Ok(Self::SessionRequest),
            4 => Ok(Self::BehaviorCommand),
            5 => Ok(Self::SessionAck),
            6 => Ok(Self::IdentityResult),
            _ => Err(IpcError::InvalidWireType(byte)),
        }
    }
}

// ---------------------------------------------------------------------------
// Error
// ---------------------------------------------------------------------------

/// Errors from IPC operations.
#[derive(Debug, thiserror::Error)]
pub(crate) enum IpcError {
    /// Failed to remove a stale socket file before binding.
    #[error("failed to remove stale socket at {path}: {source}")]
    RemoveStale {
        /// Socket path that was attempted.
        path: String,
        /// Underlying OS error.
        source: io::Error,
    },

    /// Failed to bind the Unix listener socket.
    #[error("failed to bind Unix socket at {path}: {source}")]
    Bind {
        /// Socket path that was attempted.
        path: String,
        /// Underlying OS error.
        source: io::Error,
    },

    /// Failed to set non-blocking mode on the listener.
    #[error("failed to set non-blocking on listener: {source}")]
    SetNonBlocking {
        /// Underlying OS error.
        source: io::Error,
    },

    /// Failed to accept a client connection.
    #[error("failed to accept connection: {source}")]
    Accept {
        /// Underlying OS error.
        source: io::Error,
    },

    /// Failed to write a message to the peer.
    #[error("send failed: {source}")]
    Send {
        /// Underlying OS error.
        source: io::Error,
    },

    /// Failed to read from the peer.
    #[error("recv failed: {source}")]
    Recv {
        /// Underlying OS error.
        source: io::Error,
    },

    /// The type byte in a frame header is not a known `WireType`.
    #[error("invalid wire type byte: {0}")]
    InvalidWireType(u8),

    /// The payload length in a frame header exceeds [`MAX_MESSAGE_SIZE`].
    #[error("message too large: {size} bytes (max {MAX_MESSAGE_SIZE})")]
    MessageTooLarge {
        /// Declared payload size.
        size: u32,
    },

    /// The wire type received does not match any expected inbound message.
    #[error("unexpected wire type {wire_type:?} from peer")]
    UnexpectedWireType {
        /// The wire type that was received.
        wire_type: WireType,
    },

    /// Protobuf decode failed on a received payload.
    #[error("protobuf decode: {source}")]
    Decode {
        /// Underlying decode error.
        source: buffa::DecodeError,
    },

    /// The peer closed the connection.
    #[error("connection closed by peer")]
    PeerClosed,
}

// ---------------------------------------------------------------------------
// Wire format: encode
// ---------------------------------------------------------------------------

/// Encodes a framed message into `buf`: `[type][length LE u32][payload]`.
///
/// Returns an error if the payload exceeds [`MAX_MESSAGE_SIZE`].
pub(crate) fn encode_frame(
    wire_type: WireType,
    payload: &[u8],
    buf: &mut Vec<u8>,
) -> Result<(), IpcError> {
    let Some(len) = u32::try_from(payload.len())
        .ok()
        .filter(|&n| n <= MAX_MESSAGE_SIZE)
    else {
        let size = u32::try_from(payload.len()).unwrap_or(u32::MAX);
        return Err(IpcError::MessageTooLarge { size });
    };

    buf.reserve(HEADER_SIZE.saturating_add(payload.len()));
    buf.push(wire_type.to_byte());
    buf.extend_from_slice(&len.to_le_bytes());
    buf.extend_from_slice(payload);
    Ok(())
}

// ---------------------------------------------------------------------------
// Wire format: decode
// ---------------------------------------------------------------------------

/// Decoded frame header: wire type and payload length.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct FrameHeader {
    /// Message type.
    pub wire_type: WireType,
    /// Payload length in bytes.
    pub length: u32,
}

/// Parses a 5-byte frame header.
///
/// Returns an error if the type byte is invalid or the length exceeds
/// [`MAX_MESSAGE_SIZE`].
pub(crate) fn decode_header(header: [u8; HEADER_SIZE]) -> Result<FrameHeader, IpcError> {
    let wire_type = WireType::from_byte(header[0_usize])?;
    let length = u32::from_le_bytes([
        header[1_usize],
        header[2_usize],
        header[3_usize],
        header[4_usize],
    ]);
    if length > MAX_MESSAGE_SIZE {
        return Err(IpcError::MessageTooLarge { size: length });
    }
    Ok(FrameHeader { wire_type, length })
}

// ---------------------------------------------------------------------------
// Incoming message
// ---------------------------------------------------------------------------

/// A decoded message received from the Python behavior engine.
#[derive(Debug)]
pub(crate) enum IncomingMessage {
    /// Per-frame behavior command from the state machine.
    BehaviorCommand(BehaviorCommand),
    /// Response to a `SessionRequest`.
    SessionAck(SessionAck),
    /// Response to an `IdentityRequest`.
    IdentityResult(IdentityResult),
}

/// Decodes a payload into an [`IncomingMessage`] based on the wire type.
fn decode_incoming(wire_type: WireType, payload: &[u8]) -> Result<IncomingMessage, IpcError> {
    let opts = decode_options();
    match wire_type {
        WireType::BehaviorCommand => {
            let msg = opts
                .decode_from_slice::<BehaviorCommand>(payload)
                .map_err(|source| IpcError::Decode { source })?;
            Ok(IncomingMessage::BehaviorCommand(msg))
        }
        WireType::SessionAck => {
            let msg = opts
                .decode_from_slice::<SessionAck>(payload)
                .map_err(|source| IpcError::Decode { source })?;
            Ok(IncomingMessage::SessionAck(msg))
        }
        WireType::IdentityResult => {
            let msg = opts
                .decode_from_slice::<IdentityResult>(payload)
                .map_err(|source| IpcError::Decode { source })?;
            Ok(IncomingMessage::IdentityResult(msg))
        }
        // DetectionFrame, TrackEvent, SessionRequest are outbound-only.
        wire_type
        @ (WireType::DetectionFrame | WireType::TrackEvent | WireType::SessionRequest) => {
            Err(IpcError::UnexpectedWireType { wire_type })
        }
    }
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

/// Unix domain socket server for the vision daemon.
///
/// Binds to a socket path and accepts a single client connection (the Python
/// behavior engine). The listener uses non-blocking mode so [`try_accept`]
/// returns immediately when no client is waiting.
///
/// Drop cleans up the socket file.
#[derive(Debug)]
pub(crate) struct IpcServer {
    listener: UnixListener,
    path: PathBuf,
}

impl IpcServer {
    /// Binds a Unix listener socket at `path`.
    ///
    /// Removes a stale socket file if one exists from a previous unclean
    /// shutdown. Creates parent directories if needed.
    pub(crate) fn bind(path: &Path) -> Result<Self, IpcError> {
        let path_str = path.display().to_string();

        // Remove stale socket from a previous run. Only ENOENT is acceptable
        // (file didn't exist). Any other error is a real failure.
        if let Err(err) = std::fs::remove_file(path)
            && err.kind() != io::ErrorKind::NotFound
        {
            return Err(IpcError::RemoveStale {
                path: path_str,
                source: err,
            });
        }

        // Ensure parent directory exists.
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|source| IpcError::Bind {
                path: path_str.clone(),
                source,
            })?;
        }

        let listener = UnixListener::bind(path).map_err(|source| IpcError::Bind {
            path: path_str,
            source,
        })?;

        listener
            .set_nonblocking(true)
            .map_err(|source| IpcError::SetNonBlocking { source })?;

        Ok(Self {
            listener,
            path: path.to_path_buf(),
        })
    }

    /// Returns the socket path this server is bound to.
    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    /// Attempts to accept a pending client connection.
    ///
    /// Returns `Ok(Some(connection))` if a client was waiting, `Ok(None)` if
    /// no client is pending (non-blocking), or `Err` on a real I/O failure.
    pub(crate) fn try_accept(&self) -> Result<Option<IpcConnection>, IpcError> {
        match self.listener.accept() {
            Ok((stream, _addr)) => {
                // Client reads are non-blocking (polled each frame).
                // Writes remain blocking — messages are small.
                stream
                    .set_nonblocking(true)
                    .map_err(|source| IpcError::SetNonBlocking { source })?;
                tracing::info!("IPC client connected");
                Ok(Some(IpcConnection {
                    stream,
                    read_buf: Vec::new(),
                    write_buf: Vec::new(),
                }))
            }
            Err(err) if err.kind() == io::ErrorKind::WouldBlock => Ok(None),
            Err(source) => Err(IpcError::Accept { source }),
        }
    }
}

impl Drop for IpcServer {
    fn drop(&mut self) {
        drop(std::fs::remove_file(&self.path));
    }
}

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

/// An accepted IPC connection to the Python behavior engine.
///
/// Wraps a `UnixStream` with framed message send/receive. Maintains an
/// internal read buffer for partial message reassembly — Unix sockets are
/// stream-oriented, so a single `read()` call may return a partial frame
/// or multiple frames.
#[derive(Debug)]
pub(crate) struct IpcConnection {
    stream: UnixStream,
    /// Accumulates bytes from `read()` calls until a complete frame is
    /// available.
    read_buf: Vec<u8>,
    /// Scratch buffer for encoding outbound frames. Reused across sends
    /// to avoid per-message allocation.
    write_buf: Vec<u8>,
}

impl IpcConnection {
    /// Sends a `DetectionFrame` to the Python behavior engine.
    pub(crate) fn send_detection_frame(&mut self, msg: &DetectionFrame) -> Result<(), IpcError> {
        self.send_message(WireType::DetectionFrame, msg)
    }

    /// Sends a `TrackEvent` to the Python behavior engine.
    pub(crate) fn send_track_event(&mut self, msg: &TrackEvent) -> Result<(), IpcError> {
        self.send_message(WireType::TrackEvent, msg)
    }

    /// Sends a `SessionRequest` to the Python behavior engine.
    pub(crate) fn send_session_request(&mut self, msg: &SessionRequest) -> Result<(), IpcError> {
        self.send_message(WireType::SessionRequest, msg)
    }

    /// Attempts a non-blocking read for an incoming message.
    ///
    /// Returns `Ok(Some(msg))` if a complete message was received,
    /// `Ok(None)` if no data is available yet, or `Err` on I/O failure
    /// or protocol violation.
    pub(crate) fn try_recv(&mut self) -> Result<Option<IncomingMessage>, IpcError> {
        // Read whatever is available into the read buffer.
        self.drain_socket()?;

        // Try to parse a complete frame from the accumulated bytes.
        self.try_parse_frame()
    }

    // -----------------------------------------------------------------------
    // Internal: send
    // -----------------------------------------------------------------------

    /// Encodes a protobuf message with framing and writes it to the socket.
    fn send_message<M: Message>(&mut self, wire_type: WireType, msg: &M) -> Result<(), IpcError> {
        self.write_buf.clear();
        let payload = msg.encode_to_vec();
        encode_frame(wire_type, &payload, &mut self.write_buf)?;
        self.stream
            .write_all(&self.write_buf)
            .map_err(|source| IpcError::Send { source })
    }

    // -----------------------------------------------------------------------
    // Internal: receive
    // -----------------------------------------------------------------------

    /// Reads all immediately available bytes from the socket into `read_buf`.
    ///
    /// Non-blocking: returns immediately when no data is available.
    /// Detects peer disconnection (read returns 0 bytes).
    fn drain_socket(&mut self) -> Result<(), IpcError> {
        let mut tmp = [0_u8; 4096_usize];
        loop {
            match self.stream.read(&mut tmp) {
                Ok(0_usize) => return Err(IpcError::PeerClosed),
                Ok(n) => {
                    self.read_buf.extend_from_slice(tmp.get(..n).ok_or_else(|| {
                        IpcError::Recv {
                            source: io::Error::new(
                                io::ErrorKind::InvalidData,
                                "read returned count larger than buffer",
                            ),
                        }
                    })?);
                }
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => return Ok(()),
                Err(source) => return Err(IpcError::Recv { source }),
            }
        }
    }

    /// Tries to extract one complete frame from `read_buf`.
    ///
    /// If a complete header + payload is present, decodes and returns the
    /// message. If the buffer contains a partial frame, returns `None`
    /// without consuming any bytes — the next `drain_socket` call will
    /// append more data.
    fn try_parse_frame(&mut self) -> Result<Option<IncomingMessage>, IpcError> {
        if self.read_buf.len() < HEADER_SIZE {
            return Ok(None);
        }

        // Parse header without consuming — we may not have the full payload yet.
        let header_arr: [u8; HEADER_SIZE] = self
            .read_buf
            .get(..HEADER_SIZE)
            .and_then(|s| <[u8; HEADER_SIZE]>::try_from(s).ok())
            .ok_or_else(|| IpcError::Recv {
                source: io::Error::new(io::ErrorKind::InvalidData, "header slice too short"),
            })?;

        let header = decode_header(header_arr)?;
        let payload_len =
            usize::try_from(header.length).map_err(|_err| IpcError::MessageTooLarge {
                size: header.length,
            })?;
        let frame_len = HEADER_SIZE.saturating_add(payload_len);

        if self.read_buf.len() < frame_len {
            // Partial frame — wait for more data.
            return Ok(None);
        }

        // Full frame available. Extract payload and consume.
        let payload_start = HEADER_SIZE;
        let payload_end = frame_len;
        let payload = self
            .read_buf
            .get(payload_start..payload_end)
            .ok_or_else(|| IpcError::Recv {
                source: io::Error::new(io::ErrorKind::InvalidData, "payload slice out of bounds"),
            })?;

        let msg = decode_incoming(header.wire_type, payload)?;

        // Remove the consumed frame from the front of the buffer.
        // Use drain to shift remaining bytes to the front efficiently.
        self.read_buf.drain(..frame_len);

        Ok(Some(msg))
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
#[expect(
    clippy::indexing_slicing,
    clippy::expect_used,
    clippy::unwrap_used,
    clippy::as_conversions,
    clippy::arithmetic_side_effects,
    clippy::panic,
    clippy::float_cmp,
    reason = "test code: expect/unwrap for test assertions, indexing on known-size test data, \
              as-conversions on small known values, panic in test failure paths, \
              float_cmp for protobuf round-trip (IEEE 754 preserved bit-exact)"
)]
mod tests {
    use super::*;
    use crate::proto::detection::{
        self, BehaviorCommand, DetectionFrame, IdentityResult, SessionAck, TrackedCat,
    };
    use proptest::prelude::*;
    use std::io::Write;
    use std::os::unix::net::UnixStream as StdUnixStream;

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// Creates a server in a temp directory and returns `(server, socket_path)`.
    fn test_server() -> (IpcServer, tempfile::TempDir) {
        let dir = tempfile::tempdir().expect("tempdir creation must succeed in tests");
        let path = dir.path().join("test.sock");
        let server = IpcServer::bind(&path).expect("bind must succeed in tests");
        (server, dir)
    }

    /// Connects a raw `UnixStream` to the server's socket.
    fn raw_client(server: &IpcServer) -> StdUnixStream {
        StdUnixStream::connect(server.path()).expect("connect must succeed in tests")
    }

    /// Accepts a connection from the server, retrying briefly for the
    /// non-blocking accept to pick up the client.
    fn accept_connection(server: &IpcServer) -> IpcConnection {
        // The non-blocking accept may need a moment for the kernel to
        // enqueue the connection.
        for _ in 0..100_u32 {
            if let Some(conn) = server
                .try_accept()
                .expect("try_accept must not fail in tests")
            {
                return conn;
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        panic!("server did not accept connection within timeout");
    }

    // -----------------------------------------------------------------------
    // WireType round-trip
    // -----------------------------------------------------------------------

    #[test]
    fn test_wire_type_round_trip_all_variants() {
        let variants = [
            WireType::DetectionFrame,
            WireType::TrackEvent,
            WireType::SessionRequest,
            WireType::BehaviorCommand,
            WireType::SessionAck,
            WireType::IdentityResult,
        ];
        for wt in variants {
            let byte = wt.to_byte();
            let recovered =
                WireType::from_byte(byte).expect("from_byte must succeed for valid variant");
            assert_eq!(wt, recovered, "WireType round-trip failed for {wt:?}");
        }
    }

    #[test]
    fn test_wire_type_from_byte_invalid() {
        assert!(
            WireType::from_byte(0).is_err(),
            "0 (UNSPECIFIED) must be rejected"
        );
        assert!(WireType::from_byte(7).is_err(), "7 must be rejected");
        assert!(WireType::from_byte(255).is_err(), "255 must be rejected");
    }

    // -----------------------------------------------------------------------
    // Frame encode / decode
    // -----------------------------------------------------------------------

    #[test]
    fn test_frame_encode_decode_round_trip() {
        let payload = b"hello protobuf";
        let mut buf = Vec::new();
        encode_frame(WireType::DetectionFrame, payload, &mut buf).expect("encode must succeed");

        // Header is 5 bytes + payload.
        assert_eq!(
            buf.len(),
            HEADER_SIZE
                .checked_add(payload.len())
                .expect("no overflow in test"),
            "frame length must be header + payload"
        );

        let header_arr: [u8; HEADER_SIZE] = buf
            .get(..HEADER_SIZE)
            .and_then(|s| <[u8; HEADER_SIZE]>::try_from(s).ok())
            .expect("header slice must be 5 bytes");
        let header = decode_header(header_arr).expect("decode_header must succeed");

        assert_eq!(
            header.wire_type,
            WireType::DetectionFrame,
            "wire type mismatch"
        );
        let expected_len = u32::try_from(payload.len()).expect("payload len fits u32");
        assert_eq!(header.length, expected_len, "payload length mismatch");

        let decoded_payload = buf
            .get(HEADER_SIZE..)
            .expect("payload must exist after header");
        assert_eq!(decoded_payload, payload, "payload content mismatch");
    }

    #[test]
    fn test_frame_encode_empty_payload() {
        let mut buf = Vec::new();
        encode_frame(WireType::SessionAck, &[], &mut buf)
            .expect("encoding empty payload must succeed");
        assert_eq!(
            buf.len(),
            HEADER_SIZE,
            "empty payload frame must be header-only"
        );

        let header_arr: [u8; HEADER_SIZE] = buf
            .get(..HEADER_SIZE)
            .and_then(|s| <[u8; HEADER_SIZE]>::try_from(s).ok())
            .expect("header slice must be 5 bytes");
        let header = decode_header(header_arr).expect("decode must succeed");
        assert_eq!(header.length, 0_u32, "empty payload length must be 0");
    }

    #[test]
    fn test_frame_encode_oversized_payload_rejected() {
        let payload = vec![0_u8; MAX_MESSAGE_SIZE.saturating_add(1_u32) as usize];
        let mut buf = Vec::new();
        let result = encode_frame(WireType::DetectionFrame, &payload, &mut buf);
        assert!(result.is_err(), "oversized payload must be rejected");
    }

    #[test]
    fn test_decode_header_oversized_length_rejected() {
        let mut header = [0_u8; HEADER_SIZE];
        header[0_usize] = WireType::DetectionFrame.to_byte();
        let too_big = MAX_MESSAGE_SIZE.saturating_add(1_u32);
        let len_bytes = too_big.to_le_bytes();
        header[1_usize] = len_bytes[0_usize];
        header[2_usize] = len_bytes[1_usize];
        header[3_usize] = len_bytes[2_usize];
        header[4_usize] = len_bytes[3_usize];

        let result = decode_header(header);
        assert!(result.is_err(), "oversized length must be rejected");
    }

    // -----------------------------------------------------------------------
    // Proptest: frame round-trip with arbitrary payloads
    // -----------------------------------------------------------------------

    fn wire_type_strategy() -> impl Strategy<Value = WireType> {
        prop_oneof![
            Just(WireType::DetectionFrame),
            Just(WireType::TrackEvent),
            Just(WireType::SessionRequest),
            Just(WireType::BehaviorCommand),
            Just(WireType::SessionAck),
            Just(WireType::IdentityResult),
        ]
    }

    proptest! {
        #[test]
        fn test_frame_round_trip_arbitrary(
            wire_type in wire_type_strategy(),
            payload in proptest::collection::vec(any::<u8>(), 0..1024_usize),
        ) {
            let mut buf = Vec::new();
            encode_frame(wire_type, &payload, &mut buf)
                .expect("encode must succeed for payloads under MAX_MESSAGE_SIZE");

            let header_arr: [u8; HEADER_SIZE] = buf
                .get(..HEADER_SIZE)
                .and_then(|s| <[u8; HEADER_SIZE]>::try_from(s).ok())
                .expect("header must be extractable");
            let header = decode_header(header_arr)
                .expect("decode_header must succeed for valid frame");

            prop_assert_eq!(header.wire_type, wire_type);
            let expected_len = u32::try_from(payload.len()).expect("len fits u32");
            prop_assert_eq!(header.length, expected_len);

            let decoded_payload = buf.get(HEADER_SIZE..).expect("payload exists");
            prop_assert_eq!(decoded_payload, &*payload);
        }
    }

    // -----------------------------------------------------------------------
    // Insta snapshots: wire bytes for known messages
    // -----------------------------------------------------------------------

    #[test]
    fn test_snapshot_detection_frame_wire_bytes() {
        let frame = DetectionFrame {
            timestamp_us: 1_000_000_u64,
            frame_number: 42_u64,
            cats: vec![TrackedCat {
                track_id: 1_u32,
                cat_id: String::from("whiskers"),
                center_x: 0.5_f32,
                center_y: 0.6_f32,
                width: 0.2_f32,
                height: 0.3_f32,
                velocity_x: 0.01_f32,
                velocity_y: -0.02_f32,
                state: detection::TrackState::TRACK_STATE_CONFIRMED.into(),
                ..Default::default()
            }],
            safety_ceiling_y: 0.75_f32,
            person_in_frame: true,
            ambient_brightness: 0.8_f32,
            ..Default::default()
        };

        let payload = frame.encode_to_vec();
        let mut wire = Vec::new();
        encode_frame(WireType::DetectionFrame, &payload, &mut wire).expect("encode must succeed");

        insta::assert_yaml_snapshot!("detection_frame_wire", wire);
    }

    #[test]
    fn test_snapshot_behavior_command_wire_bytes() {
        let cmd = BehaviorCommand {
            mode: detection::TargetingMode::TARGETING_MODE_TRACK.into(),
            offset_x: 0.1_f32,
            offset_y: -0.05_f32,
            smoothing: 0.7_f32,
            max_speed: 0.5_f32,
            laser_on: true,
            target_track_id: 3_u32,
            ..Default::default()
        };

        let payload = cmd.encode_to_vec();
        let mut wire = Vec::new();
        encode_frame(WireType::BehaviorCommand, &payload, &mut wire).expect("encode must succeed");

        insta::assert_yaml_snapshot!("behavior_command_wire", wire);
    }

    // -----------------------------------------------------------------------
    // Server: bind + accept
    // -----------------------------------------------------------------------

    #[test]
    fn test_server_bind_and_accept() {
        let (server, _dir) = test_server();

        // No client yet — accept returns None.
        let result = server.try_accept().expect("try_accept must not fail");
        assert!(
            result.is_none(),
            "accept must return None when no client is pending"
        );

        // Connect a client.
        let _client = raw_client(&server);
        let conn = accept_connection(&server);

        // Connection is live.
        drop(conn);
    }

    #[test]
    fn test_server_cleans_up_stale_socket() {
        let dir = tempfile::tempdir().expect("tempdir must succeed");
        let path = dir.path().join("stale.sock");

        // Create a stale socket file.
        std::fs::write(&path, b"stale").expect("write must succeed");

        // Binding should succeed by removing the stale file.
        let server = IpcServer::bind(&path).expect("bind must succeed over stale socket");
        drop(server);

        // Socket file should be cleaned up on drop.
        assert!(!path.exists(), "socket file must be removed on server drop");
    }

    // -----------------------------------------------------------------------
    // Connection: send + receive protobuf messages
    // -----------------------------------------------------------------------

    #[test]
    fn test_send_detection_frame_and_receive_raw() {
        let (server, _dir) = test_server();
        let mut client = raw_client(&server);
        let mut conn = accept_connection(&server);

        let frame = DetectionFrame {
            timestamp_us: 500_000_u64,
            frame_number: 7_u64,
            safety_ceiling_y: -1.0_f32,
            ..Default::default()
        };

        conn.send_detection_frame(&frame)
            .expect("send must succeed");

        // Read raw bytes from the client side.
        client
            .set_nonblocking(false)
            .expect("set_nonblocking must succeed");

        let mut header_buf = [0_u8; HEADER_SIZE];
        client
            .read_exact(&mut header_buf)
            .expect("read header must succeed");

        let header = decode_header(header_buf).expect("header must decode");
        assert_eq!(
            header.wire_type,
            WireType::DetectionFrame,
            "wrong wire type"
        );

        let mut payload_buf = vec![0_u8; header.length as usize];
        client
            .read_exact(&mut payload_buf)
            .expect("read payload must succeed");

        let decoded = decode_options()
            .decode_from_slice::<DetectionFrame>(&payload_buf)
            .expect("protobuf decode must succeed");
        assert_eq!(decoded.timestamp_us, 500_000_u64, "timestamp mismatch");
        assert_eq!(decoded.frame_number, 7_u64, "frame number mismatch");
    }

    #[test]
    fn test_receive_behavior_command_from_client() {
        let (server, _dir) = test_server();
        let mut client = raw_client(&server);
        let mut conn = accept_connection(&server);

        let cmd = BehaviorCommand {
            mode: detection::TargetingMode::TARGETING_MODE_TRACK.into(),
            laser_on: true,
            target_track_id: 5_u32,
            smoothing: 0.6_f32,
            ..Default::default()
        };

        // Client sends a framed message.
        let payload = cmd.encode_to_vec();
        let mut frame_buf = Vec::new();
        encode_frame(WireType::BehaviorCommand, &payload, &mut frame_buf)
            .expect("encode must succeed");
        client
            .write_all(&frame_buf)
            .expect("client write must succeed");

        // Give the kernel a moment to deliver.
        std::thread::sleep(std::time::Duration::from_millis(10));

        let msg = conn.try_recv().expect("recv must not fail");
        let msg = msg.expect("a complete message must be available");

        match msg {
            IncomingMessage::BehaviorCommand(received) => {
                assert_eq!(received.target_track_id, 5_u32, "track_id mismatch");
                assert!(received.laser_on, "laser must be on");
            }
            other => panic!("expected BehaviorCommand, got {other:?}"),
        }
    }

    #[test]
    fn test_receive_session_ack_from_client() {
        let (server, _dir) = test_server();
        let mut client = raw_client(&server);
        let mut conn = accept_connection(&server);

        let ack = SessionAck {
            accept: false,
            skip_reason: detection::SkipReason::SKIP_REASON_HOPPER_EMPTY.into(),
            ..Default::default()
        };

        let payload = ack.encode_to_vec();
        let mut frame_buf = Vec::new();
        encode_frame(WireType::SessionAck, &payload, &mut frame_buf).expect("encode must succeed");
        client
            .write_all(&frame_buf)
            .expect("client write must succeed");

        std::thread::sleep(std::time::Duration::from_millis(10));

        let msg = conn
            .try_recv()
            .expect("recv must not fail")
            .expect("message must be available");

        match msg {
            IncomingMessage::SessionAck(received) => {
                assert!(!received.accept, "session must be rejected");
            }
            other => panic!("expected SessionAck, got {other:?}"),
        }
    }

    #[test]
    fn test_receive_identity_result_from_client() {
        let (server, _dir) = test_server();
        let mut client = raw_client(&server);
        let mut conn = accept_connection(&server);

        let result = IdentityResult {
            track_id: 2_u32,
            cat_id: String::from("mittens"),
            similarity: 0.92_f32,
            ..Default::default()
        };

        let payload = result.encode_to_vec();
        let mut frame_buf = Vec::new();
        encode_frame(WireType::IdentityResult, &payload, &mut frame_buf)
            .expect("encode must succeed");
        client
            .write_all(&frame_buf)
            .expect("client write must succeed");

        std::thread::sleep(std::time::Duration::from_millis(10));

        let msg = conn
            .try_recv()
            .expect("recv must not fail")
            .expect("message must be available");

        match msg {
            IncomingMessage::IdentityResult(received) => {
                assert_eq!(received.track_id, 2_u32, "track_id mismatch");
                assert_eq!(received.cat_id, "mittens", "cat_id mismatch");
            }
            other => panic!("expected IdentityResult, got {other:?}"),
        }
    }

    // -----------------------------------------------------------------------
    // Connection: partial read reassembly
    // -----------------------------------------------------------------------

    #[test]
    fn test_partial_frame_reassembly() {
        let (server, _dir) = test_server();
        let mut client = raw_client(&server);
        let mut conn = accept_connection(&server);

        let cmd = BehaviorCommand {
            mode: detection::TargetingMode::TARGETING_MODE_IDLE.into(),
            ..Default::default()
        };

        let payload = cmd.encode_to_vec();
        let mut frame_buf = Vec::new();
        encode_frame(WireType::BehaviorCommand, &payload, &mut frame_buf)
            .expect("encode must succeed");

        // Split the frame in half and send in two writes.
        let mid = frame_buf
            .len()
            .checked_div(2_usize)
            .expect("non-empty frame");
        let (first_half, second_half) = frame_buf.split_at(mid);

        client
            .write_all(first_half)
            .expect("first write must succeed");
        std::thread::sleep(std::time::Duration::from_millis(10));

        // First recv sees partial data — returns None.
        let msg = conn.try_recv().expect("recv must not fail");
        assert!(msg.is_none(), "partial frame must not yield a message");

        // Send the rest.
        client
            .write_all(second_half)
            .expect("second write must succeed");
        std::thread::sleep(std::time::Duration::from_millis(10));

        // Now the full frame is available.
        let msg = conn
            .try_recv()
            .expect("recv must not fail")
            .expect("complete message must be available after reassembly");

        assert!(
            matches!(msg, IncomingMessage::BehaviorCommand(_)),
            "expected BehaviorCommand after reassembly"
        );
    }

    // -----------------------------------------------------------------------
    // Connection: multiple messages in one read
    // -----------------------------------------------------------------------

    #[test]
    fn test_multiple_messages_in_single_read() {
        let (server, _dir) = test_server();
        let mut client = raw_client(&server);
        let mut conn = accept_connection(&server);

        // Encode two messages back-to-back.
        let cmd1 = BehaviorCommand {
            target_track_id: 1_u32,
            ..Default::default()
        };
        let cmd2 = BehaviorCommand {
            target_track_id: 2_u32,
            ..Default::default()
        };

        let mut combined = Vec::new();
        let payload1 = cmd1.encode_to_vec();
        encode_frame(WireType::BehaviorCommand, &payload1, &mut combined)
            .expect("encode must succeed");
        let payload2 = cmd2.encode_to_vec();
        encode_frame(WireType::BehaviorCommand, &payload2, &mut combined)
            .expect("encode must succeed");

        // Send both frames in a single write.
        client
            .write_all(&combined)
            .expect("combined write must succeed");
        std::thread::sleep(std::time::Duration::from_millis(10));

        // First recv yields the first message.
        let msg1 = conn
            .try_recv()
            .expect("recv must not fail")
            .expect("first message must be available");
        match msg1 {
            IncomingMessage::BehaviorCommand(c) => {
                assert_eq!(c.target_track_id, 1_u32, "first message track_id");
            }
            other => panic!("expected BehaviorCommand, got {other:?}"),
        }

        // Second recv yields the second message (already buffered).
        let msg2 = conn
            .try_recv()
            .expect("recv must not fail")
            .expect("second message must be available");
        match msg2 {
            IncomingMessage::BehaviorCommand(c) => {
                assert_eq!(c.target_track_id, 2_u32, "second message track_id");
            }
            other => panic!("expected BehaviorCommand, got {other:?}"),
        }
    }

    // -----------------------------------------------------------------------
    // Connection: peer disconnect detection
    // -----------------------------------------------------------------------

    #[test]
    fn test_peer_disconnect_detected() {
        let (server, _dir) = test_server();
        let client = raw_client(&server);
        let mut conn = accept_connection(&server);

        // Drop the client — closes the connection.
        drop(client);
        std::thread::sleep(std::time::Duration::from_millis(10));

        let result = conn.try_recv();
        assert!(
            matches!(result, Err(IpcError::PeerClosed)),
            "must detect peer disconnect, got {result:?}"
        );
    }

    // -----------------------------------------------------------------------
    // Connection: outbound-only wire types rejected on receive
    // -----------------------------------------------------------------------

    #[test]
    fn test_outbound_wire_type_rejected_on_receive() {
        let (server, _dir) = test_server();
        let mut client = raw_client(&server);
        let mut conn = accept_connection(&server);

        // Client sends a DetectionFrame wire type — invalid direction.
        let frame = DetectionFrame::default();
        let payload = frame.encode_to_vec();
        let mut frame_buf = Vec::new();
        encode_frame(WireType::DetectionFrame, &payload, &mut frame_buf)
            .expect("encode must succeed");
        client.write_all(&frame_buf).expect("write must succeed");

        std::thread::sleep(std::time::Duration::from_millis(10));

        let result = conn.try_recv();
        assert!(
            matches!(result, Err(IpcError::UnexpectedWireType { .. })),
            "outbound-only wire type must be rejected, got {result:?}"
        );
    }

    // -----------------------------------------------------------------------
    // Connection: no data returns None
    // -----------------------------------------------------------------------

    #[test]
    fn test_try_recv_no_data_returns_none() {
        let (server, _dir) = test_server();
        let _client = raw_client(&server);
        let mut conn = accept_connection(&server);

        let msg = conn.try_recv().expect("recv must not fail");
        assert!(msg.is_none(), "no data must return None");
    }

    // -----------------------------------------------------------------------
    // Bidirectional exchange
    // -----------------------------------------------------------------------

    #[test]
    fn test_bidirectional_exchange() {
        let (server, _dir) = test_server();
        let mut client = raw_client(&server);
        let mut conn = accept_connection(&server);

        // Rust → Python: send DetectionFrame.
        let frame = DetectionFrame {
            timestamp_us: 1_234_567_u64,
            frame_number: 100_u64,
            ..Default::default()
        };
        conn.send_detection_frame(&frame)
            .expect("send frame must succeed");

        // Read it on the client side.
        client
            .set_nonblocking(false)
            .expect("set blocking must succeed");
        let mut header_buf = [0_u8; HEADER_SIZE];
        client
            .read_exact(&mut header_buf)
            .expect("read header must succeed");
        let header = decode_header(header_buf).expect("header must decode");
        let mut payload_buf = vec![0_u8; header.length as usize];
        client
            .read_exact(&mut payload_buf)
            .expect("read payload must succeed");

        // Python → Rust: send BehaviorCommand.
        let cmd = BehaviorCommand {
            mode: detection::TargetingMode::TARGETING_MODE_TRACK.into(),
            target_track_id: 42_u32,
            laser_on: true,
            ..Default::default()
        };
        let cmd_payload = cmd.encode_to_vec();
        let mut cmd_frame = Vec::new();
        encode_frame(WireType::BehaviorCommand, &cmd_payload, &mut cmd_frame)
            .expect("encode must succeed");
        client
            .write_all(&cmd_frame)
            .expect("client write must succeed");

        std::thread::sleep(std::time::Duration::from_millis(10));

        let msg = conn
            .try_recv()
            .expect("recv must not fail")
            .expect("message must be available");
        match msg {
            IncomingMessage::BehaviorCommand(received) => {
                assert_eq!(received.target_track_id, 42_u32, "track_id mismatch");
                assert!(received.laser_on, "laser must be on");
            }
            other => panic!("expected BehaviorCommand, got {other:?}"),
        }
    }

    // -----------------------------------------------------------------------
    // Proptest: protobuf message round-trip through wire
    // -----------------------------------------------------------------------

    proptest! {
        #[test]
        fn test_behavior_command_wire_round_trip(
            track_id in 0..1000_u32,
            laser_on in any::<bool>(),
            smoothing in 0.0_f32..1.0_f32,
            offset_x in -1.0_f32..1.0_f32,
            offset_y in -1.0_f32..1.0_f32,
        ) {
            let cmd = BehaviorCommand {
                mode: detection::TargetingMode::TARGETING_MODE_TRACK.into(),
                target_track_id: track_id,
                laser_on,
                smoothing,
                offset_x,
                offset_y,
                ..Default::default()
            };

            let payload = cmd.encode_to_vec();
            let mut frame_buf = Vec::new();
            encode_frame(WireType::BehaviorCommand, &payload, &mut frame_buf)
                .expect("encode must succeed");

            // Extract and decode.
            let header_arr: [u8; HEADER_SIZE] = frame_buf
                .get(..HEADER_SIZE)
                .and_then(|s| <[u8; HEADER_SIZE]>::try_from(s).ok())
                .expect("header must exist");
            let header = decode_header(header_arr).expect("header must decode");
            let decoded_payload = frame_buf.get(HEADER_SIZE..).expect("payload exists");

            let decoded = decode_options()
                .decode_from_slice::<BehaviorCommand>(decoded_payload)
                .expect("decode must succeed");

            prop_assert_eq!(decoded.target_track_id, track_id);
            prop_assert_eq!(decoded.laser_on, laser_on);
            prop_assert_eq!(decoded.smoothing, smoothing);
            prop_assert_eq!(decoded.offset_x, offset_x);
            prop_assert_eq!(decoded.offset_y, offset_y);
            prop_assert_eq!(header.wire_type, WireType::BehaviorCommand);
        }
    }
}
