//! V4L2 DMA capture from the SC3336 via RKISP mainpath.
//!
//! Provides [`Camera`] for frame capture and [`IspController`] for ISP 3A
//! initialization. These are independent subsystems that operate on
//! different V4L2 device nodes:
//!
//! - **`IspController`** opens the ISP metadata nodes (`rkisp-statistics`,
//!   `rkisp-input-params`) to run auto-exposure/white-balance/gain via the
//!   rkaiq library.
//! - **`Camera`** opens `rkisp_mainpath` for ISP-processed NV12 frame
//!   capture using MMAP buffers with DMABUF export for zero-copy to the NPU.
//!
//! The caller coordinates startup order: init ISP, start ISP, open camera,
//! start streaming.

mod buffer;
mod error;
mod rkaiq;
mod v4l2;

use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::time::Duration;

pub(crate) use error::CameraError;
pub(crate) use rkaiq::{IspConfig, IspController};

// ---------------------------------------------------------------------------
// Camera configuration
// ---------------------------------------------------------------------------

/// Default path to the RKISP mainpath video device.
///
/// The actual `/dev/videoN` number varies by kernel build. On the standard
/// Luckfox Pico Ultra W firmware, `rkisp_mainpath` is typically at
/// `/dev/video11`, but this should be verified via `v4l2-ctl --list-devices`
/// or sysfs enumeration.
const DEFAULT_DEVICE_PATH: &str = "/dev/video11";

/// Default number of MMAP buffers to request from the driver.
const DEFAULT_BUFFER_COUNT: u32 = 4;

/// Default capture width.
const DEFAULT_WIDTH: u32 = 640;

/// Default capture height.
const DEFAULT_HEIGHT: u32 = 480;

/// Default poll timeout in milliseconds.
///
/// At 15 FPS, inter-frame interval is ~67ms. 500ms gives generous headroom
/// for ISP processing delays while catching actual stalls.
const DEFAULT_POLL_TIMEOUT_MS: i32 = 500;

/// Camera capture configuration.
#[derive(Debug, Clone)]
pub(crate) struct CameraConfig {
    /// Path to the `rkisp_mainpath` video device.
    pub device_path: PathBuf,
    /// Number of MMAP buffers to request.
    pub buffer_count: u32,
    /// Capture width in pixels (must be even for NV12).
    pub width: u32,
    /// Capture height in pixels (must be even for NV12).
    pub height: u32,
    /// `poll()` timeout in milliseconds when waiting for a frame.
    pub poll_timeout_ms: i32,
}

impl CameraConfig {
    /// Validates the configuration, returning an error for invalid values.
    fn validate(&self) -> Result<(), CameraError> {
        // NV12 requires even dimensions: the UV plane is subsampled 2x
        // in both directions, so odd width or height produces a malformed frame.
        if self.width == 0
            || self.height == 0
            || !self.width.is_multiple_of(2)
            || !self.height.is_multiple_of(2)
        {
            return Err(CameraError::FormatMismatch {
                requested_width: self.width,
                requested_height: self.height,
                requested_format: "NV12",
                actual_width: 0,
                actual_height: 0,
                actual_format: 0,
            });
        }
        Ok(())
    }
}

impl Default for CameraConfig {
    fn default() -> Self {
        Self {
            device_path: PathBuf::from(DEFAULT_DEVICE_PATH),
            buffer_count: DEFAULT_BUFFER_COUNT,
            width: DEFAULT_WIDTH,
            height: DEFAULT_HEIGHT,
            poll_timeout_ms: DEFAULT_POLL_TIMEOUT_MS,
        }
    }
}

// ---------------------------------------------------------------------------
// Captured frame
// ---------------------------------------------------------------------------

/// A captured NV12 frame from the camera.
///
/// Holds a reference to the mmap'd buffer data and the exported DMABUF fd
/// for zero-copy sharing with downstream consumers (NPU, hardware encoder).
///
/// The caller must return the frame via [`Camera::return_frame`] when done
/// processing. Failing to return frames will exhaust the buffer pool and
/// stall capture.
#[derive(Debug)]
pub(crate) struct CapturedFrame<'a> {
    /// NV12 pixel data: Y plane (width * height bytes) followed by
    /// interleaved UV plane (width * height / 2 bytes).
    data: &'a [u8],
    /// DMABUF file descriptor for zero-copy to NPU/encoder.
    dmabuf_fd: BorrowedFd<'a>,
    /// Kernel-assigned frame timestamp (monotonic).
    timestamp: Duration,
    /// Frame sequence number (monotonically increasing from STREAMON).
    sequence: u32,
    /// Buffer index in the pool (pass to `Camera::return_frame`).
    index: u32,
}

impl CapturedFrame<'_> {
    /// NV12 pixel data.
    pub(crate) const fn data(&self) -> &[u8] {
        self.data
    }

    /// DMABUF fd for zero-copy sharing with NPU or hardware encoder.
    pub(crate) const fn dmabuf_fd(&self) -> BorrowedFd<'_> {
        self.dmabuf_fd
    }

    /// Kernel timestamp for this frame.
    pub(crate) const fn timestamp(&self) -> Duration {
        self.timestamp
    }

    /// Frame sequence number.
    pub(crate) const fn sequence(&self) -> u32 {
        self.sequence
    }

    /// Buffer index (pass to [`Camera::return_frame`]).
    pub(crate) const fn index(&self) -> u32 {
        self.index
    }
}

// ---------------------------------------------------------------------------
// Camera
// ---------------------------------------------------------------------------

/// V4L2 camera capture from the RKISP mainpath.
///
/// Opens the ISP-processed video output, configures NV12 640x480
/// multiplanar capture, and manages the MMAP buffer pool with DMABUF
/// export for zero-copy downstream processing.
///
/// # Lifecycle
///
/// ```text
/// Camera::open(config)
///   → start_streaming()
///     → capture_frame() / return_frame() loop
///   → stop_streaming()
///   → [Drop closes device and unmaps buffers]
/// ```
pub(crate) struct Camera {
    device_fd: OwnedFd,
    pool: buffer::BufferPool,
    config: CameraConfig,
    streaming: bool,
}

impl std::fmt::Debug for Camera {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Camera")
            .field("device_path", &self.config.device_path)
            .field(
                "resolution",
                &format_args!("{}x{}", self.config.width, self.config.height),
            )
            .field("buffers", &self.pool.len())
            .field("streaming", &self.streaming)
            .finish_non_exhaustive()
    }
}

impl Camera {
    /// Opens the V4L2 device, verifies capabilities, configures the format,
    /// and allocates the MMAP buffer pool with DMABUF export.
    #[tracing::instrument(skip_all, fields(
        device = %config.device_path.display(),
        width = config.width,
        height = config.height,
        buffers = config.buffer_count,
    ))]
    pub(crate) fn open(config: CameraConfig) -> Result<Self, CameraError> {
        config.validate()?;

        let device_fd = v4l2::open_device(&config.device_path)?;
        let fd = device_fd.as_fd();

        // Verify device capabilities.
        let cap = v4l2::querycap(fd)?;
        v4l2::require_mplane_streaming(&cap)?;
        tracing::debug!(
            driver = %String::from_utf8_lossy(&cap.driver),
            card = %String::from_utf8_lossy(&cap.card),
            "device opened"
        );

        // Configure capture format.
        let _fmt = v4l2::set_format(fd, config.width, config.height)?;
        tracing::debug!("format set: {}x{} NV12", config.width, config.height);

        // Allocate and map buffers.
        let pool = buffer::BufferPool::allocate(fd, config.buffer_count)?;
        tracing::info!(buffers = pool.len(), "camera initialized");

        Ok(Self {
            device_fd,
            pool,
            config,
            streaming: false,
        })
    }

    /// Queues all buffers and starts the V4L2 capture stream.
    pub(crate) fn start_streaming(&mut self) -> Result<(), CameraError> {
        let fd = self.device_fd.as_fd();

        // Queue all buffers so the driver has frames to fill.
        for index in 0..self.pool.len() {
            v4l2::queue_buffer(fd, index)?;
            self.pool.mark_queued(index)?;
        }

        v4l2::stream_on(fd)?;
        self.streaming = true;
        tracing::info!("capture streaming started");
        Ok(())
    }

    /// Waits for a frame, dequeues it, and returns a reference to the data.
    ///
    /// Blocks until a frame is available or the poll timeout expires.
    /// The returned [`CapturedFrame`] borrows from this `Camera`, tying
    /// the frame data lifetime to the buffer pool.
    ///
    /// Call [`return_frame`](Self::return_frame) with the frame's index
    /// when done processing.
    pub(crate) fn capture_frame(&mut self) -> Result<CapturedFrame<'_>, CameraError> {
        let fd = self.device_fd.as_fd();

        // Wait for a frame to be ready.
        let ready = v4l2::poll_frame(fd, self.config.poll_timeout_ms)?;
        if !ready {
            return Err(CameraError::PollTimeout {
                timeout_ms: self.config.poll_timeout_ms,
            });
        }

        // Dequeue the filled buffer.
        let frame_info = v4l2::dequeue_buffer(fd)?;
        self.pool.mark_dequeued(frame_info.index)?;

        if frame_info.is_error {
            return Err(CameraError::CorruptFrame {
                index: frame_info.index,
            });
        }

        let data = self.pool.data(frame_info.index, frame_info.bytesused)?;
        let dmabuf_fd = self.pool.dmabuf_fd(frame_info.index)?;

        Ok(CapturedFrame {
            data,
            dmabuf_fd,
            timestamp: frame_info.timestamp,
            sequence: frame_info.sequence,
            index: frame_info.index,
        })
    }

    /// Returns a previously captured frame's buffer to the driver.
    ///
    /// The buffer is re-enqueued and becomes available for the driver to
    /// fill with a new frame.
    pub(crate) fn return_frame(&mut self, index: u32) -> Result<(), CameraError> {
        v4l2::queue_buffer(self.device_fd.as_fd(), index)?;
        self.pool.mark_queued(index)?;
        Ok(())
    }

    /// Returns `true` if a completed frame is immediately available.
    ///
    /// Uses a zero-timeout poll — returns instantly without blocking.
    /// Detects frames queued in the V4L2 buffer ring that are fresher
    /// than the one just captured. EINTR from signal delivery during
    /// the poll is treated as "not ready" (safe, non-blocking).
    pub(crate) fn has_pending_frame(&self) -> Result<bool, CameraError> {
        match v4l2::poll_frame(self.device_fd.as_fd(), 0_i32) {
            Ok(ready) => Ok(ready),
            Err(CameraError::Poll { source }) if source.raw_os_error() == Some(libc::EINTR) => {
                Ok(false)
            }
            Err(err) => Err(err),
        }
    }

    /// Stops the capture stream and implicitly dequeues all buffers.
    pub(crate) fn stop_streaming(&mut self) -> Result<(), CameraError> {
        if !self.streaming {
            return Ok(());
        }

        v4l2::stream_off(self.device_fd.as_fd())?;
        self.streaming = false;

        // STREAMOFF implicitly dequeues all buffers back to userspace.
        for index in 0..self.pool.len() {
            // Ignore errors — some buffers may already be dequeued.
            drop(self.pool.mark_dequeued(index));
        }

        tracing::info!("capture streaming stopped");
        Ok(())
    }

    /// Returns the device path this camera was opened on.
    pub(crate) fn device_path(&self) -> &Path {
        &self.config.device_path
    }

    /// Returns the capture width.
    pub(crate) const fn width(&self) -> u32 {
        self.config.width
    }

    /// Returns the capture height.
    pub(crate) const fn height(&self) -> u32 {
        self.config.height
    }

    /// Returns whether the capture stream is currently active.
    pub(crate) const fn is_streaming(&self) -> bool {
        self.streaming
    }
}

impl Drop for Camera {
    fn drop(&mut self) {
        if self.streaming
            && let Err(err) = self.stop_streaming()
        {
            tracing::warn!(%err, "failed to stop streaming during camera cleanup");
        }
        // BufferPool::drop handles munmap.
        // OwnedFd::drop handles closing the device fd.
        tracing::debug!(device = %self.config.device_path.display(), "camera closed");
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // --- CameraConfig ---

    #[test]
    fn test_default_config() {
        let config = CameraConfig::default();
        assert_eq!(
            config.device_path,
            PathBuf::from("/dev/video11"),
            "default device path"
        );
        assert_eq!(config.buffer_count, 4, "default buffer count");
        assert_eq!(config.width, 640, "default width");
        assert_eq!(config.height, 480, "default height");
        assert_eq!(config.poll_timeout_ms, 500_i32, "default poll timeout");
    }

    #[test]
    fn test_config_validate_zero_width() {
        let config = CameraConfig {
            width: 0,
            ..CameraConfig::default()
        };
        assert!(
            config.validate().is_err(),
            "zero width must fail validation"
        );
    }

    #[test]
    fn test_config_validate_zero_height() {
        let config = CameraConfig {
            height: 0,
            ..CameraConfig::default()
        };
        assert!(
            config.validate().is_err(),
            "zero height must fail validation"
        );
    }

    #[test]
    fn test_config_validate_odd_width() {
        let config = CameraConfig {
            width: 641,
            ..CameraConfig::default()
        };
        assert!(
            config.validate().is_err(),
            "odd width must fail validation for NV12"
        );
    }

    #[test]
    fn test_config_validate_odd_height() {
        let config = CameraConfig {
            height: 481,
            ..CameraConfig::default()
        };
        assert!(
            config.validate().is_err(),
            "odd height must fail validation for NV12"
        );
    }

    #[test]
    fn test_config_validate_valid() {
        let config = CameraConfig::default();
        assert!(
            config.validate().is_ok(),
            "default config must pass validation"
        );
    }

    #[test]
    fn test_open_nonexistent_device() {
        let config = CameraConfig {
            device_path: PathBuf::from("/dev/video_nonexistent_99"),
            ..CameraConfig::default()
        };
        let result = Camera::open(config);
        let Err(err) = result else {
            #[expect(clippy::panic, reason = "test assertion")]
            {
                panic!("opening nonexistent device must fail");
            }
        };
        assert!(
            matches!(err, CameraError::DeviceOpen { .. }),
            "error must be DeviceOpen, got: {err}"
        );
    }

    // --- CapturedFrame accessors ---

    #[test]
    fn test_captured_frame_accessors() {
        // Create a temporary fd for testing (use /dev/null).
        let Ok(null_fd) = std::fs::File::open("/dev/null") else {
            #[expect(clippy::panic, reason = "test assertion")]
            {
                panic!("/dev/null must be openable in tests");
            }
        };
        let borrowed = null_fd.as_fd();

        let data = [0_u8; 64];
        let frame = CapturedFrame {
            data: &data,
            dmabuf_fd: borrowed,
            timestamp: Duration::from_millis(12345),
            sequence: 42,
            index: 3,
        };

        assert_eq!(frame.data().len(), 64, "data length");
        assert_eq!(frame.timestamp(), Duration::from_millis(12345), "timestamp");
        assert_eq!(frame.sequence(), 42, "sequence");
        assert_eq!(frame.index(), 3, "index");
    }

    // --- error display snapshot tests ---

    #[test]
    fn test_error_display_ioctl() {
        let err = CameraError::Ioctl {
            name: "VIDIOC_QUERYCAP",
            source: std::io::Error::from_raw_os_error(libc::ENODEV),
        };
        insta::assert_snapshot!(err.to_string(), @"v4l2 ioctl VIDIOC_QUERYCAP failed: No such device (os error 19)");
    }

    #[test]
    fn test_error_display_missing_cap() {
        let err = CameraError::MissingCapability("V4L2_CAP_STREAMING");
        insta::assert_snapshot!(err.to_string(), @"device missing required capability: V4L2_CAP_STREAMING");
    }

    #[test]
    fn test_error_display_format_mismatch() {
        let err = CameraError::FormatMismatch {
            requested_width: 640,
            requested_height: 480,
            requested_format: "NV12",
            actual_width: 1920,
            actual_height: 1080,
            actual_format: 0x3231_564E,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"format negotiation failed: requested 640x480 NV12, driver returned 1920x1080 842094158"
        );
    }

    #[test]
    fn test_error_display_insufficient_buffers() {
        let err = CameraError::InsufficientBuffers {
            requested: 4,
            allocated: 1,
            minimum: 2,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"requested 4 buffers, driver allocated 1 (minimum 2)"
        );
    }

    #[test]
    fn test_error_display_poll_timeout() {
        let err = CameraError::PollTimeout {
            timeout_ms: 500_i32,
        };
        insta::assert_snapshot!(err.to_string(), @"poll timed out after 500ms waiting for frame");
    }

    #[test]
    fn test_error_display_corrupt_frame() {
        let err = CameraError::CorruptFrame { index: 2 };
        insta::assert_snapshot!(err.to_string(), @"frame 2 flagged as corrupt by driver");
    }

    #[test]
    fn test_error_display_buffer_not_dequeued() {
        let err = CameraError::BufferNotDequeued {
            index: 1,
            state: "queued",
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"buffer 1 is not dequeued (current state: queued)"
        );
    }

    #[test]
    fn test_error_display_buffer_index_out_of_range() {
        let err = CameraError::BufferIndexOutOfRange {
            index: 10,
            pool_size: 4,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"buffer index 10 out of range (pool size: 4)"
        );
    }

    #[test]
    fn test_error_display_device_open() {
        let err = CameraError::DeviceOpen {
            path: PathBuf::from("/dev/video99"),
            source: std::io::Error::from_raw_os_error(libc::ENOENT),
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"failed to open /dev/video99: No such file or directory (os error 2)"
        );
    }

    #[test]
    fn test_error_display_rkaiq_call() {
        let err = CameraError::RkaiqCall {
            function: "rk_aiq_uapi2_sysctl_start",
            code: -1_i32,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"rkaiq rk_aiq_uapi2_sysctl_start failed with code -1"
        );
    }
}
