//! End-to-end vision pipeline: camera → NPU → detection → tracking → targeting → serial.
//!
//! Orchestrates all vision subsystems into a single per-frame processing loop.
//! Each call to [`Pipeline::run_frame`] captures a camera frame, runs NPU
//! inference, processes detections through safety filtering and tracking,
//! selects a target, computes servo angles, and transmits a [`ServoCommand`](catlaser_common::ServoCommand)
//! to the MCU over UART.
//!
//! Until the Python behavior engine is connected via IPC, the pipeline
//! operates in autonomous mode: laser on when tracking a confirmed cat,
//! laser off and servos home otherwise.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use catlaser_common::constants::{PAN_HOME, TILT_HOME};
use catlaser_common::servo_math;

use crate::camera::{Camera, CameraConfig, IspConfig, IspController};
use crate::detect::{DetectionConfig, Detector};
use crate::ipc::{IncomingMessage, IpcConnection, IpcServer};
use crate::npu::{Model, ModelPriority, NpuConfig};
use crate::proto::detection::{
    self, DetectionFrame, NewTrack, SessionRequest, TrackEvent, TrackLost, TrackedCat, track_event,
};
use crate::safety::{SafetyComputer, SafetyResult};
use crate::serial::{self, CommandParams, SerialPort};
use crate::targeting::{Targeter, TargetingConfig, TargetingSolution};
use crate::tracker::{Track, TrackState, TrackUpdate, Tracker, TrackerConfig};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Default UART device path on the RV1106G3 compute module.
const DEFAULT_SERIAL_PATH: &str = "/dev/ttyS3";

/// Default RKNN model file path on the target filesystem.
const DEFAULT_MODEL_PATH: &str = "/opt/catlaser/models/yolov8n-coco.rknn";

/// Smoothing value for active tracking (responsive but smooth).
///
/// Maps to ~0.5 interpolation factor in the MCU's 200 Hz control loop.
/// Balances responsive tracking with smooth motion to avoid servo buzz.
const TRACKING_SMOOTHING: u8 = 128_u8;

/// Smoothing value for idle/homing (gentle return to home position).
///
/// Maps to ~0.25 interpolation factor — slow, smooth drift to home to
/// avoid startling the cat when the laser disengages.
const IDLE_SMOOTHING: u8 = 64_u8;

/// Default assumed FPS for velocity conversion when no prior frame
/// timestamp is available (first frame after init).
const DEFAULT_FPS: f32 = 15.0_f32;

/// How long to wait for Python to respond to a `SessionRequest` before
/// reverting to `Idle`. 5 seconds is generous for a local Unix socket
/// round-trip but short enough to prevent a stuck Python from permanently
/// disabling session initiation.
const SESSION_ACK_TIMEOUT: Duration = Duration::from_secs(5);

// ---------------------------------------------------------------------------
// Error
// ---------------------------------------------------------------------------

/// Errors from pipeline initialization and frame processing.
#[derive(Debug, thiserror::Error)]
pub(crate) enum PipelineError {
    /// Failed to initialize or operate the camera/ISP.
    #[error("camera: {0}")]
    Camera(#[from] crate::camera::CameraError),

    /// Failed to load or run the NPU model.
    #[error("npu: {0}")]
    Npu(#[from] crate::npu::error::NpuError),

    /// Failed during detection post-processing.
    #[error("detection: {0}")]
    Detection(#[from] crate::detect::DetectError),

    /// Failed to configure the targeter.
    #[error("targeting: {0}")]
    Targeting(#[from] crate::targeting::TargetingError),

    /// Failed to open or write to the serial port.
    #[error("serial: {0}")]
    Serial(#[from] crate::serial::SerialError),

    /// Failed to read the model file from disk.
    #[error("failed to read model file {path}: {source}")]
    ModelRead {
        /// Filesystem path attempted.
        path: PathBuf,
        /// Underlying OS error.
        source: std::io::Error,
    },

    /// Failed to initialize the IPC Unix socket server.
    #[error("ipc: {0}")]
    Ipc(#[from] crate::ipc::IpcError),

    /// Failed to install a signal handler.
    #[error("failed to install {signal} handler: {source}")]
    Signal {
        /// Signal name (e.g. "SIGTERM").
        signal: &'static str,
        /// Underlying OS error.
        source: std::io::Error,
    },
}

impl PipelineError {
    /// Returns `true` for transient per-frame errors that should be retried.
    ///
    /// Camera poll timeouts and corrupt frames are expected to happen
    /// occasionally and do not indicate a systemic failure. All other
    /// errors (NPU crash, serial disconnect, etc.) are fatal.
    pub(crate) fn is_transient(&self) -> bool {
        use crate::camera::CameraError;
        matches!(
            self,
            Self::Camera(CameraError::PollTimeout { .. } | CameraError::CorruptFrame { .. })
        )
    }
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Aggregated configuration for all pipeline subsystems.
#[derive(Debug, Clone)]
pub(crate) struct PipelineConfig {
    /// Camera capture configuration.
    pub camera: CameraConfig,
    /// ISP 3A (auto-exposure, white balance, gain) configuration.
    pub isp: IspConfig,
    /// NPU runtime configuration.
    pub npu: NpuConfig,
    /// Detection post-processing thresholds.
    pub detection: DetectionConfig,
    /// SORT tracker parameters.
    pub tracker: TrackerConfig,
    /// Camera-to-servo angle transform parameters.
    pub targeting: TargetingConfig,
    /// Path to the RKNN model file on disk.
    pub model_path: PathBuf,
    /// Path to the UART device node for MCU communication.
    pub serial_path: PathBuf,
    /// Path to the Unix domain socket for IPC with the Python behavior engine.
    pub socket_path: PathBuf,
}

impl Default for PipelineConfig {
    fn default() -> Self {
        Self {
            camera: CameraConfig::default(),
            isp: IspConfig::default(),
            npu: NpuConfig::default(),
            detection: DetectionConfig::default(),
            tracker: TrackerConfig::default(),
            targeting: TargetingConfig::default(),
            model_path: PathBuf::from(DEFAULT_MODEL_PATH),
            serial_path: PathBuf::from(DEFAULT_SERIAL_PATH),
            socket_path: PathBuf::from(crate::ipc::DEFAULT_SOCKET_PATH),
        }
    }
}

// ---------------------------------------------------------------------------
// Frame result
// ---------------------------------------------------------------------------

/// Result of processing a single camera frame.
#[derive(Debug, Clone)]
pub(crate) struct FrameResult {
    /// Camera frame sequence number.
    pub sequence: u32,
    /// Number of raw detections from the model (all classes).
    pub detection_count: usize,
    /// Number of cat detections after class filtering.
    pub cat_count: usize,
    /// Number of active tracks (all lifecycle states).
    pub track_count: usize,
    /// Track ID being targeted, or `None` if idle.
    pub target_track_id: Option<u32>,
    /// Safety ceiling state for this frame.
    pub safety: SafetyResult,
    /// Commanded pan angle (centidegrees).
    pub pan: i16,
    /// Commanded tilt angle (centidegrees).
    pub tilt: i16,
    /// Whether the laser was commanded on.
    pub laser_on: bool,
    /// Whether an IPC client (Python behavior engine) is connected.
    pub ipc_connected: bool,
    /// Frame timestamp in monotonic microseconds since boot.
    pub timestamp_us: u64,
    /// Ambient brightness estimate from the Y-plane. 0.0 = dark, 1.0 = bright.
    pub ambient_brightness: f32,
}

// ---------------------------------------------------------------------------
// Pure logic
// ---------------------------------------------------------------------------

/// Hysteresis bonus for the current target's score. A competing cat
/// must exceed the current target's raw score by this margin to steal
/// targeting, preventing frame-to-frame ping-pong between cats with
/// similar activity levels.
const TARGET_SWITCH_MARGIN: f32 = 2.0_f32;

/// Engagement score for a confirmed track.
///
/// Components:
/// - **Speed**: positional velocity magnitude. Faster cats are more
///   engaged. Dominates the score — a fast cat is clearly playing.
/// - **Freshness**: consecutive hit count (capped at 10). More hits
///   means more reliable tracking, slight tiebreaker for equally
///   active cats.
///
/// Scale: speed is ~0-0.15 per frame for an active cat; freshness
/// adds 0-1.0. The hysteresis margin (2.0) dwarfs both, ensuring
/// switches only happen on sustained, obvious engagement differences.
#[expect(
    clippy::as_conversions,
    reason = "hits clamped to 10 then cast u32→u8→f32; value 0-10 is exact in all types"
)]
pub(crate) fn track_score(track: &Track) -> f32 {
    let vel = track.velocity();
    let speed = vel[0].hypot(vel[1]);
    let freshness = f32::from(track.hits().min(10_u32) as u8) * 0.1_f32;
    speed + freshness
}

/// Selects the target track with engagement-based scoring and hysteresis.
///
/// With a single confirmed cat, always selects it (identical to the
/// previous lowest-ID strategy). With multiple cats, prefers the most
/// active cat but strongly resists switching away from the current
/// target to prevent distracting ping-pong.
///
/// Returns `None` when no confirmed tracks exist.
pub(crate) fn select_target(tracks: &[Track], current_target_id: Option<u32>) -> Option<&Track> {
    let mut best: Option<(&Track, f32)> = None;

    for track in tracks.iter().filter(|t| t.state() == TrackState::Confirmed) {
        let mut score = track_score(track);

        if Some(track.id()) == current_target_id {
            score += TARGET_SWITCH_MARGIN;
        }

        if best.is_none_or(|(_, s)| score > s) {
            best = Some((track, score));
        }
    }

    best.map(|(track, _)| track)
}

/// Default behavior parameters when no Python behavior engine is connected.
///
/// When tracking a confirmed cat: laser on, responsive smoothing, default
/// slew rate. When idle: laser off, gentle smoothing for the drift to
/// home position.
pub(crate) fn default_command_params(tracking: bool) -> CommandParams {
    CommandParams {
        laser_on: tracking,
        smoothing: if tracking {
            TRACKING_SMOOTHING
        } else {
            IDLE_SMOOTHING
        },
        max_slew: 0_u8,
        dispense: None,
    }
}

/// Computes the targeting solution for the current frame.
///
/// When a target track exists, converts the track's normalized center
/// coordinates to servo angles and enforces the safety ceiling. When
/// no target exists, returns the home position.
pub(crate) fn compute_solution(
    targeter: &Targeter,
    target: Option<&Track>,
    safety: SafetyResult,
    current_pan: i16,
    current_tilt: i16,
) -> TargetingSolution {
    let Some(track) = target else {
        return TargetingSolution {
            pan: PAN_HOME,
            tilt: TILT_HOME,
        };
    };

    let bbox = track.bbox();
    // bbox is [cx, cy, w, h] in normalized 0.0-1.0 coordinates.
    let cx = bbox.first().copied().unwrap_or(0.5_f32);
    let cy = bbox.get(1).copied().unwrap_or(0.5_f32);

    let raw = targeter.compute(cx, cy, current_pan, current_tilt);
    targeter.enforce_ceiling(raw, safety.ceiling_y, current_tilt)
}

// ---------------------------------------------------------------------------
// IPC: DetectionFrame construction
// ---------------------------------------------------------------------------

/// Computes ambient brightness from the NV12 Y-plane.
///
/// Averages the luminance values of the first `y_plane_size` bytes in the
/// frame data (the Y plane in NV12 format). Returns a value in `[0.0, 1.0]`
/// where 0.0 is complete darkness and 1.0 is maximum brightness.
///
/// At 640x480 the Y-plane is 307,200 bytes. Iteration is ~100 us on the
/// Cortex-A7 — negligible compared to the ~60 ms NPU inference that follows.
pub(crate) fn compute_ambient_brightness(frame_data: &[u8], y_plane_size: usize) -> f32 {
    let y_data = match frame_data.get(..y_plane_size) {
        Some(slice) => slice,
        None => frame_data,
    };
    if y_data.is_empty() {
        return 0.0_f32;
    }

    // Sum Y values as u64. Max sum = 255 × 640 × 480 = 78,643,200 — fits u64.
    let sum: u64 = y_data
        .iter()
        .copied()
        .map(u64::from)
        .fold(0_u64, u64::saturating_add);

    // Both sum (≤ 78M) and len (≤ 307K) are exact in f64. The quotient is
    // in [0.0, 255.0]; dividing by 255 gives [0.0, 1.0], exact in f32.
    #[expect(
        clippy::as_conversions,
        clippy::cast_precision_loss,
        clippy::cast_possible_truncation,
        reason = "sum ≤ 78M and len ≤ 307K are exact in f64; result ∈ [0.0, 1.0] is exact in f32"
    )]
    let brightness = ((sum as f64) / (y_data.len() as f64) / 255.0_f64) as f32;
    brightness
}

/// Maps the internal tracker state enum to the proto `TrackState` enum.
pub(crate) fn map_track_state(state: TrackState) -> detection::TrackState {
    match state {
        TrackState::Tentative => detection::TrackState::TRACK_STATE_TENTATIVE,
        TrackState::Confirmed => detection::TrackState::TRACK_STATE_CONFIRMED,
        TrackState::Coasting => detection::TrackState::TRACK_STATE_COASTING,
    }
}

/// Builds a [`DetectionFrame`] protobuf message from the current pipeline state.
///
/// Pure function — reads from tracker tracks and safety result, produces a
/// proto message ready for IPC transmission. Velocity is converted from
/// per-frame (Kalman filter output) to per-second (proto contract) using
/// the current FPS estimate.
///
/// `cat_id` is left empty for all tracks until the identity system
/// (`MobileNetV2` embedding + catalog matching) is integrated.
pub(crate) fn build_detection_frame(
    tracks: &[Track],
    safety: SafetyResult,
    timestamp_us: u64,
    frame_number: u64,
    ambient_brightness: f32,
    fps_estimate: f32,
) -> DetectionFrame {
    let cats = tracks
        .iter()
        .map(|track| {
            let [cx, cy, w, h] = track.bbox();
            let [vx, vy, _, _] = track.velocity();
            TrackedCat {
                track_id: track.id(),
                cat_id: String::new(),
                center_x: cx,
                center_y: cy,
                width: w,
                height: h,
                velocity_x: vx * fps_estimate,
                velocity_y: vy * fps_estimate,
                state: map_track_state(track.state()).into(),
                ..Default::default()
            }
        })
        .collect();

    DetectionFrame {
        timestamp_us,
        frame_number,
        cats,
        safety_ceiling_y: safety.ceiling_y,
        person_in_frame: safety.person_in_frame,
        ambient_brightness,
        ..Default::default()
    }
}

// ---------------------------------------------------------------------------
// IPC: TrackEvent construction
// ---------------------------------------------------------------------------

/// Converts tracker lifecycle events into protobuf [`TrackEvent`] messages
/// ready for IPC transmission.
///
/// [`TrackUpdate::Confirmed`] maps to `NewTrack`, [`TrackUpdate::Lost`]
/// maps to `TrackLost`. [`TrackUpdate::Reacquired`] is filtered out — it
/// will produce an `IdentityRequest` once the embedding model is integrated.
pub(crate) fn build_track_events(updates: &[TrackUpdate]) -> Vec<TrackEvent> {
    updates
        .iter()
        .filter_map(|update| match *update {
            TrackUpdate::Confirmed { track_id } => Some(TrackEvent {
                event: Some(track_event::Event::NewTrack(Box::new(NewTrack {
                    track_id,
                    ..Default::default()
                }))),
                ..Default::default()
            }),
            TrackUpdate::Lost {
                track_id,
                duration_ms,
            } => Some(TrackEvent {
                event: Some(track_event::Event::TrackLost(Box::new(TrackLost {
                    track_id,
                    duration_ms,
                    ..Default::default()
                }))),
                ..Default::default()
            }),
            TrackUpdate::Reacquired { .. } => None,
        })
        .collect()
}

// ---------------------------------------------------------------------------
// IPC: SessionRequest construction
// ---------------------------------------------------------------------------

/// Builds a [`SessionRequest`] for autonomous session initiation.
pub(crate) fn build_session_request(
    trigger: detection::SessionTrigger,
    track_id: Option<u32>,
) -> SessionRequest {
    SessionRequest {
        trigger: trigger.into(),
        track_id,
        ..Default::default()
    }
}

// ---------------------------------------------------------------------------
// Session state
// ---------------------------------------------------------------------------

/// Tracks the autonomous session lifecycle on the Rust side.
///
/// Prevents duplicate `SessionRequest` messages while one is pending.
/// The `AwaitingAck → Idle` and `AwaitingAck → Active` transitions are
/// handled by the receive path (Part 5, step 5: `BehaviorCommand +
/// SessionAck + IdentityResult`). A timeout on `AwaitingAck` ensures
/// a stuck or slow Python doesn't permanently disable session initiation.
#[derive(Debug, Clone, Copy)]
enum SessionState {
    /// No session in progress or pending. A `SessionRequest` can be sent.
    Idle,
    /// A `SessionRequest` has been sent; waiting for `SessionAck` from Python.
    AwaitingAck {
        /// When the `SessionRequest` was sent.
        sent_at: Instant,
    },
    /// A `SessionRequest` timed out or was rejected. Blocks re-sends until
    /// the deadline expires, preventing immediate re-fire.
    Cooldown {
        /// When the cooldown expires and state reverts to `Idle`.
        until: Instant,
    },
    /// A session is active (Python accepted the `SessionRequest`). No new
    /// `SessionRequest` will be sent until the session ends or Python
    /// disconnects.
    Active,
}

// ---------------------------------------------------------------------------
// Pipeline
// ---------------------------------------------------------------------------

/// End-to-end vision pipeline from camera capture to servo command.
///
/// Owns all subsystem instances and the mutable state needed to process
/// frames. Constructed once via [`Pipeline::init`], then driven by
/// calling [`Pipeline::run_frame`] in a loop.
///
/// Drop order is significant: camera streaming stops before the ISP
/// shuts down, and the serial port closes last. Rust drops struct fields
/// in declaration order, which matches the required teardown sequence.
#[derive(Debug)]
pub(crate) struct Pipeline {
    camera: Camera,
    /// Held for its Drop impl — the ISP 3A thread runs continuously
    /// and must outlive the camera capture stream.
    isp: IspController,
    model: Model,
    detector: Detector,
    safety: SafetyComputer,
    tracker: Tracker,
    targeter: Targeter,
    serial: SerialPort,
    /// Active IPC connection to the Python behavior engine, if any.
    /// Drops before `ipc_server` so the connection closes before the
    /// socket file is removed.
    ipc_connection: Option<IpcConnection>,
    /// Unix socket server for IPC. Drops last among I/O resources —
    /// removes the socket file on cleanup.
    ipc_server: IpcServer,
    /// Current pan angle (centidegrees). Tracks what was last commanded.
    current_pan: i16,
    /// Current tilt angle (centidegrees). Tracks what was last commanded.
    current_tilt: i16,
    /// Track ID of the currently targeted cat, for switch hysteresis.
    current_target_id: Option<u32>,
    /// Person-in-frame flag from the previous frame. On the true→false
    /// transition, the MCU hasn't yet received the relaxed command, so
    /// state clamping must use the stricter person limit for one frame.
    prev_person_in_frame: bool,
    /// Autonomous session lifecycle state. Prevents duplicate
    /// `SessionRequest` messages while one is pending.
    session_state: SessionState,
    /// V4L2 timestamp of the previously processed frame. Used to compute
    /// inter-frame delta for velocity-to-per-second conversion.
    prev_frame_timestamp: Option<Duration>,
    /// NV12 Y-plane size in bytes (`width × height`). Computed once at init
    /// from the camera config for ambient brightness extraction.
    y_plane_size: usize,
    /// Stale frames drained since pipeline init (diagnostic counter).
    frames_drained: u64,
    /// Total frames processed since pipeline init.
    frame_count: u64,
}

impl Pipeline {
    /// Initializes all subsystems in the required startup order.
    ///
    /// Startup sequence:
    /// 1. ISP init → start (must run before camera capture)
    /// 2. Camera open → start streaming
    /// 3. Load RKNN model → construct detector
    /// 4. Tracker, safety computer, targeter (stateless construction)
    /// 5. Serial port open
    ///
    /// On failure, all previously constructed subsystems are dropped
    /// automatically (ISP stops, camera stops streaming, serial closes).
    #[tracing::instrument(skip_all, fields(
        model = %config.model_path.display(),
        serial = %config.serial_path.display(),
    ))]
    pub(crate) fn init(config: PipelineConfig) -> Result<Self, PipelineError> {
        // ISP must be initialized and started before camera capture begins.
        // The ISP 3A thread feeds auto-exposure and white-balance parameters
        // to the hardware ISP, which processes raw sensor data into NV12.
        tracing::info!("initializing ISP 3A");
        let mut isp = IspController::init(&config.isp)?;
        isp.start()?;

        // Capture camera dimensions before config.camera is moved into Camera::open.
        let cam_width = config.camera.width;
        let cam_height = config.camera.height;

        tracing::info!("opening camera");
        let mut camera = Camera::open(config.camera)?;
        camera.start_streaming()?;

        tracing::info!(path = %config.model_path.display(), "loading RKNN model");
        let model_data =
            std::fs::read(&config.model_path).map_err(|source| PipelineError::ModelRead {
                path: config.model_path.clone(),
                source,
            })?;
        let model = Model::load(&config.npu, &model_data, ModelPriority::High)?;

        let detector = Detector::new(config.detection, &model)?;
        let tracker = Tracker::new(config.tracker);
        let safety = SafetyComputer::new();
        let targeter = Targeter::new(&config.targeting)?;

        tracing::info!(path = %config.serial_path.display(), "opening serial port");
        let serial = SerialPort::open(&config.serial_path)?;

        tracing::info!(path = %config.socket_path.display(), "binding IPC socket");
        let ipc_server = IpcServer::bind(&config.socket_path)?;

        // NV12 Y-plane size for ambient brightness computation.
        // Camera validation guarantees non-zero even dimensions. On all
        // supported targets (32-bit ARM, 64-bit host), u32→usize is lossless
        // and the product (≤ 4096² = 16M) fits comfortably.
        #[expect(
            clippy::as_conversions,
            clippy::arithmetic_side_effects,
            reason = "camera dimensions validated ≤ 4096; product fits usize; \
                      u32→usize widening is lossless on 32-bit+"
        )]
        let y_plane_size = cam_width as usize * cam_height as usize;

        tracing::info!("pipeline initialized");
        Ok(Self {
            camera,
            isp,
            model,
            detector,
            safety,
            tracker,
            targeter,
            serial,
            ipc_connection: None,
            ipc_server,
            current_pan: PAN_HOME,
            current_tilt: TILT_HOME,
            current_target_id: None,
            prev_person_in_frame: false,
            session_state: SessionState::Idle,
            prev_frame_timestamp: None,
            y_plane_size,
            frames_drained: 0_u64,
            frame_count: 0_u64,
        })
    }

    /// Processes a single camera frame through the full vision pipeline.
    ///
    /// Capture → inference → detection → safety → tracking → targeting → serial.
    ///
    /// Returns a [`FrameResult`] with per-frame statistics for logging.
    /// Transient errors (poll timeout, corrupt frame) should be retried
    /// by the caller; other errors are fatal.
    pub(crate) fn run_frame(&mut self) -> Result<FrameResult, PipelineError> {
        // --- Capture ---
        // Capture the freshest available frame by draining any stale
        // frames queued in the V4L2 buffer ring. When inference is slow
        // (thermal throttle), multiple frames accumulate; processing the
        // oldest would cause oscillation because the camera has moved
        // since capture. Each drain iteration costs one NV12 memcpy
        // (~100 us) but avoids the ~30-60 ms NPU inference on stale data.
        const MAX_DRAIN: u32 = 3_u32;
        let mut drained = 0_u32;

        let (sequence, frame_timestamp, ambient_brightness) = loop {
            let (seq, idx, ts, brightness) = {
                let frame = self.camera.capture_frame()?;
                let s = frame.sequence();
                let i = frame.index();
                let ts = frame.timestamp();
                let brightness = compute_ambient_brightness(frame.data(), self.y_plane_size);
                self.model.set_input(frame.data())?;
                (s, i, ts, brightness)
            };
            self.camera.return_frame(idx)?;

            if drained < MAX_DRAIN && self.camera.has_pending_frame()? {
                tracing::warn!(
                    seq,
                    drain = drained.saturating_add(1_u32),
                    "replacing stale frame"
                );
                self.frames_drained = self.frames_drained.saturating_add(1_u64);
                drained = drained.saturating_add(1_u32);
                continue;
            }

            break (seq, ts, brightness);
        };

        // --- Inference ---
        self.model.run()?;

        // --- Detection ---
        // Cache model dimensions before detect() — detect returns a slice
        // borrowing self.detector, which prevents subsequent immutable
        // borrows of self.detector for accessors.
        let model_width = self.detector.model_width();
        let model_height = self.detector.model_height();
        let detections = self.detector.detect(&self.model)?;
        let detection_count = detections.len();

        // --- Safety ---
        let safety = self.safety.process(detections, model_height);
        let cat_detections = self.safety.cat_detections();
        let cat_count = cat_detections.len();

        // --- Timestamp ---
        // V4L2 kernel timestamp → monotonic microseconds for IPC and tracker.
        // Duration::as_micros() returns u128; overflow requires >584K years uptime.
        let timestamp_us = u64::try_from(frame_timestamp.as_micros()).unwrap_or(u64::MAX);

        // --- Tracking ---
        self.tracker
            .update(cat_detections, model_width, model_height, timestamp_us);
        let track_count = self.tracker.tracks().len();

        // --- Targeting ---
        let target = select_target(self.tracker.tracks(), self.current_target_id);
        let tracking = target.is_some();
        let target_track_id = target.map(Track::id);

        let solution = compute_solution(
            &self.targeter,
            target,
            safety,
            self.current_pan,
            self.current_tilt,
        );

        // --- Command ---
        let params = default_command_params(tracking);
        let cmd = serial::build_command(solution, safety, params);
        self.serial.send(cmd)?;

        // --- IPC ---
        let ipc_connected = self.stream_ipc(
            frame_timestamp,
            safety,
            ambient_brightness,
            timestamp_us,
            target_track_id,
        );

        // --- State update ---
        // Clamp to the MCU's effective range so that on the next frame the
        // targeting math uses an accurate model of where the camera is
        // actually pointing.  Without this, commands beyond the MCU's
        // horizon limit cause `current_tilt` to diverge from the physical
        // servo position, producing oscillation/jitter near the limit.
        //
        // Use the stricter of current and previous person_in_frame for
        // tilt clamping. On the true→false transition, the MCU is still
        // executing the previous command under the person limit for one
        // frame period (~67 ms). Clamping conservatively keeps
        // current_tilt aligned with the MCU's actual servo position.
        self.current_pan = servo_math::clamp_pan(solution.pan);
        let clamp_person = self.prev_person_in_frame || safety.person_in_frame;
        self.current_tilt = servo_math::clamp_tilt(solution.tilt, clamp_person);
        self.prev_person_in_frame = safety.person_in_frame;
        self.current_target_id = target_track_id;
        self.prev_frame_timestamp = Some(frame_timestamp);
        self.frame_count = self.frame_count.saturating_add(1_u64);

        Ok(FrameResult {
            sequence,
            detection_count,
            cat_count,
            track_count,
            target_track_id,
            safety,
            pan: solution.pan,
            tilt: solution.tilt,
            laser_on: tracking,
            ipc_connected,
            timestamp_us,
            ambient_brightness,
        })
    }

    /// Streams IPC messages to the Python behavior engine.
    ///
    /// Sends a [`DetectionFrame`] every frame (~15/sec), plus sporadic
    /// [`TrackEvent`] and [`SessionRequest`] messages when track lifecycle
    /// transitions occur or an autonomous session should start.
    ///
    /// Computes the FPS estimate from inter-frame timestamps, accepts new
    /// clients, and handles disconnects gracefully — a lost client reverts
    /// to autonomous mode and resets session state.
    fn stream_ipc(
        &mut self,
        frame_timestamp: Duration,
        safety: SafetyResult,
        ambient_brightness: f32,
        timestamp_us: u64,
        target_track_id: Option<u32>,
    ) -> bool {
        // Compute FPS estimate from V4L2 monotonic timestamps for
        // velocity-per-frame → velocity-per-second conversion.
        let fps_estimate = match self.prev_frame_timestamp {
            Some(prev_ts) => {
                let delta_secs = frame_timestamp.saturating_sub(prev_ts).as_secs_f64();
                if delta_secs > 0.0_f64 {
                    #[expect(
                        clippy::as_conversions,
                        clippy::cast_possible_truncation,
                        reason = "FPS ∈ [1, 60] at camera rates, exact in f32"
                    )]
                    {
                        (1.0_f64 / delta_secs) as f32
                    }
                } else {
                    DEFAULT_FPS
                }
            }
            None => DEFAULT_FPS,
        };

        // Accept a new IPC client if none is connected.
        if self.ipc_connection.is_none() {
            match self.ipc_server.try_accept() {
                Ok(Some(conn)) => self.ipc_connection = Some(conn),
                Ok(None) => {}
                Err(err) => tracing::warn!(%err, "IPC accept failed"),
            }
        }

        let Some(conn) = &mut self.ipc_connection else {
            return false;
        };

        // --- DetectionFrame (steady ~15/sec) ---
        let detection_frame = build_detection_frame(
            self.tracker.tracks(),
            safety,
            timestamp_us,
            self.frame_count,
            ambient_brightness,
            fps_estimate,
        );
        if let Err(err) = conn.send_detection_frame(&detection_frame) {
            tracing::warn!(%err, "IPC client disconnected, reverting to autonomous mode");
            self.ipc_connection = None;
            self.session_state = SessionState::Idle;
            return false;
        }

        // --- TrackEvents (sporadic) ---
        let track_events = build_track_events(self.tracker.events());
        for event in &track_events {
            if let Err(err) = conn.send_track_event(event) {
                tracing::warn!(%err, "IPC client disconnected during track event send");
                self.ipc_connection = None;
                self.session_state = SessionState::Idle;
                return false;
            }
        }

        // --- Drain incoming messages (Python → Rust) ---
        loop {
            match conn.try_recv() {
                Ok(Some(msg)) => match msg {
                    IncomingMessage::SessionAck(ack) => {
                        if let SessionState::AwaitingAck { .. } = self.session_state {
                            if ack.accept {
                                tracing::info!("session accepted");
                                self.session_state = SessionState::Active;
                            } else {
                                tracing::info!(skip_reason = ?ack.skip_reason, "session rejected");
                                self.session_state = SessionState::Cooldown {
                                    until: Instant::now() + SESSION_ACK_TIMEOUT,
                                };
                            }
                        } else {
                            tracing::debug!("received stale SessionAck, ignoring");
                        }
                    }
                    IncomingMessage::BehaviorCommand(cmd) => {
                        tracing::debug!(
                            mode = ?cmd.mode,
                            track_id = cmd.target_track_id,
                            "received BehaviorCommand, behavior integration pending"
                        );
                    }
                    IncomingMessage::IdentityResult(result) => {
                        tracing::debug!(
                            track_id = result.track_id,
                            cat_id = %result.cat_id,
                            "received IdentityResult, identity integration pending"
                        );
                    }
                },
                Ok(None) => break,
                Err(err) => {
                    tracing::warn!(%err, "IPC recv error, disconnecting");
                    self.ipc_connection = None;
                    self.session_state = SessionState::Idle;
                    return false;
                }
            }
        }

        // --- Session state transitions ---
        // Time out stale AwaitingAck so a stuck Python doesn't permanently
        // disable session initiation. Transitions to Cooldown (not Idle) to
        // prevent immediate re-fire on the next frame.
        if let SessionState::AwaitingAck { sent_at } = self.session_state
            && sent_at.elapsed() >= SESSION_ACK_TIMEOUT
        {
            tracing::warn!(
                elapsed_ms = sent_at.elapsed().as_millis(),
                "session ack timed out, cooling down"
            );
            self.session_state = SessionState::Cooldown {
                until: Instant::now() + SESSION_ACK_TIMEOUT,
            };
        }

        // Expire cooldown — ready for a new session attempt.
        if let SessionState::Cooldown { until } = self.session_state
            && Instant::now() >= until
        {
            self.session_state = SessionState::Idle;
        }

        // --- SessionRequest (sporadic, at most once per session) ---
        if matches!(self.session_state, SessionState::Idle)
            && let Some(track_id) = target_track_id
        {
            let request = build_session_request(
                detection::SessionTrigger::SESSION_TRIGGER_CAT_DETECTED,
                Some(track_id),
            );
            if let Err(err) = conn.send_session_request(&request) {
                tracing::warn!(%err, "IPC client disconnected during session request");
                self.ipc_connection = None;
                self.session_state = SessionState::Idle;
                return false;
            }
            self.session_state = SessionState::AwaitingAck {
                sent_at: Instant::now(),
            };
            tracing::info!(track_id, "session request sent (cat detected)");
        }

        true
    }

    /// Returns the total number of frames processed since initialization.
    pub(crate) fn frame_count(&self) -> u64 {
        self.frame_count
    }

    /// Returns the total number of stale frames drained since initialization.
    pub(crate) fn frames_drained(&self) -> u64 {
        self.frames_drained
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
#[expect(
    clippy::expect_used,
    clippy::integer_division,
    clippy::panic,
    clippy::float_cmp,
    reason = "test code: expect for test assertions, integer division in known-safe \
              size computations, panic in test failure paths, float_cmp for protobuf \
              round-trip (IEEE 754 preserved bit-exact)"
)]
mod tests {
    use super::*;
    use crate::detect::{BoundingBox, Detection};
    use crate::serial::build_command;
    use crate::targeting::TargetingConfig;
    use buffa::Message;
    use catlaser_common::constants::{
        PAN_HOME, PAN_LIMIT_MAX, PAN_LIMIT_MIN, TILT_HOME, TILT_HORIZON_LIMIT,
        TILT_HORIZON_LIMIT_PERSON, TILT_LIMIT_MAX, TILT_LIMIT_MIN,
    };
    use proptest::prelude::*;

    // -----------------------------------------------------------------------
    // Test helpers
    // -----------------------------------------------------------------------

    /// Creates a cat detection at the given pixel-space center with a fixed size.
    fn cat_detection(cx: f32, cy: f32, size: f32) -> Detection {
        let half = size / 2.0_f32;
        Detection {
            bbox: BoundingBox {
                x1: cx - half,
                y1: cy - half,
                x2: cx + half,
                y2: cy + half,
            },
            class_id: 15_u16,
            confidence: 0.9_f32,
        }
    }

    /// Feeds detections into a tracker for N frames and returns the tracker.
    fn run_tracker(frames: &[&[Detection]]) -> Tracker {
        let mut tracker = Tracker::new(TrackerConfig::default());
        for dets in frames {
            tracker.update(dets, 640.0_f32, 480.0_f32, 0_u64);
        }
        tracker
    }

    /// Creates a targeter with zero parallax for predictable test geometry.
    fn test_targeter() -> Targeter {
        Targeter::new(&TargetingConfig {
            hfov_deg: 80.0_f32,
            vfov_deg: 64.0_f32,
            laser_offset_x_mm: 0.0_f32,
            laser_offset_y_mm: 0.0_f32,
            working_distance_mm: 2000.0_f32,
        })
        .ok()
        .expect_or_log("test targeter config must be valid")
    }

    /// Extension trait for `Option<T>` in tests to avoid denied `expect`.
    trait ExpectOrLog<T> {
        fn expect_or_log(self, msg: &str) -> T;
    }

    impl<T: std::fmt::Debug> ExpectOrLog<T> for Option<T> {
        #[track_caller]
        fn expect_or_log(self, msg: &str) -> T {
            match self {
                Some(val) => val,
                None => {
                    panic!("expect_or_log failed on None: {msg}")
                }
            }
        }
    }

    impl<T: std::fmt::Debug, E: std::fmt::Debug> ExpectOrLog<T> for Result<T, E> {
        #[track_caller]
        fn expect_or_log(self, msg: &str) -> T {
            match self {
                Ok(val) => val,
                Err(err) => {
                    panic!("expect_or_log failed on Err({err:?}): {msg}")
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // select_target
    // -----------------------------------------------------------------------

    #[test]
    fn test_select_target_empty_tracks() {
        assert!(
            select_target(&[], None).is_none(),
            "no tracks must produce no target"
        );
    }

    #[test]
    fn test_select_target_only_tentative() {
        // One frame of detections → tentative tracks (not yet confirmed).
        let det = cat_detection(320.0_f32, 240.0_f32, 50.0_f32);
        let tracker = run_tracker(&[&[det]]);
        let tracks = tracker.tracks();

        assert!(
            !tracks.is_empty(),
            "tracker must have created a tentative track"
        );
        assert!(
            select_target(tracks, None).is_none(),
            "tentative tracks must not be selected as target"
        );
    }

    #[test]
    fn test_select_target_single_confirmed() {
        // 3 frames of the same detection → confirmed track.
        let det = cat_detection(320.0_f32, 240.0_f32, 50.0_f32);
        let tracker = run_tracker(&[&[det], &[det], &[det]]);
        let tracks = tracker.tracks();

        let target = select_target(tracks, None);
        assert!(
            target.is_some(),
            "confirmed track must be selected as target"
        );
        assert_eq!(
            target.map(Track::state),
            Some(TrackState::Confirmed),
            "selected track must be in Confirmed state"
        );
    }

    #[test]
    fn test_select_target_multiple_confirmed_picks_one() {
        // Two detections at different positions, both confirmed.
        // Without hysteresis, the highest-scoring confirmed track wins.
        let det_a = cat_detection(100.0_f32, 100.0_f32, 50.0_f32);
        let det_b = cat_detection(500.0_f32, 400.0_f32, 50.0_f32);
        let both = [det_a, det_b];
        let tracker = run_tracker(&[&both, &both, &both]);
        let tracks = tracker.tracks();

        let confirmed_count = tracks
            .iter()
            .filter(|t| t.state() == TrackState::Confirmed)
            .count();
        assert!(
            confirmed_count >= 2_usize,
            "must have at least 2 confirmed tracks"
        );

        let target = select_target(tracks, None);
        assert!(target.is_some(), "must select a target");
        assert_eq!(
            target.map(Track::state),
            Some(TrackState::Confirmed),
            "selected track must be confirmed"
        );
    }

    #[test]
    fn test_select_target_only_coasting() {
        // Confirm a track, then feed empty frames to transition to coasting.
        let det = cat_detection(320.0_f32, 240.0_f32, 50.0_f32);
        let empty: &[Detection] = &[];
        let mut tracker = Tracker::new(TrackerConfig::default());

        // 3 frames to confirm.
        for _ in 0_u32..3_u32 {
            tracker.update(&[det], 640.0_f32, 480.0_f32, 0_u64);
        }

        // Verify confirmed.
        let pre_coast = select_target(tracker.tracks(), None);
        assert!(
            pre_coast.is_some(),
            "track must be confirmed before coasting test"
        );

        // Feed empty frames to transition to coasting.
        tracker.update(empty, 640.0_f32, 480.0_f32, 0_u64);
        let tracks = tracker.tracks();

        let has_coasting = tracks.iter().any(|t| t.state() == TrackState::Coasting);
        assert!(has_coasting, "track must have transitioned to coasting");

        assert!(
            select_target(tracks, None).is_none(),
            "coasting tracks must not be selected as target"
        );
    }

    #[test]
    fn test_select_target_confirmed_preferred_over_coasting() {
        // Two tracks: one confirmed, one coasting.
        let det_a = cat_detection(100.0_f32, 100.0_f32, 50.0_f32);
        let det_b = cat_detection(500.0_f32, 400.0_f32, 50.0_f32);
        let mut tracker = Tracker::new(TrackerConfig::default());

        // Confirm both tracks.
        for _ in 0_u32..3_u32 {
            tracker.update(&[det_a, det_b], 640.0_f32, 480.0_f32, 0_u64);
        }

        // Feed only det_a — det_b's track starts coasting.
        tracker.update(&[det_a], 640.0_f32, 480.0_f32, 0_u64);
        let tracks = tracker.tracks();

        let confirmed_count = tracks
            .iter()
            .filter(|t| t.state() == TrackState::Confirmed)
            .count();
        let coasting_count = tracks
            .iter()
            .filter(|t| t.state() == TrackState::Coasting)
            .count();
        assert!(
            confirmed_count >= 1_usize && coasting_count >= 1_usize,
            "must have both confirmed and coasting tracks for this test"
        );

        let target = select_target(tracks, None);
        assert!(target.is_some(), "must select a target");
        assert_eq!(
            target.map(Track::state),
            Some(TrackState::Confirmed),
            "must select the confirmed track, not the coasting one"
        );
    }

    // -----------------------------------------------------------------------
    // Multi-cat engagement scoring and hysteresis
    // -----------------------------------------------------------------------

    #[test]
    fn test_track_score_stationary_uses_freshness() {
        // A confirmed track that has been stationary for 3 frames should
        // have a score based only on freshness: 3 * 0.1 = 0.3.
        let det = cat_detection(320.0_f32, 240.0_f32, 50.0_f32);
        let tracker = run_tracker(&[&[det], &[det], &[det]]);
        let target = select_target(tracker.tracks(), None);
        let track = target.expect_or_log("must have a confirmed target");

        let score = track_score(track);
        assert!(
            score >= 0.0_f32,
            "stationary track must have non-negative score, got {score}"
        );
    }

    #[test]
    fn test_select_target_hysteresis_retains_current() {
        // Two confirmed cats at different positions. When one is the
        // current target, hysteresis should retain it even though both
        // have similar activity levels (both stationary).
        let det_a = cat_detection(100.0_f32, 100.0_f32, 50.0_f32);
        let det_b = cat_detection(500.0_f32, 400.0_f32, 50.0_f32);
        let both = [det_a, det_b];
        let tracker = run_tracker(&[&both, &both, &both]);
        let tracks = tracker.tracks();

        let confirmed: Vec<_> = tracks
            .iter()
            .filter(|t| t.state() == TrackState::Confirmed)
            .collect();
        assert!(
            confirmed.len() >= 2_usize,
            "must have at least 2 confirmed tracks"
        );

        // First selection without hysteresis picks whatever scores highest.
        let first = select_target(tracks, None);
        assert!(first.is_some(), "must select a target");
        let first_id = first.map(Track::id);

        // Second selection with hysteresis on the same target retains it.
        let second = select_target(tracks, first_id);
        assert_eq!(
            second.map(Track::id),
            first_id,
            "hysteresis must retain the current target"
        );

        // Third selection with hysteresis on the OTHER target retains that one.
        let other_id = confirmed
            .iter()
            .map(|t| t.id())
            .find(|&id| Some(id) != first_id);
        let third = select_target(tracks, other_id);
        assert_eq!(
            third.map(Track::id),
            other_id,
            "hysteresis must retain whichever track is current"
        );
    }

    #[test]
    fn test_select_target_dead_target_switches() {
        // When the current target's track dies (removed from tracks),
        // the best remaining track is selected without hysteresis penalty.
        let det_a = cat_detection(100.0_f32, 100.0_f32, 50.0_f32);
        let det_b = cat_detection(500.0_f32, 400.0_f32, 50.0_f32);
        let both = [det_a, det_b];
        let mut tracker = Tracker::new(TrackerConfig::default());

        // Confirm both tracks.
        for _ in 0_u32..3_u32 {
            tracker.update(&[det_a, det_b], 640.0_f32, 480.0_f32, 0_u64);
        }

        let first = select_target(tracker.tracks(), None);
        let first_id = first.map(Track::id);

        // Feed only det_b — det_a's track starts coasting, then dies.
        for _ in 0_u32..31_u32 {
            tracker.update(&[det_b], 640.0_f32, 480.0_f32, 0_u64);
        }

        // The old target is gone. Selection with the dead ID should
        // still pick the surviving track.
        let surviving = select_target(tracker.tracks(), first_id);
        assert!(
            surviving.is_some(),
            "must select the surviving confirmed track"
        );
        assert_ne!(
            surviving.map(Track::id),
            first_id,
            "must switch away from the dead target"
        );
    }

    // -----------------------------------------------------------------------
    // default_command_params
    // -----------------------------------------------------------------------

    #[test]
    fn test_default_params_tracking() {
        let params = default_command_params(true);

        assert!(params.laser_on, "laser must be on when tracking");
        assert_eq!(
            params.smoothing, TRACKING_SMOOTHING,
            "smoothing must be TRACKING_SMOOTHING when tracking"
        );
        assert_eq!(
            params.max_slew, 0_u8,
            "max_slew must be 0 (default) when tracking"
        );
        assert!(
            params.dispense.is_none(),
            "no dispense in default tracking mode"
        );
    }

    #[test]
    fn test_default_params_idle() {
        let params = default_command_params(false);

        assert!(!params.laser_on, "laser must be off when idle");
        assert_eq!(
            params.smoothing, IDLE_SMOOTHING,
            "smoothing must be IDLE_SMOOTHING when idle"
        );
        assert_eq!(
            params.max_slew, 0_u8,
            "max_slew must be 0 (default) when idle"
        );
        assert!(
            params.dispense.is_none(),
            "no dispense in default idle mode"
        );
    }

    // -----------------------------------------------------------------------
    // compute_solution
    // -----------------------------------------------------------------------

    #[test]
    fn test_compute_solution_no_target_returns_home() {
        let targeter = test_targeter();
        let safety = SafetyResult {
            ceiling_y: -1.0_f32,
            person_in_frame: false,
        };

        let solution = compute_solution(&targeter, None, safety, 0_i16, 0_i16);

        assert_eq!(solution.pan, PAN_HOME, "idle pan must be PAN_HOME");
        assert_eq!(solution.tilt, TILT_HOME, "idle tilt must be TILT_HOME");
    }

    #[test]
    fn test_compute_solution_with_target_center_no_motion() {
        // A track at frame center should produce minimal angular change
        // from the current position (only parallax, which is zero here).
        let targeter = test_targeter();
        let safety = SafetyResult {
            ceiling_y: -1.0_f32,
            person_in_frame: false,
        };

        // Create a confirmed track at frame center.
        let det = cat_detection(320.0_f32, 240.0_f32, 50.0_f32);
        let tracker = run_tracker(&[&[det], &[det], &[det]]);
        let target = select_target(tracker.tracks(), None);
        assert!(
            target.is_some(),
            "must have a confirmed target for this test"
        );

        let current_pan = 2000_i16;
        let current_tilt = 3000_i16;
        let solution = compute_solution(&targeter, target, safety, current_pan, current_tilt);

        // Track is near center (0.5, 0.5) so the angular offset is near zero.
        // The solution should be close to the current position.
        let pan_delta = i32::from(solution.pan)
            .saturating_sub(i32::from(current_pan))
            .abs();
        let tilt_delta = i32::from(solution.tilt)
            .saturating_sub(i32::from(current_tilt))
            .abs();

        assert!(
            pan_delta < 500_i32,
            "center track should produce small pan change, got delta {pan_delta}"
        );
        assert!(
            tilt_delta < 500_i32,
            "center track should produce small tilt change, got delta {tilt_delta}"
        );
    }

    #[test]
    fn test_compute_solution_ceiling_enforcement() {
        let targeter = test_targeter();
        let safety = SafetyResult {
            ceiling_y: 0.8_f32,
            person_in_frame: true,
        };

        // Create a confirmed track near the top of the frame (low y = above ceiling).
        let det = cat_detection(320.0_f32, 48.0_f32, 50.0_f32);
        let tracker = run_tracker(&[&[det], &[det], &[det]]);
        let target = select_target(tracker.tracks(), None);
        assert!(target.is_some(), "must have a confirmed target");

        let solution = compute_solution(&targeter, target, safety, 0_i16, 4500_i16);

        // The ceiling should clamp the tilt to stay below the safety line.
        // With ceiling_y=0.8 and current_tilt=4500, the ceiling tilt is
        // roughly current_tilt + (0.8 - 0.5) * vfov_centideg = 4500 + 1920 = 6420.
        // The track at y=0.1 (normalized) would want tilt around
        // 4500 + (0.1 - 0.5) * 6400 = 4500 - 2560 = 1940, which is above
        // the ceiling. So ceiling enforcement should clamp to ~6420.
        // .max() picks the higher value (more downward = below ceiling).
        let ceiling_tilt_approx = 6420_i16;
        assert!(
            solution.tilt >= ceiling_tilt_approx.saturating_sub(200_i16),
            "tilt must be clamped below safety ceiling, got {} (ceiling ~{ceiling_tilt_approx})",
            solution.tilt
        );
    }

    // -----------------------------------------------------------------------
    // Full frame decision path (integration)
    // -----------------------------------------------------------------------

    #[test]
    fn test_frame_decision_tracking_produces_valid_command() {
        let targeter = test_targeter();
        let safety = SafetyResult {
            ceiling_y: -1.0_f32,
            person_in_frame: false,
        };

        // Confirmed track near bottom-right of frame.
        let det = cat_detection(500.0_f32, 400.0_f32, 60.0_f32);
        let tracker = run_tracker(&[&[det], &[det], &[det]]);
        let target = select_target(tracker.tracks(), None);
        assert!(target.is_some(), "must have a confirmed target");
        let tracking = target.is_some();

        let solution = compute_solution(&targeter, target, safety, PAN_HOME, TILT_HOME);
        let params = default_command_params(tracking);
        let cmd = build_command(solution, safety, params);

        assert!(
            cmd.verify_checksum(),
            "command from frame decision must have valid checksum"
        );
        assert!(
            cmd.flags().laser_on(),
            "laser must be on when tracking a confirmed cat"
        );
        assert!(
            !cmd.flags().person_detected(),
            "person_detected must be false when no person in frame"
        );
        assert_eq!(cmd.pan(), solution.pan, "command pan must match solution");
        assert_eq!(
            cmd.tilt(),
            solution.tilt,
            "command tilt must match solution"
        );

        // Verify the command round-trips through bytes.
        let bytes = cmd.to_bytes();
        let recovered = catlaser_common::ServoCommand::from_bytes(bytes);
        assert_eq!(
            recovered,
            Ok(cmd),
            "frame decision command must survive byte round-trip"
        );
    }

    #[test]
    fn test_frame_decision_idle_produces_home_command() {
        let targeter = test_targeter();
        let safety = SafetyResult {
            ceiling_y: -1.0_f32,
            person_in_frame: false,
        };

        let solution = compute_solution(&targeter, None, safety, PAN_HOME, TILT_HOME);
        let params = default_command_params(false);
        let cmd = build_command(solution, safety, params);

        assert!(
            cmd.verify_checksum(),
            "idle command must have valid checksum"
        );
        assert!(!cmd.flags().laser_on(), "laser must be off when idle");
        assert_eq!(cmd.pan(), PAN_HOME, "idle command must target PAN_HOME");
        assert_eq!(cmd.tilt(), TILT_HOME, "idle command must target TILT_HOME");
        assert_eq!(
            cmd.smoothing(),
            IDLE_SMOOTHING,
            "idle command must use IDLE_SMOOTHING"
        );
    }

    #[test]
    fn test_frame_decision_with_person_sets_flag() {
        let targeter = test_targeter();
        let safety = SafetyResult {
            ceiling_y: 0.7_f32,
            person_in_frame: true,
        };

        let solution = compute_solution(&targeter, None, safety, PAN_HOME, TILT_HOME);
        let params = default_command_params(false);
        let cmd = build_command(solution, safety, params);

        assert!(
            cmd.flags().person_detected(),
            "person_detected flag must be set when person is in frame"
        );
    }

    #[test]
    fn test_frame_decision_parseable_by_frame_parser() {
        let targeter = test_targeter();
        let safety = SafetyResult {
            ceiling_y: -1.0_f32,
            person_in_frame: false,
        };

        let det = cat_detection(200.0_f32, 300.0_f32, 80.0_f32);
        let tracker = run_tracker(&[&[det], &[det], &[det]]);
        let target = select_target(tracker.tracks(), None);
        let tracking = target.is_some();

        let solution = compute_solution(&targeter, target, safety, 1000_i16, 2000_i16);
        let params = default_command_params(tracking);
        let cmd = build_command(solution, safety, params);
        let bytes = cmd.to_bytes();

        let mut parser = catlaser_common::FrameParser::new();
        let mut result = None;
        for &b in &bytes {
            if let Some(c) = parser.push(b) {
                result = Some(c);
            }
        }
        assert_eq!(
            result,
            Some(cmd),
            "frame decision command must be parseable by MCU FrameParser"
        );
    }

    // -----------------------------------------------------------------------
    // State clamping (pipeline state tracks MCU effective range)
    // -----------------------------------------------------------------------

    /// Simulates the pipeline state update for tilt: the value stored in
    /// `current_tilt` after a frame is the MCU-clamped solution, not the
    /// raw solution. This helper mirrors the production code path.
    fn clamped_tilt(solution_tilt: i16, person_in_frame: bool) -> i16 {
        servo_math::clamp_tilt(solution_tilt, person_in_frame)
    }

    #[test]
    fn test_state_tilt_clamped_to_horizon_limit() {
        // A solution that exceeds the MCU's horizon limit must be clamped
        // in the pipeline's internal state so the next frame's targeting
        // math uses the physical servo position.
        let below_horizon = TILT_HORIZON_LIMIT.saturating_sub(500_i16);
        let clamped = clamped_tilt(below_horizon, false);

        assert_eq!(
            clamped, TILT_HORIZON_LIMIT,
            "tilt below horizon limit must clamp to TILT_HORIZON_LIMIT"
        );
    }

    #[test]
    fn test_state_tilt_clamped_to_person_limit() {
        // When a person is in frame, the MCU applies the stricter person
        // limit. The pipeline state must match.
        let below_person_limit = TILT_HORIZON_LIMIT_PERSON.saturating_sub(200_i16);
        let clamped = clamped_tilt(below_person_limit, true);

        assert_eq!(
            clamped, TILT_HORIZON_LIMIT_PERSON,
            "tilt below person limit must clamp to TILT_HORIZON_LIMIT_PERSON"
        );
    }

    #[test]
    fn test_state_tilt_passthrough_within_range() {
        let in_range = 4500_i16;
        let clamped = clamped_tilt(in_range, false);

        assert_eq!(
            clamped, in_range,
            "tilt within safe range must pass through unchanged"
        );
    }

    #[test]
    fn test_state_pan_clamped_to_limits() {
        let beyond_max = PAN_LIMIT_MAX.saturating_add(100_i16);
        let clamped = servo_math::clamp_pan(beyond_max);

        assert_eq!(
            clamped, PAN_LIMIT_MAX,
            "pan beyond max limit must clamp to PAN_LIMIT_MAX"
        );
    }

    #[test]
    fn test_state_clamping_prevents_feedback_divergence() {
        // Scenario: cat at top of FOV, no person. The targeting solution
        // goes beyond the MCU's horizon limit. Without clamping, the
        // pipeline's current_tilt diverges from the physical position,
        // causing incorrect targeting on subsequent frames.
        let targeter = test_targeter();
        let safety = SafetyResult {
            ceiling_y: -1.0_f32,
            person_in_frame: false,
        };

        // Confirmed track near top of frame.
        let det = cat_detection(320.0_f32, 10.0_f32, 30.0_f32);
        let tracker = run_tracker(&[&[det], &[det], &[det]]);
        let target = select_target(tracker.tracks(), None);
        assert!(target.is_some(), "must have confirmed target");

        // Start with tilt near the horizon limit.
        let current_tilt = TILT_HORIZON_LIMIT;
        let solution = compute_solution(&targeter, target, safety, 0_i16, current_tilt);

        // The raw solution may go below the horizon limit.
        // The clamped state must not.
        let next_tilt = servo_math::clamp_tilt(solution.tilt, false);
        assert!(
            next_tilt >= TILT_HORIZON_LIMIT,
            "clamped state tilt {next_tilt} must be >= TILT_HORIZON_LIMIT {TILT_HORIZON_LIMIT}"
        );

        // Verify the state differs from the unclamped solution when the
        // solution exceeds the horizon.
        if solution.tilt < TILT_HORIZON_LIMIT {
            assert_ne!(
                next_tilt, solution.tilt,
                "state must differ from raw solution when solution exceeds horizon limit"
            );
        }
    }

    // -----------------------------------------------------------------------
    // Person-transition conservative clamping
    // -----------------------------------------------------------------------

    /// Simulates the pipeline's conservative tilt clamping that accounts
    /// for the one-frame MCU command latency on person-detected transitions.
    fn conservative_clamp_tilt(solution_tilt: i16, prev_person: bool, current_person: bool) -> i16 {
        servo_math::clamp_tilt(solution_tilt, prev_person || current_person)
    }

    #[test]
    fn test_state_tilt_conservative_on_person_transition() {
        // When person_in_frame transitions true→false, the MCU is still
        // executing the previous command under the person limit. Tilt at
        // 0 (horizontal) must clamp to TILT_HORIZON_LIMIT_PERSON (500).
        let clamped = conservative_clamp_tilt(0_i16, true, false);

        assert_eq!(
            clamped, TILT_HORIZON_LIMIT_PERSON,
            "transition frame must use person limit"
        );
    }

    #[test]
    fn test_state_tilt_relaxes_after_transition() {
        // One frame after the transition, prev_person is false and
        // the MCU has had time to process the relaxed command.
        let clamped = conservative_clamp_tilt(0_i16, false, false);

        assert_eq!(
            clamped, 0_i16,
            "post-transition frame must use relaxed limit"
        );
    }

    #[test]
    fn test_state_tilt_no_effect_sustained_person() {
        // Both frames have person — person limit applies as usual.
        let clamped = conservative_clamp_tilt(200_i16, true, true);

        assert_eq!(
            clamped, TILT_HORIZON_LIMIT_PERSON,
            "sustained person must use person limit"
        );
    }

    #[test]
    fn test_state_tilt_no_effect_no_person() {
        // Neither frame has person — relaxed limit.
        let clamped = conservative_clamp_tilt(-500_i16, false, false);

        assert_eq!(clamped, -500_i16, "no person must use relaxed limit");
    }

    #[test]
    fn test_state_tilt_person_appearing_uses_person_limit() {
        // Person appears this frame (false→true). The command sent
        // this frame has person_detected=true, so the person limit
        // is correct for both the MCU (which will receive it shortly)
        // and the conservative clamp.
        let clamped = conservative_clamp_tilt(0_i16, false, true);

        assert_eq!(
            clamped, TILT_HORIZON_LIMIT_PERSON,
            "person appearing must use person limit"
        );
    }

    // -----------------------------------------------------------------------
    // Proptests
    // -----------------------------------------------------------------------

    proptest! {
        #[test]
        fn test_conservative_clamp_always_safe_for_both_states(
            solution_tilt in any::<i16>(),
            prev_person in any::<bool>(),
            current_person in any::<bool>(),
        ) {
            let clamped = conservative_clamp_tilt(solution_tilt, prev_person, current_person);

            // The clamped value must satisfy the strictest limit that either
            // the previous or current command imposes — because the MCU may
            // be executing either one during the transition window.
            let prev_min = if prev_person { TILT_HORIZON_LIMIT_PERSON } else { TILT_HORIZON_LIMIT };
            let curr_min = if current_person { TILT_HORIZON_LIMIT_PERSON } else { TILT_HORIZON_LIMIT };
            let strictest_min = prev_min.max(curr_min);

            prop_assert!(
                clamped >= strictest_min,
                "conservative clamp {} must be >= strictest limit {} (prev={}, curr={})",
                clamped, strictest_min, prev_person, current_person,
            );
            prop_assert!(
                clamped <= TILT_LIMIT_MAX,
                "conservative clamp {} must be <= TILT_LIMIT_MAX {}",
                clamped, TILT_LIMIT_MAX,
            );
        }

        #[test]
        fn test_select_target_never_returns_non_confirmed(
            n_frames in 1_usize..=10_usize,
        ) {
            let det = cat_detection(320.0_f32, 240.0_f32, 50.0_f32);
            let dets: Vec<Detection> = vec![det];
            let refs: Vec<&[Detection]> = (0..n_frames).map(|_| dets.as_slice()).collect();
            let tracker = run_tracker(&refs);

            if let Some(target) = select_target(tracker.tracks(), None) {
                prop_assert_eq!(
                    target.state(),
                    TrackState::Confirmed,
                    "select_target must only return Confirmed tracks",
                );
            }
        }

        #[test]
        fn test_select_target_always_confirmed_with_multiple(
            n_extra_frames in 0_usize..=5_usize,
        ) {
            // Two tracks, confirmed (3 + extra frames).
            let det_a = cat_detection(100.0_f32, 100.0_f32, 50.0_f32);
            let det_b = cat_detection(500.0_f32, 400.0_f32, 50.0_f32);
            let both = vec![det_a, det_b];
            let refs: Vec<&[Detection]> = (0..3_usize.saturating_add(n_extra_frames))
                .map(|_| both.as_slice())
                .collect();
            let tracker = run_tracker(&refs);

            let confirmed_ids: Vec<u32> = tracker
                .tracks()
                .iter()
                .filter(|t| t.state() == TrackState::Confirmed)
                .map(Track::id)
                .collect();

            if let Some(target) = select_target(tracker.tracks(), None) {
                prop_assert_eq!(
                    target.state(),
                    TrackState::Confirmed,
                    "must select a confirmed track",
                );
                prop_assert!(
                    confirmed_ids.contains(&target.id()),
                    "selected track ID must be in confirmed set",
                );
            }
        }

        #[test]
        fn test_default_params_laser_matches_tracking(tracking: bool) {
            let params = default_command_params(tracking);
            prop_assert_eq!(
                params.laser_on,
                tracking,
                "laser_on must match tracking state",
            );
            prop_assert!(
                params.dispense.is_none(),
                "default params must never request dispense",
            );
        }

        #[test]
        fn test_compute_solution_within_servo_limits(
            current_pan in (PAN_LIMIT_MIN..=PAN_LIMIT_MAX),
            current_tilt in (TILT_LIMIT_MIN..=TILT_LIMIT_MAX),
        ) {
            let targeter = test_targeter();
            let safety = SafetyResult {
                ceiling_y: -1.0_f32,
                person_in_frame: false,
            };

            // Track at a fixed position — we're testing angle bounds, not tracking.
            let det = cat_detection(320.0_f32, 240.0_f32, 50.0_f32);
            let tracker = run_tracker(&[&[det], &[det], &[det]]);
            let target = select_target(tracker.tracks(), None);

            let solution = compute_solution(
                &targeter,
                target,
                safety,
                current_pan,
                current_tilt,
            );

            prop_assert!(
                solution.pan >= PAN_LIMIT_MIN && solution.pan <= PAN_LIMIT_MAX,
                "pan {} must be within [{}, {}]",
                solution.pan, PAN_LIMIT_MIN, PAN_LIMIT_MAX,
            );
            prop_assert!(
                solution.tilt >= TILT_LIMIT_MIN && solution.tilt <= TILT_LIMIT_MAX,
                "tilt {} must be within [{}, {}]",
                solution.tilt, TILT_LIMIT_MIN, TILT_LIMIT_MAX,
            );
        }

        #[test]
        fn test_idle_solution_always_home(
            current_pan in (PAN_LIMIT_MIN..=PAN_LIMIT_MAX),
            current_tilt in (TILT_LIMIT_MIN..=TILT_LIMIT_MAX),
        ) {
            let targeter = test_targeter();
            let safety = SafetyResult {
                ceiling_y: -1.0_f32,
                person_in_frame: false,
            };

            let solution = compute_solution(
                &targeter,
                None,
                safety,
                current_pan,
                current_tilt,
            );

            prop_assert_eq!(solution.pan, PAN_HOME, "idle pan must always be PAN_HOME");
            prop_assert_eq!(
                solution.tilt,
                TILT_HOME,
                "idle tilt must always be TILT_HOME",
            );
        }

        #[test]
        fn test_frame_decision_always_produces_valid_command(
            current_pan in (PAN_LIMIT_MIN..=PAN_LIMIT_MAX),
            current_tilt in (TILT_LIMIT_MIN..=TILT_LIMIT_MAX),
            has_person: bool,
            has_cat: bool,
        ) {
            let targeter = test_targeter();
            let ceiling_y = if has_person { 0.7_f32 } else { -1.0_f32 };
            let safety = SafetyResult {
                ceiling_y,
                person_in_frame: has_person,
            };

            let target = if has_cat {
                let det = cat_detection(400.0_f32, 350.0_f32, 60.0_f32);
                let tracker = run_tracker(&[&[det], &[det], &[det]]);
                select_target(tracker.tracks(), None).map(Track::id)
            } else {
                None
            };
            let tracking = target.is_some();

            // Recompute solution without borrowing the tracker (it was dropped).
            let solution = if has_cat {
                let det = cat_detection(400.0_f32, 350.0_f32, 60.0_f32);
                let tracker = run_tracker(&[&[det], &[det], &[det]]);
                compute_solution(
                    &targeter,
                    select_target(tracker.tracks(), None),
                    safety,
                    current_pan,
                    current_tilt,
                )
            } else {
                compute_solution(&targeter, None, safety, current_pan, current_tilt)
            };

            let params = default_command_params(tracking);
            let cmd = build_command(solution, safety, params);

            prop_assert!(
                cmd.verify_checksum(),
                "every frame decision must produce a valid checksum",
            );
            prop_assert_eq!(
                cmd.flags().laser_on(),
                tracking,
                "laser state must match tracking",
            );
            prop_assert_eq!(
                cmd.flags().person_detected(),
                has_person,
                "person flag must match safety",
            );
        }

        #[test]
        fn test_state_clamping_always_within_mcu_range(
            solution_pan in any::<i16>(),
            solution_tilt in any::<i16>(),
            person_in_frame: bool,
        ) {
            // The pipeline stores servo_math::clamp_pan / clamp_tilt of
            // the solution. This must always be within the MCU's effective
            // range — the same range the MCU applies in its control loop.
            let clamped_pan = servo_math::clamp_pan(solution_pan);
            let clamped_tilt = servo_math::clamp_tilt(solution_tilt, person_in_frame);

            prop_assert!(
                (PAN_LIMIT_MIN..=PAN_LIMIT_MAX).contains(&clamped_pan),
                "clamped pan {} must be within [{}, {}]",
                clamped_pan, PAN_LIMIT_MIN, PAN_LIMIT_MAX,
            );

            let tilt_min = if person_in_frame {
                TILT_HORIZON_LIMIT_PERSON
            } else {
                TILT_HORIZON_LIMIT
            };
            prop_assert!(
                (tilt_min..=TILT_LIMIT_MAX).contains(&clamped_tilt),
                "clamped tilt {} must be within [{}, {}] (person={})",
                clamped_tilt, tilt_min, TILT_LIMIT_MAX, person_in_frame,
            );
        }
    }

    // -----------------------------------------------------------------------
    // PipelineConfig defaults
    // -----------------------------------------------------------------------

    #[test]
    fn test_pipeline_config_default_paths() {
        let config = PipelineConfig::default();
        assert_eq!(
            config.model_path,
            PathBuf::from(DEFAULT_MODEL_PATH),
            "default model path"
        );
        assert_eq!(
            config.serial_path,
            PathBuf::from(DEFAULT_SERIAL_PATH),
            "default serial path"
        );
        assert_eq!(
            config.socket_path,
            PathBuf::from(crate::ipc::DEFAULT_SOCKET_PATH),
            "default socket path"
        );
    }

    // -----------------------------------------------------------------------
    // PipelineError::is_transient
    // -----------------------------------------------------------------------

    #[test]
    fn test_is_transient_poll_timeout() {
        let err = PipelineError::Camera(crate::camera::CameraError::PollTimeout {
            timeout_ms: 500_i32,
        });
        assert!(err.is_transient(), "PollTimeout must be transient");
    }

    #[test]
    fn test_is_transient_corrupt_frame() {
        let err = PipelineError::Camera(crate::camera::CameraError::CorruptFrame { index: 2 });
        assert!(err.is_transient(), "CorruptFrame must be transient");
    }

    #[test]
    fn test_is_not_transient_serial_write() {
        let err = PipelineError::Serial(crate::serial::SerialError::Write(
            std::io::Error::from_raw_os_error(libc::EIO),
        ));
        assert!(
            !err.is_transient(),
            "serial write error must not be transient"
        );
    }

    #[test]
    fn test_is_not_transient_model_read() {
        let err = PipelineError::ModelRead {
            path: PathBuf::from("/tmp/missing.rknn"),
            source: std::io::Error::from_raw_os_error(libc::ENOENT),
        };
        assert!(
            !err.is_transient(),
            "model read error must not be transient"
        );
    }

    #[test]
    fn test_is_not_transient_ipc() {
        let err = PipelineError::Ipc(crate::ipc::IpcError::Bind {
            path: String::from("/tmp/test.sock"),
            source: std::io::Error::from_raw_os_error(libc::EACCES),
        });
        assert!(!err.is_transient(), "IPC bind error must not be transient");
    }

    // -----------------------------------------------------------------------
    // compute_ambient_brightness
    // -----------------------------------------------------------------------

    #[test]
    fn test_compute_ambient_brightness_all_black() {
        let data = vec![0_u8; 640 * 480];
        let result = compute_ambient_brightness(&data, 640 * 480);
        assert_eq!(result, 0.0_f32, "all-zero Y-plane must produce 0.0");
    }

    #[test]
    fn test_compute_ambient_brightness_all_white() {
        let data = vec![255_u8; 640 * 480];
        let result = compute_ambient_brightness(&data, 640 * 480);
        assert!(
            (result - 1.0_f32).abs() < 0.001_f32,
            "all-255 Y-plane must produce ~1.0, got {result}"
        );
    }

    #[test]
    fn test_compute_ambient_brightness_half() {
        let data = vec![128_u8; 640 * 480];
        let result = compute_ambient_brightness(&data, 640 * 480);
        let expected = 128.0_f32 / 255.0_f32;
        assert!(
            (result - expected).abs() < 0.001_f32,
            "all-128 Y-plane must produce ~{expected}, got {result}"
        );
    }

    #[test]
    fn test_compute_ambient_brightness_empty_data() {
        let result = compute_ambient_brightness(&[], 0);
        assert_eq!(result, 0.0_f32, "empty data must produce 0.0");
    }

    #[test]
    fn test_compute_ambient_brightness_data_shorter_than_y_plane() {
        // When frame data is shorter than y_plane_size, use all available data.
        let data = vec![200_u8; 100];
        let result = compute_ambient_brightness(&data, 1000);
        let expected = 200.0_f32 / 255.0_f32;
        assert!(
            (result - expected).abs() < 0.001_f32,
            "short data must average what's available, got {result}"
        );
    }

    #[test]
    fn test_compute_ambient_brightness_ignores_uv_plane() {
        // NV12: Y-plane (width*height) followed by UV-plane.
        // Only the first y_plane_size bytes should be used.
        let y_size = 640 * 480;
        let uv_size = 640 * 480 / 2;
        let mut data = vec![100_u8; y_size + uv_size];
        // Fill UV plane with a different value.
        for byte in data.get_mut(y_size..).expect("UV range exists") {
            *byte = 255_u8;
        }
        let result = compute_ambient_brightness(&data, y_size);
        let expected = 100.0_f32 / 255.0_f32;
        assert!(
            (result - expected).abs() < 0.001_f32,
            "UV plane data must be ignored, got {result}"
        );
    }

    // -----------------------------------------------------------------------
    // map_track_state
    // -----------------------------------------------------------------------

    #[test]
    fn test_map_track_state_all_variants() {
        assert_eq!(
            map_track_state(TrackState::Tentative),
            detection::TrackState::TRACK_STATE_TENTATIVE,
            "Tentative must map to TRACK_STATE_TENTATIVE"
        );
        assert_eq!(
            map_track_state(TrackState::Confirmed),
            detection::TrackState::TRACK_STATE_CONFIRMED,
            "Confirmed must map to TRACK_STATE_CONFIRMED"
        );
        assert_eq!(
            map_track_state(TrackState::Coasting),
            detection::TrackState::TRACK_STATE_COASTING,
            "Coasting must map to TRACK_STATE_COASTING"
        );
    }

    // -----------------------------------------------------------------------
    // build_detection_frame
    // -----------------------------------------------------------------------

    #[test]
    fn test_build_detection_frame_empty_tracks() {
        let safety = SafetyResult {
            ceiling_y: -1.0_f32,
            person_in_frame: false,
        };
        let frame = build_detection_frame(&[], safety, 1_000_000_u64, 42_u64, 0.5_f32, 15.0_f32);

        assert!(frame.cats.is_empty(), "no tracks must produce no cats");
        assert_eq!(frame.timestamp_us, 1_000_000_u64, "timestamp_us");
        assert_eq!(frame.frame_number, 42_u64, "frame_number");
        assert_eq!(frame.safety_ceiling_y, -1.0_f32, "safety_ceiling_y");
        assert!(!frame.person_in_frame, "person_in_frame");
        assert_eq!(frame.ambient_brightness, 0.5_f32, "ambient_brightness");
    }

    #[test]
    fn test_build_detection_frame_single_confirmed_cat() {
        let det = cat_detection(320.0_f32, 240.0_f32, 50.0_f32);
        let tracker = run_tracker(&[&[det], &[det], &[det]]);
        let safety = SafetyResult {
            ceiling_y: -1.0_f32,
            person_in_frame: false,
        };

        let frame = build_detection_frame(
            tracker.tracks(),
            safety,
            500_000_u64,
            10_u64,
            0.7_f32,
            15.0_f32,
        );

        assert_eq!(frame.cats.len(), 1, "one track must produce one cat");
        let cat = frame.cats.first().expect("cat must exist");
        assert_eq!(
            cat.state,
            detection::TrackState::TRACK_STATE_CONFIRMED,
            "confirmed track must map to TRACK_STATE_CONFIRMED"
        );
        assert!(
            cat.cat_id.is_empty(),
            "cat_id must be empty before identity integration"
        );

        // Bounding box center should be near frame center (320/640, 240/480).
        assert!(
            (cat.center_x - 0.5_f32).abs() < 0.05_f32,
            "center_x should be near 0.5, got {}",
            cat.center_x
        );
        assert!(
            (cat.center_y - 0.5_f32).abs() < 0.05_f32,
            "center_y should be near 0.5, got {}",
            cat.center_y
        );
    }

    #[test]
    fn test_build_detection_frame_multiple_cats_all_states() {
        let det_a = cat_detection(100.0_f32, 100.0_f32, 50.0_f32);
        let det_b = cat_detection(500.0_f32, 400.0_f32, 50.0_f32);
        let mut tracker = Tracker::new(TrackerConfig::default());

        // Confirm both tracks.
        for _ in 0_u32..3_u32 {
            tracker.update(&[det_a, det_b], 640.0_f32, 480.0_f32, 0_u64);
        }
        // Feed only det_a to make det_b coast.
        tracker.update(&[det_a], 640.0_f32, 480.0_f32, 0_u64);

        let safety = SafetyResult {
            ceiling_y: 0.75_f32,
            person_in_frame: true,
        };

        let frame = build_detection_frame(
            tracker.tracks(),
            safety,
            2_000_000_u64,
            100_u64,
            0.3_f32,
            15.0_f32,
        );

        let has_confirmed = frame
            .cats
            .iter()
            .any(|c| c.state == detection::TrackState::TRACK_STATE_CONFIRMED);
        let has_coasting = frame
            .cats
            .iter()
            .any(|c| c.state == detection::TrackState::TRACK_STATE_COASTING);
        assert!(has_confirmed, "must have at least one confirmed cat");
        assert!(has_coasting, "must have at least one coasting cat");
        assert_eq!(
            frame.safety_ceiling_y, 0.75_f32,
            "safety ceiling must propagate"
        );
        assert!(frame.person_in_frame, "person_in_frame must propagate");
    }

    #[test]
    fn test_build_detection_frame_safety_no_person() {
        let safety = SafetyResult {
            ceiling_y: -1.0_f32,
            person_in_frame: false,
        };
        let frame = build_detection_frame(&[], safety, 0_u64, 0_u64, 0.0_f32, 15.0_f32);

        assert_eq!(
            frame.safety_ceiling_y, -1.0_f32,
            "no-person ceiling must be -1.0"
        );
        assert!(!frame.person_in_frame, "no person must be false");
    }

    #[test]
    fn test_build_detection_frame_safety_with_person() {
        let safety = SafetyResult {
            ceiling_y: 0.65_f32,
            person_in_frame: true,
        };
        let frame = build_detection_frame(&[], safety, 0_u64, 0_u64, 0.0_f32, 15.0_f32);

        assert_eq!(
            frame.safety_ceiling_y, 0.65_f32,
            "person ceiling must propagate"
        );
        assert!(frame.person_in_frame, "person flag must propagate");
    }

    #[test]
    fn test_build_detection_frame_velocity_per_second() {
        // A track that moves in x by 0.01 per frame at 15 FPS should
        // report velocity_x ≈ 0.15 normalized units per second.
        let det1 = cat_detection(300.0_f32, 240.0_f32, 50.0_f32);
        let det2 = cat_detection(310.0_f32, 240.0_f32, 50.0_f32);
        let det3 = cat_detection(320.0_f32, 240.0_f32, 50.0_f32);
        let det4 = cat_detection(330.0_f32, 240.0_f32, 50.0_f32);
        let tracker = run_tracker(&[&[det1], &[det2], &[det3], &[det4]]);
        let safety = SafetyResult {
            ceiling_y: -1.0_f32,
            person_in_frame: false,
        };

        let fps = 15.0_f32;
        let frame = build_detection_frame(tracker.tracks(), safety, 0_u64, 0_u64, 0.0_f32, fps);

        assert_eq!(frame.cats.len(), 1, "must have one tracked cat");
        let cat = frame.cats.first().expect("cat must exist");

        // The cat moves ~10 pixels per frame = 10/640 ≈ 0.016 normalized per frame.
        // Velocity_x per second ≈ 0.016 * 15 ≈ 0.234. Kalman smoothing reduces
        // this, so check direction and order of magnitude rather than exact value.
        assert!(
            cat.velocity_x > 0.0_f32,
            "moving right must produce positive velocity_x, got {}",
            cat.velocity_x
        );
        assert!(
            cat.velocity_x < 1.0_f32,
            "velocity_x must be reasonable, got {}",
            cat.velocity_x
        );
    }

    #[test]
    fn test_build_detection_frame_cat_id_always_empty() {
        let det = cat_detection(320.0_f32, 240.0_f32, 50.0_f32);
        let tracker = run_tracker(&[&[det], &[det], &[det]]);
        let safety = SafetyResult {
            ceiling_y: -1.0_f32,
            person_in_frame: false,
        };

        let frame =
            build_detection_frame(tracker.tracks(), safety, 0_u64, 0_u64, 0.0_f32, 15.0_f32);

        for cat in &frame.cats {
            assert!(
                cat.cat_id.is_empty(),
                "cat_id must be empty before identity integration, got {:?}",
                cat.cat_id
            );
        }
    }

    // -----------------------------------------------------------------------
    // build_detection_frame — insta snapshot
    // -----------------------------------------------------------------------

    #[test]
    fn test_snapshot_detection_frame_from_tracks() {
        let det = cat_detection(320.0_f32, 240.0_f32, 50.0_f32);
        let tracker = run_tracker(&[&[det], &[det], &[det]]);
        let safety = SafetyResult {
            ceiling_y: 0.75_f32,
            person_in_frame: true,
        };

        let frame = build_detection_frame(
            tracker.tracks(),
            safety,
            1_000_000_u64,
            42_u64,
            0.6_f32,
            15.0_f32,
        );

        // Snapshot the protobuf wire bytes to detect unexpected changes in
        // the mapping from tracker state to proto fields.
        let payload = frame.encode_to_vec();
        insta::assert_yaml_snapshot!("detection_frame_from_tracks", payload);
    }

    // -----------------------------------------------------------------------
    // IPC: DetectionFrame round-trip over real Unix socket
    // -----------------------------------------------------------------------

    /// Creates an IPC server in a temp directory.
    fn ipc_test_server() -> (crate::ipc::IpcServer, tempfile::TempDir) {
        let dir = tempfile::tempdir().expect("tempdir creation must succeed in tests");
        let path = dir.path().join("test.sock");
        let server = crate::ipc::IpcServer::bind(&path).expect("bind must succeed in tests");
        (server, dir)
    }

    /// Connects a raw `UnixStream` to the IPC server's socket.
    fn ipc_raw_client(server: &crate::ipc::IpcServer) -> std::os::unix::net::UnixStream {
        std::os::unix::net::UnixStream::connect(server.path())
            .expect("connect must succeed in tests")
    }

    /// Accepts a connection from the IPC server.
    fn ipc_accept_connection(server: &crate::ipc::IpcServer) -> crate::ipc::IpcConnection {
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

    #[test]
    fn test_ipc_detection_frame_round_trip() {
        let (server, _dir) = ipc_test_server();
        let mut client = ipc_raw_client(&server);
        let mut conn = ipc_accept_connection(&server);

        // Build a DetectionFrame from real tracker state.
        let det = cat_detection(320.0_f32, 240.0_f32, 50.0_f32);
        let tracker = run_tracker(&[&[det], &[det], &[det]]);
        let safety = SafetyResult {
            ceiling_y: 0.75_f32,
            person_in_frame: true,
        };

        let frame = build_detection_frame(
            tracker.tracks(),
            safety,
            1_000_000_u64,
            42_u64,
            0.6_f32,
            15.0_f32,
        );

        conn.send_detection_frame(&frame)
            .expect("send must succeed");

        // Read raw bytes from the client side.
        client
            .set_nonblocking(false)
            .expect("set blocking must succeed");

        let mut header_buf = [0_u8; 5_usize];
        std::io::Read::read_exact(&mut client, &mut header_buf).expect("read header must succeed");

        let header = crate::ipc::decode_header(header_buf).expect("header must decode");
        assert_eq!(
            header.wire_type,
            crate::ipc::WireType::DetectionFrame,
            "wire type must be DetectionFrame"
        );

        let payload_len = usize::try_from(header.length).expect("length fits usize in tests");
        let mut payload_buf = vec![0_u8; payload_len];
        std::io::Read::read_exact(&mut client, &mut payload_buf)
            .expect("read payload must succeed");

        let decoded = buffa::DecodeOptions::new()
            .decode_from_slice::<DetectionFrame>(&payload_buf)
            .expect("protobuf decode must succeed");

        assert_eq!(decoded.timestamp_us, 1_000_000_u64, "timestamp_us");
        assert_eq!(decoded.frame_number, 42_u64, "frame_number");
        assert_eq!(
            decoded.cats.len(),
            tracker.tracks().len(),
            "cat count must match track count"
        );
        assert_eq!(decoded.safety_ceiling_y, 0.75_f32, "safety_ceiling_y");
        assert!(decoded.person_in_frame, "person_in_frame");
        assert_eq!(decoded.ambient_brightness, 0.6_f32, "ambient_brightness");

        // Verify the tracked cat fields.
        let cat = decoded.cats.first().expect("must have at least one cat");
        assert!(cat.cat_id.is_empty(), "cat_id must be empty");
        assert_eq!(
            cat.state,
            detection::TrackState::TRACK_STATE_CONFIRMED,
            "track state must be CONFIRMED"
        );
    }

    #[test]
    fn test_ipc_multiple_frames_streaming() {
        let (server, _dir) = ipc_test_server();
        let mut client = ipc_raw_client(&server);
        let mut conn = ipc_accept_connection(&server);

        client
            .set_nonblocking(false)
            .expect("set blocking must succeed");

        let safety = SafetyResult {
            ceiling_y: -1.0_f32,
            person_in_frame: false,
        };

        // Stream 10 frames and verify each arrives correctly.
        for i in 0_u64..10_u64 {
            let frame = build_detection_frame(
                &[],
                safety,
                i.saturating_mul(66_667_u64),
                i,
                0.5_f32,
                15.0_f32,
            );
            conn.send_detection_frame(&frame)
                .expect("send must succeed");

            let mut header_buf = [0_u8; 5_usize];
            std::io::Read::read_exact(&mut client, &mut header_buf)
                .expect("read header must succeed");
            let header = crate::ipc::decode_header(header_buf).expect("header must decode");

            let payload_len = usize::try_from(header.length).expect("length fits usize");
            let mut payload_buf = vec![0_u8; payload_len];
            std::io::Read::read_exact(&mut client, &mut payload_buf)
                .expect("read payload must succeed");

            let decoded = buffa::DecodeOptions::new()
                .decode_from_slice::<DetectionFrame>(&payload_buf)
                .expect("decode must succeed");
            assert_eq!(decoded.frame_number, i, "frame_number for frame {i}");
        }
    }

    #[test]
    fn test_ipc_server_continues_without_client() {
        let (server, _dir) = ipc_test_server();

        // No client connected — try_accept returns None.
        let result = server.try_accept().expect("try_accept must not fail");
        assert!(
            result.is_none(),
            "must return None when no client is pending"
        );
    }

    #[test]
    fn test_ipc_server_recovers_from_disconnect() {
        let (server, _dir) = ipc_test_server();

        // First client connects and disconnects.
        let client = ipc_raw_client(&server);
        let mut conn = ipc_accept_connection(&server);
        drop(client);
        std::thread::sleep(std::time::Duration::from_millis(10));

        let frame = build_detection_frame(
            &[],
            SafetyResult {
                ceiling_y: -1.0_f32,
                person_in_frame: false,
            },
            0_u64,
            0_u64,
            0.0_f32,
            15.0_f32,
        );
        let result = conn.send_detection_frame(&frame);
        assert!(result.is_err(), "send to disconnected client must fail");
        drop(conn);

        // Second client connects successfully after first disconnected.
        let _client2 = ipc_raw_client(&server);
        let conn2 = ipc_accept_connection(&server);
        drop(conn2);
    }

    // -----------------------------------------------------------------------
    // build_detection_frame — proptests
    // -----------------------------------------------------------------------

    proptest! {
        #[test]
        fn test_detection_frame_fields_in_range(
            n_frames in 1_usize..=6_usize,
            has_person: bool,
            ceiling_y in -1.0_f32..1.0_f32,
            brightness in 0.0_f32..=1.0_f32,
            fps in 1.0_f32..60.0_f32,
            timestamp_us in any::<u64>(),
            frame_number in any::<u64>(),
        ) {
            let det = cat_detection(320.0_f32, 240.0_f32, 50.0_f32);
            let dets: Vec<Detection> = vec![det];
            let refs: Vec<&[Detection]> = (0..n_frames).map(|_| dets.as_slice()).collect();
            let tracker = run_tracker(&refs);

            let safety_ceiling = if has_person { ceiling_y.abs() } else { -1.0_f32 };
            let safety = SafetyResult {
                ceiling_y: safety_ceiling,
                person_in_frame: has_person,
            };

            let frame = build_detection_frame(
                tracker.tracks(),
                safety,
                timestamp_us,
                frame_number,
                brightness,
                fps,
            );

            prop_assert_eq!(frame.timestamp_us, timestamp_us);
            prop_assert_eq!(frame.frame_number, frame_number);
            prop_assert_eq!(frame.safety_ceiling_y, safety_ceiling);
            prop_assert_eq!(frame.person_in_frame, has_person);
            prop_assert_eq!(frame.ambient_brightness, brightness);

            for cat in &frame.cats {
                // Normalized coordinates must be in [0, 1].
                prop_assert!(
                    cat.center_x >= 0.0_f32 && cat.center_x <= 1.0_f32,
                    "center_x {} out of range",
                    cat.center_x,
                );
                prop_assert!(
                    cat.center_y >= 0.0_f32 && cat.center_y <= 1.0_f32,
                    "center_y {} out of range",
                    cat.center_y,
                );
                prop_assert!(
                    cat.width >= 0.0_f32 && cat.width <= 1.0_f32,
                    "width {} out of range",
                    cat.width,
                );
                prop_assert!(
                    cat.height >= 0.0_f32 && cat.height <= 1.0_f32,
                    "height {} out of range",
                    cat.height,
                );
                // cat_id must be empty (identity not integrated).
                prop_assert!(
                    cat.cat_id.is_empty(),
                    "cat_id must be empty",
                );
                // State must be a valid proto enum value (not UNSPECIFIED).
                prop_assert!(
                    cat.state != detection::TrackState::TRACK_STATE_UNSPECIFIED,
                    "track state must not be UNSPECIFIED",
                );
            }
        }

        #[test]
        fn test_ambient_brightness_always_in_range(
            pixel_val in 0_u8..=255_u8,
        ) {
            let data = vec![pixel_val; 640 * 480];
            let result = compute_ambient_brightness(&data, 640 * 480);
            prop_assert!(
                (0.0_f32..=1.0_f32).contains(&result),
                "brightness {} must be in [0, 1] for pixel value {}",
                result,
                pixel_val,
            );
        }
    }

    // -----------------------------------------------------------------------
    // build_track_events
    // -----------------------------------------------------------------------

    #[test]
    fn test_build_track_events_empty() {
        let events = build_track_events(&[]);
        assert!(events.is_empty(), "no updates must produce no events");
    }

    #[test]
    fn test_build_track_events_confirmed_produces_new_track() {
        let updates = [TrackUpdate::Confirmed { track_id: 7_u32 }];
        let events = build_track_events(&updates);
        assert_eq!(events.len(), 1, "one Confirmed must produce one event");

        let event = events.first().expect("event must exist");
        match &event.event {
            Some(track_event::Event::NewTrack(nt)) => {
                assert_eq!(nt.track_id, 7_u32, "track_id must match");
            }
            other => panic!("expected NewTrack, got {other:?}"),
        }
    }

    #[test]
    fn test_build_track_events_lost_produces_track_lost() {
        let updates = [TrackUpdate::Lost {
            track_id: 3_u32,
            duration_ms: 5000_u32,
        }];
        let events = build_track_events(&updates);
        assert_eq!(events.len(), 1, "one Lost must produce one event");

        let event = events.first().expect("event must exist");
        match &event.event {
            Some(track_event::Event::TrackLost(tl)) => {
                assert_eq!(tl.track_id, 3_u32, "track_id must match");
                assert_eq!(tl.duration_ms, 5000_u32, "duration_ms must match");
            }
            other => panic!("expected TrackLost, got {other:?}"),
        }
    }

    #[test]
    fn test_build_track_events_reacquired_filtered() {
        let updates = [TrackUpdate::Reacquired { track_id: 1_u32 }];
        let events = build_track_events(&updates);
        assert!(
            events.is_empty(),
            "Reacquired must be filtered (no IPC message until embedding model)"
        );
    }

    #[test]
    fn test_build_track_events_mixed() {
        let updates = [
            TrackUpdate::Confirmed { track_id: 0_u32 },
            TrackUpdate::Reacquired { track_id: 1_u32 },
            TrackUpdate::Lost {
                track_id: 2_u32,
                duration_ms: 3000_u32,
            },
        ];
        let events = build_track_events(&updates);
        assert_eq!(
            events.len(),
            2,
            "Confirmed + Lost = 2 events (Reacquired filtered)"
        );

        assert!(
            matches!(
                &events.first().expect("first event").event,
                Some(track_event::Event::NewTrack(_))
            ),
            "first event must be NewTrack"
        );
        assert!(
            matches!(
                &events.get(1).expect("second event").event,
                Some(track_event::Event::TrackLost(_))
            ),
            "second event must be TrackLost"
        );
    }

    // -----------------------------------------------------------------------
    // build_session_request
    // -----------------------------------------------------------------------

    #[test]
    fn test_build_session_request_cat_detected() {
        let request = build_session_request(
            detection::SessionTrigger::SESSION_TRIGGER_CAT_DETECTED,
            Some(5_u32),
        );
        assert_eq!(
            request.trigger,
            detection::SessionTrigger::SESSION_TRIGGER_CAT_DETECTED,
            "trigger must be CAT_DETECTED"
        );
        assert_eq!(
            request.track_id,
            Some(5_u32),
            "track_id must be set for cat-detected trigger"
        );
    }

    #[test]
    fn test_build_session_request_scheduled() {
        let request =
            build_session_request(detection::SessionTrigger::SESSION_TRIGGER_SCHEDULED, None);
        assert_eq!(
            request.trigger,
            detection::SessionTrigger::SESSION_TRIGGER_SCHEDULED,
            "trigger must be SCHEDULED"
        );
        assert_eq!(
            request.track_id, None,
            "track_id must be None for scheduled trigger"
        );
    }

    // -----------------------------------------------------------------------
    // build_track_events — insta snapshot
    // -----------------------------------------------------------------------

    #[test]
    fn test_snapshot_track_event_new_track() {
        let updates = [TrackUpdate::Confirmed { track_id: 1_u32 }];
        let events = build_track_events(&updates);
        let event = events.first().expect("event must exist");
        let payload = event.encode_to_vec();
        insta::assert_yaml_snapshot!("track_event_new_track", payload);
    }

    #[test]
    fn test_snapshot_track_event_track_lost() {
        let updates = [TrackUpdate::Lost {
            track_id: 3_u32,
            duration_ms: 12500_u32,
        }];
        let events = build_track_events(&updates);
        let event = events.first().expect("event must exist");
        let payload = event.encode_to_vec();
        insta::assert_yaml_snapshot!("track_event_track_lost", payload);
    }

    #[test]
    fn test_snapshot_session_request_cat_detected() {
        let request = build_session_request(
            detection::SessionTrigger::SESSION_TRIGGER_CAT_DETECTED,
            Some(2_u32),
        );
        let payload = request.encode_to_vec();
        insta::assert_yaml_snapshot!("session_request_cat_detected", payload);
    }

    // -----------------------------------------------------------------------
    // IPC: TrackEvent + SessionRequest over real Unix socket
    // -----------------------------------------------------------------------

    #[test]
    fn test_ipc_track_event_new_track_round_trip() {
        let (server, _dir) = ipc_test_server();
        let mut client = ipc_raw_client(&server);
        let mut conn = ipc_accept_connection(&server);

        let updates = [TrackUpdate::Confirmed { track_id: 42_u32 }];
        let events = build_track_events(&updates);
        let event = events.first().expect("event must exist");

        conn.send_track_event(event).expect("send must succeed");

        client
            .set_nonblocking(false)
            .expect("set blocking must succeed");

        let mut header_buf = [0_u8; 5_usize];
        std::io::Read::read_exact(&mut client, &mut header_buf).expect("read header must succeed");

        let header = crate::ipc::decode_header(header_buf).expect("header must decode");
        assert_eq!(
            header.wire_type,
            crate::ipc::WireType::TrackEvent,
            "wire type must be TrackEvent"
        );

        let payload_len = usize::try_from(header.length).expect("length fits usize in tests");
        let mut payload_buf = vec![0_u8; payload_len];
        std::io::Read::read_exact(&mut client, &mut payload_buf)
            .expect("read payload must succeed");

        let decoded = buffa::DecodeOptions::new()
            .decode_from_slice::<TrackEvent>(&payload_buf)
            .expect("protobuf decode must succeed");

        match &decoded.event {
            Some(track_event::Event::NewTrack(nt)) => {
                assert_eq!(nt.track_id, 42_u32, "track_id must match");
            }
            other => panic!("expected NewTrack, got {other:?}"),
        }
    }

    #[test]
    fn test_ipc_track_event_track_lost_round_trip() {
        let (server, _dir) = ipc_test_server();
        let mut client = ipc_raw_client(&server);
        let mut conn = ipc_accept_connection(&server);

        let updates = [TrackUpdate::Lost {
            track_id: 7_u32,
            duration_ms: 8500_u32,
        }];
        let events = build_track_events(&updates);
        let event = events.first().expect("event must exist");

        conn.send_track_event(event).expect("send must succeed");

        client
            .set_nonblocking(false)
            .expect("set blocking must succeed");

        let mut header_buf = [0_u8; 5_usize];
        std::io::Read::read_exact(&mut client, &mut header_buf).expect("read header must succeed");
        let header = crate::ipc::decode_header(header_buf).expect("header must decode");

        let payload_len = usize::try_from(header.length).expect("length fits usize");
        let mut payload_buf = vec![0_u8; payload_len];
        std::io::Read::read_exact(&mut client, &mut payload_buf)
            .expect("read payload must succeed");

        let decoded = buffa::DecodeOptions::new()
            .decode_from_slice::<TrackEvent>(&payload_buf)
            .expect("decode must succeed");

        match &decoded.event {
            Some(track_event::Event::TrackLost(tl)) => {
                assert_eq!(tl.track_id, 7_u32, "track_id must match");
                assert_eq!(tl.duration_ms, 8500_u32, "duration_ms must match");
            }
            other => panic!("expected TrackLost, got {other:?}"),
        }
    }

    #[test]
    fn test_ipc_session_request_round_trip() {
        let (server, _dir) = ipc_test_server();
        let mut client = ipc_raw_client(&server);
        let mut conn = ipc_accept_connection(&server);

        let request = build_session_request(
            detection::SessionTrigger::SESSION_TRIGGER_CAT_DETECTED,
            Some(10_u32),
        );

        conn.send_session_request(&request)
            .expect("send must succeed");

        client
            .set_nonblocking(false)
            .expect("set blocking must succeed");

        let mut header_buf = [0_u8; 5_usize];
        std::io::Read::read_exact(&mut client, &mut header_buf).expect("read header must succeed");
        let header = crate::ipc::decode_header(header_buf).expect("header must decode");
        assert_eq!(
            header.wire_type,
            crate::ipc::WireType::SessionRequest,
            "wire type must be SessionRequest"
        );

        let payload_len = usize::try_from(header.length).expect("length fits usize");
        let mut payload_buf = vec![0_u8; payload_len];
        std::io::Read::read_exact(&mut client, &mut payload_buf)
            .expect("read payload must succeed");

        let decoded = buffa::DecodeOptions::new()
            .decode_from_slice::<SessionRequest>(&payload_buf)
            .expect("decode must succeed");

        assert_eq!(
            decoded.trigger,
            detection::SessionTrigger::SESSION_TRIGGER_CAT_DETECTED,
            "trigger must match"
        );
        assert_eq!(decoded.track_id, Some(10_u32), "track_id must match");
    }
}
