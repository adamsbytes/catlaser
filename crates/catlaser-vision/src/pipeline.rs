//! End-to-end vision pipeline: camera → NPU → detection → tracking → targeting → serial.
//!
//! Orchestrates all vision subsystems into a single per-frame processing loop.
//! Each call to [`Pipeline::run_frame`] captures a camera frame, runs NPU
//! inference, processes detections through safety filtering and tracking,
//! selects a target, computes servo angles, and transmits a [`ServoCommand`]
//! to the MCU over UART.
//!
//! Until the Python behavior engine is connected via IPC, the pipeline
//! operates in autonomous mode: laser on when tracking a confirmed cat,
//! laser off and servos home otherwise.

use std::path::PathBuf;

use catlaser_common::constants::{PAN_HOME, TILT_HOME};

use crate::camera::{Camera, CameraConfig, IspConfig, IspController};
use crate::detect::{DetectionConfig, Detector};
use crate::npu::{Model, ModelPriority, NpuConfig};
use crate::safety::{SafetyComputer, SafetyResult};
use crate::serial::{self, CommandParams, SerialPort};
use crate::targeting::{Targeter, TargetingConfig, TargetingSolution};
use crate::tracker::{Track, TrackState, Tracker, TrackerConfig};

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
            Self::Camera(
                CameraError::PollTimeout { .. } | CameraError::CorruptFrame { .. }
            )
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
}

// ---------------------------------------------------------------------------
// Pure logic
// ---------------------------------------------------------------------------

/// Selects the target track from active tracks.
///
/// Returns the confirmed track with the lowest ID (most established).
/// Returns `None` when no confirmed tracks exist — only confirmed
/// tracks are eligible for targeting because tentative tracks may be
/// false positives and coasting tracks have no current observation.
pub(crate) fn select_target(tracks: &[Track]) -> Option<&Track> {
    tracks
        .iter()
        .filter(|t| t.state() == TrackState::Confirmed)
        .min_by_key(|t| t.id())
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
    safety: &SafetyResult,
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
    let cx = bbox.get(0).copied().unwrap_or(0.5_f32);
    let cy = bbox.get(1).copied().unwrap_or(0.5_f32);

    let raw = targeter.compute(cx, cy, current_pan, current_tilt);
    targeter.enforce_ceiling(raw, safety.ceiling_y, current_tilt)
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
    /// Current pan angle (centidegrees). Tracks what was last commanded.
    current_pan: i16,
    /// Current tilt angle (centidegrees). Tracks what was last commanded.
    current_tilt: i16,
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
            current_pan: PAN_HOME,
            current_tilt: TILT_HOME,
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
        let frame = self.camera.capture_frame()?;
        let sequence = frame.sequence();
        let frame_index = frame.index();

        // Copy frame data into the NPU's DMA input buffer. After this
        // completes the camera buffer can be returned for reuse.
        self.model.set_input(frame.data())?;
        drop(frame);
        self.camera.return_frame(frame_index)?;

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

        // --- Tracking ---
        self.tracker
            .update(cat_detections, model_width, model_height);
        let track_count = self.tracker.tracks().len();

        // --- Targeting ---
        let target = select_target(self.tracker.tracks());
        let tracking = target.is_some();
        let target_track_id = target.map(Track::id);

        let solution = compute_solution(
            &self.targeter,
            target,
            &safety,
            self.current_pan,
            self.current_tilt,
        );

        // --- Command ---
        let params = default_command_params(tracking);
        let cmd = serial::build_command(&solution, &safety, &params);
        self.serial.send(&cmd)?;

        // --- State update ---
        self.current_pan = solution.pan;
        self.current_tilt = solution.tilt;
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
        })
    }

    /// Returns the total number of frames processed since initialization.
    pub(crate) fn frame_count(&self) -> u64 {
        self.frame_count
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::detect::{BoundingBox, Detection};
    use crate::serial::build_command;
    use crate::targeting::TargetingConfig;
    use catlaser_common::constants::{
        PAN_HOME, PAN_LIMIT_MAX, PAN_LIMIT_MIN, TILT_HOME, TILT_LIMIT_MAX, TILT_LIMIT_MIN,
    };
    use proptest::prelude::*;

    // -----------------------------------------------------------------------
    // Test helpers
    // -----------------------------------------------------------------------

    /// Creates a cat detection at the given pixel-space center with a fixed size.
    fn cat_detection(cx: f32, cy: f32, size: f32) -> Detection {
        #[expect(
            clippy::arithmetic_side_effects,
            reason = "test helper; cx/cy/size are small known constants, no overflow risk"
        )]
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
            tracker.update(dets, 640.0_f32, 480.0_f32);
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
                    #[expect(clippy::panic, reason = "test-only assertion helper")]
                    {
                        panic!("expect_or_log failed on None: {msg}")
                    }
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
                    #[expect(clippy::panic, reason = "test-only assertion helper")]
                    {
                        panic!("expect_or_log failed on Err({err:?}): {msg}")
                    }
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
            select_target(&[]).is_none(),
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
            select_target(tracks).is_none(),
            "tentative tracks must not be selected as target"
        );
    }

    #[test]
    fn test_select_target_single_confirmed() {
        // 3 frames of the same detection → confirmed track.
        let det = cat_detection(320.0_f32, 240.0_f32, 50.0_f32);
        let tracker = run_tracker(&[&[det], &[det], &[det]]);
        let tracks = tracker.tracks();

        let target = select_target(tracks);
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
    fn test_select_target_multiple_confirmed_picks_lowest_id() {
        // Two detections at different positions, both confirmed.
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

        let target = select_target(tracks);
        assert!(target.is_some(), "must select a target");

        let min_id = confirmed
            .iter()
            .map(|t| t.id())
            .min()
            .expect_or_log("confirmed tracks must be non-empty");
        assert_eq!(
            target.map(Track::id),
            Some(min_id),
            "must select the confirmed track with lowest ID"
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
            tracker.update(&[det], 640.0_f32, 480.0_f32);
        }

        // Verify confirmed.
        let pre_coast = select_target(tracker.tracks());
        assert!(
            pre_coast.is_some(),
            "track must be confirmed before coasting test"
        );

        // Feed empty frames to transition to coasting.
        tracker.update(empty, 640.0_f32, 480.0_f32);
        let tracks = tracker.tracks();

        let has_coasting = tracks.iter().any(|t| t.state() == TrackState::Coasting);
        assert!(has_coasting, "track must have transitioned to coasting");

        assert!(
            select_target(tracks).is_none(),
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
            tracker.update(&[det_a, det_b], 640.0_f32, 480.0_f32);
        }

        // Feed only det_a — det_b's track starts coasting.
        tracker.update(&[det_a], 640.0_f32, 480.0_f32);
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

        let target = select_target(tracks);
        assert!(target.is_some(), "must select a target");
        assert_eq!(
            target.map(Track::state),
            Some(TrackState::Confirmed),
            "must select the confirmed track, not the coasting one"
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

        let solution = compute_solution(&targeter, None, &safety, 0_i16, 0_i16);

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
        let target = select_target(tracker.tracks());
        assert!(
            target.is_some(),
            "must have a confirmed target for this test"
        );

        let current_pan = 2000_i16;
        let current_tilt = 3000_i16;
        let solution = compute_solution(&targeter, target, &safety, current_pan, current_tilt);

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
        let target = select_target(tracker.tracks());
        assert!(target.is_some(), "must have a confirmed target");

        let solution = compute_solution(&targeter, target, &safety, 0_i16, 4500_i16);

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
        let target = select_target(tracker.tracks());
        assert!(target.is_some(), "must have a confirmed target");
        let tracking = target.is_some();

        let solution = compute_solution(&targeter, target, &safety, PAN_HOME, TILT_HOME);
        let params = default_command_params(tracking);
        let cmd = build_command(&solution, &safety, &params);

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

        let solution = compute_solution(&targeter, None, &safety, PAN_HOME, TILT_HOME);
        let params = default_command_params(false);
        let cmd = build_command(&solution, &safety, &params);

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

        let solution = compute_solution(&targeter, None, &safety, PAN_HOME, TILT_HOME);
        let params = default_command_params(false);
        let cmd = build_command(&solution, &safety, &params);

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
        let target = select_target(tracker.tracks());
        let tracking = target.is_some();

        let solution = compute_solution(&targeter, target, &safety, 1000_i16, 2000_i16);
        let params = default_command_params(tracking);
        let cmd = build_command(&solution, &safety, &params);
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
    // Proptests
    // -----------------------------------------------------------------------

    proptest! {
        #[test]
        fn test_select_target_never_returns_non_confirmed(
            n_frames in 1_usize..=10_usize,
        ) {
            let det = cat_detection(320.0_f32, 240.0_f32, 50.0_f32);
            let dets: Vec<Detection> = vec![det];
            let refs: Vec<&[Detection]> = (0..n_frames).map(|_| dets.as_slice()).collect();
            let tracker = run_tracker(&refs);

            if let Some(target) = select_target(tracker.tracks()) {
                prop_assert_eq!(
                    target.state(),
                    TrackState::Confirmed,
                    "select_target must only return Confirmed tracks",
                );
            }
        }

        #[test]
        fn test_select_target_returns_minimum_confirmed_id(
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

            if let (Some(target), Some(&min_id)) =
                (select_target(tracker.tracks()), confirmed_ids.iter().min())
            {
                prop_assert_eq!(
                    target.id(),
                    min_id,
                    "must select confirmed track with minimum ID",
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
            let target = select_target(tracker.tracks());

            let solution = compute_solution(
                &targeter,
                target,
                &safety,
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
                &safety,
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
                select_target(tracker.tracks()).map(Track::id)
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
                    select_target(tracker.tracks()),
                    &safety,
                    current_pan,
                    current_tilt,
                )
            } else {
                compute_solution(&targeter, None, &safety, current_pan, current_tilt)
            };

            let params = default_command_params(tracking);
            let cmd = build_command(&solution, &safety, &params);

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
}
