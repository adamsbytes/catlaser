//! Camera subsystem error types.

use std::path::PathBuf;

/// Errors from V4L2 camera capture and ISP initialization.
#[derive(Debug, thiserror::Error)]
pub enum CameraError {
    /// A V4L2 ioctl call failed.
    #[error("v4l2 ioctl {name} failed: {source}")]
    Ioctl {
        /// Ioctl name (e.g. `VIDIOC_QUERYCAP`).
        name: &'static str,
        /// Underlying OS error.
        source: std::io::Error,
    },

    /// The device does not advertise required V4L2 capabilities.
    #[error("device missing required capability: {0}")]
    MissingCapability(&'static str),

    /// The driver rejected the requested pixel format or resolution.
    #[error(
        "format negotiation failed: requested {requested_width}x{requested_height} {requested_format}, \
         driver returned {actual_width}x{actual_height} {actual_format}"
    )]
    FormatMismatch {
        /// Requested width.
        requested_width: u32,
        /// Requested height.
        requested_height: u32,
        /// Requested pixel format fourcc as string.
        requested_format: &'static str,
        /// Width the driver actually set.
        actual_width: u32,
        /// Height the driver actually set.
        actual_height: u32,
        /// Pixel format fourcc the driver actually set.
        actual_format: u32,
    },

    /// The driver allocated fewer buffers than the minimum required.
    #[error("requested {requested} buffers, driver allocated {allocated} (minimum {minimum})")]
    InsufficientBuffers {
        /// Number of buffers requested.
        requested: u32,
        /// Number actually allocated by the driver.
        allocated: u32,
        /// Minimum required for the capture pipeline.
        minimum: u32,
    },

    /// `mmap` failed for a V4L2 buffer.
    #[error("mmap failed for buffer {index} plane {plane}: {source}")]
    Mmap {
        /// Buffer index.
        index: u32,
        /// Plane index within the buffer.
        plane: u32,
        /// Underlying OS error.
        source: std::io::Error,
    },

    /// `VIDIOC_EXPBUF` failed to export a buffer as a DMABUF fd.
    #[error("dmabuf export failed for buffer {index} plane {plane}: {source}")]
    DmabufExport {
        /// Buffer index.
        index: u32,
        /// Plane index within the buffer.
        plane: u32,
        /// Underlying OS error.
        source: std::io::Error,
    },

    /// `poll()` on the device fd failed or timed out.
    #[error("poll failed: {source}")]
    Poll {
        /// Underlying OS error.
        source: std::io::Error,
    },

    /// `poll()` timed out waiting for a frame.
    #[error("poll timed out after {timeout_ms}ms waiting for frame")]
    PollTimeout {
        /// Timeout duration in milliseconds.
        timeout_ms: i32,
    },

    /// A dequeued frame has the `V4L2_BUF_FLAG_ERROR` flag set.
    #[error("frame {index} flagged as corrupt by driver")]
    CorruptFrame {
        /// Buffer index of the corrupt frame.
        index: u32,
    },

    /// Attempted to requeue a buffer that is not currently dequeued.
    #[error("buffer {index} is not dequeued (current state: {state})")]
    BufferNotDequeued {
        /// Buffer index.
        index: u32,
        /// Current state description.
        state: &'static str,
    },

    /// Buffer index is out of range for the allocated pool.
    #[error("buffer index {index} out of range (pool size: {pool_size})")]
    BufferIndexOutOfRange {
        /// The invalid index.
        index: u32,
        /// Number of buffers in the pool.
        pool_size: u32,
    },

    /// Failed to open the video device.
    #[error("failed to open {path}: {source}")]
    DeviceOpen {
        /// Path that was attempted.
        path: PathBuf,
        /// Underlying OS error.
        source: std::io::Error,
    },

    /// The rkaiq ISP library could not be loaded.
    #[error("failed to load rkaiq library from {path}: {source}")]
    RkaiqLibraryLoad {
        /// Library path attempted.
        path: PathBuf,
        /// Loading error.
        source: libloading::Error,
    },

    /// A required symbol was not found in the rkaiq library.
    #[error("rkaiq symbol {symbol} not found: {source}")]
    RkaiqSymbol {
        /// Symbol name.
        symbol: &'static str,
        /// Loading error.
        source: libloading::Error,
    },

    /// An rkaiq API call returned an error code.
    #[error("rkaiq {function} failed with code {code}")]
    RkaiqCall {
        /// Function name.
        function: &'static str,
        /// Return code from the library.
        code: i32,
    },
}
