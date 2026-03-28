//! V4L2 MMAP buffer pool with DMABUF export.
//!
//! Manages the lifecycle of V4L2 buffers: allocation, mmap mapping,
//! DMABUF fd export, and state tracking (queued vs. dequeued).

use std::os::fd::{AsFd, AsRawFd, BorrowedFd, OwnedFd};

use super::error::CameraError;
use super::v4l2;

// ---------------------------------------------------------------------------
// Buffer state
// ---------------------------------------------------------------------------

/// Tracks whether a buffer is currently owned by the driver or userspace.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum BufferState {
    /// Buffer is in the driver's incoming queue, waiting to be filled.
    Queued,
    /// Buffer has been dequeued and is owned by userspace.
    Dequeued,
}

impl BufferState {
    /// Returns a static string label for error messages.
    const fn label(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Dequeued => "dequeued",
        }
    }
}

// ---------------------------------------------------------------------------
// Single buffer descriptor
// ---------------------------------------------------------------------------

/// A single V4L2 MMAP buffer with its mmap pointer and DMABUF fd.
#[derive(Debug)]
struct MappedBuffer {
    /// Pointer to the mmap'd region. Valid for the lifetime of the buffer pool.
    ptr: *mut u8,
    /// Length of the mmap'd region in bytes.
    length: usize,
    /// Exported DMABUF file descriptor for zero-copy sharing with NPU/encoder.
    dmabuf_fd: OwnedFd,
    /// Current state: queued (driver owns) or dequeued (userspace owns).
    state: BufferState,
}

// MappedBuffer contains a raw pointer (*mut u8) which is !Send by default.
// The pointer is to a stable kernel-managed mmap region that does not move
// and is only accessed through our controlled API. It is safe to move the
// buffer between threads.
#[expect(
    unsafe_code,
    reason = "MappedBuffer's *mut u8 points to a stable kernel mmap region — ADR-001"
)]
// SAFETY: The *mut u8 in MappedBuffer points to a kernel-managed mmap'd
// buffer. The mapping is stable (doesn't move) and access is synchronized
// by the buffer state machine (only accessed when dequeued). Moving the
// struct between threads is safe because the kernel memory doesn't change.
unsafe impl Send for MappedBuffer {}

// ---------------------------------------------------------------------------
// Buffer pool
// ---------------------------------------------------------------------------

/// Pool of V4L2 MMAP buffers with DMABUF export and state tracking.
///
/// Created during camera initialization. Buffers are allocated by the V4L2
/// driver, mapped into userspace for CPU access, and exported as DMABUF
/// fds for zero-copy sharing with the NPU and hardware encoder.
#[derive(Debug)]
pub(super) struct BufferPool {
    buffers: Vec<MappedBuffer>,
}

impl BufferPool {
    /// Allocates, maps, and exports `count` V4L2 MMAP buffers.
    ///
    /// All buffers start in the `Dequeued` state. The caller should queue
    /// them via [`queue`] before starting the stream.
    pub(super) fn allocate(fd: BorrowedFd<'_>, count: u32) -> Result<Self, CameraError> {
        let allocated = v4l2::request_buffers(fd, count)?;
        tracing::debug!(requested = count, allocated, "V4L2 buffers allocated");

        let mut buffers = Vec::with_capacity(usize::try_from(allocated).unwrap_or(usize::MAX));

        for index in 0..allocated {
            let (_buf, plane) = v4l2::query_buffer(fd, index)?;
            let length = usize::try_from(plane.length).unwrap_or(0);
            let offset = plane.m.mem_offset();

            let (ptr, mapped_len) = v4l2::mmap_buffer(fd, length, offset, index, 0)?;
            let dmabuf_fd = v4l2::export_buffer(fd, index, 0)?;

            tracing::trace!(
                index,
                length = mapped_len,
                dmabuf_fd = dmabuf_fd.as_raw_fd(),
                "buffer mapped + exported"
            );

            buffers.push(MappedBuffer {
                ptr,
                length: mapped_len,
                dmabuf_fd,
                state: BufferState::Dequeued,
            });
        }

        Ok(Self { buffers })
    }

    /// Returns the number of buffers in the pool.
    #[expect(
        clippy::as_conversions,
        clippy::cast_possible_truncation,
        reason = "buffer count originates from a u32 (V4L2 REQBUFS); \
                  Vec length will never exceed u32::MAX for camera buffers"
    )]
    pub(super) const fn len(&self) -> u32 {
        self.buffers.len() as u32
    }

    /// Marks a buffer as queued (driver-owned).
    ///
    /// Does not call the V4L2 ioctl — the caller must do that separately.
    /// This just updates the state tracking.
    pub(super) fn mark_queued(&mut self, index: u32) -> Result<(), CameraError> {
        let buf = self.get_mut(index)?;
        if buf.state != BufferState::Dequeued {
            return Err(CameraError::BufferNotDequeued {
                index,
                state: buf.state.label(),
            });
        }
        buf.state = BufferState::Queued;
        Ok(())
    }

    /// Marks a buffer as dequeued (userspace-owned).
    ///
    /// Does not call the V4L2 ioctl — the caller must do that separately.
    pub(super) fn mark_dequeued(&mut self, index: u32) -> Result<(), CameraError> {
        let buf = self.get_mut(index)?;
        buf.state = BufferState::Dequeued;
        Ok(())
    }

    /// Returns the mmap'd data for a dequeued buffer.
    ///
    /// The returned slice is only valid while the buffer is dequeued.
    /// Accessing mmap'd memory while the buffer is queued to the driver
    /// is undefined behavior.
    pub(super) fn data(&self, index: u32, bytesused: u32) -> Result<&[u8], CameraError> {
        let buf = self.get(index)?;
        if buf.state != BufferState::Dequeued {
            return Err(CameraError::BufferNotDequeued {
                index,
                state: buf.state.label(),
            });
        }

        let len = usize::try_from(bytesused).unwrap_or(0).min(buf.length);

        #[expect(
            unsafe_code,
            reason = "constructing a slice from the mmap'd buffer pointer — ADR-001"
        )]
        // SAFETY: buf.ptr is a valid mmap'd pointer with buf.length bytes.
        // The buffer is in Dequeued state, meaning the kernel is not writing
        // to it. `len` is clamped to buf.length. The lifetime of the slice
        // is tied to &self, so the pool (and its mmap) outlives the reference.
        let data = unsafe { std::slice::from_raw_parts(buf.ptr, len) };

        Ok(data)
    }

    /// Returns the DMABUF fd for a buffer (for zero-copy to NPU/encoder).
    pub(super) fn dmabuf_fd(&self, index: u32) -> Result<BorrowedFd<'_>, CameraError> {
        let buf = self.get(index)?;
        Ok(buf.dmabuf_fd.as_fd())
    }

    /// Returns the current state of a buffer.
    pub(super) fn state(&self, index: u32) -> Result<BufferState, CameraError> {
        Ok(self.get(index)?.state)
    }

    fn get(&self, index: u32) -> Result<&MappedBuffer, CameraError> {
        let idx = usize::try_from(index).unwrap_or(usize::MAX);
        self.buffers
            .get(idx)
            .ok_or(CameraError::BufferIndexOutOfRange {
                index,
                pool_size: self.len(),
            })
    }

    fn get_mut(&mut self, index: u32) -> Result<&mut MappedBuffer, CameraError> {
        let pool_size = self.len();
        let idx = usize::try_from(index).unwrap_or(usize::MAX);
        self.buffers
            .get_mut(idx)
            .ok_or(CameraError::BufferIndexOutOfRange { index, pool_size })
    }
}

impl Drop for BufferPool {
    fn drop(&mut self) {
        for buf in &self.buffers {
            v4l2::munmap_buffer(buf.ptr, buf.length);
        }
        tracing::debug!(count = self.buffers.len(), "buffer pool unmapped");
    }
}

// OwnedFd handles closing the DMABUF fds when MappedBuffer is dropped.

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_buffer_state_labels() {
        assert_eq!(
            BufferState::Queued.label(),
            "queued",
            "Queued state label must be 'queued'"
        );
        assert_eq!(
            BufferState::Dequeued.label(),
            "dequeued",
            "Dequeued state label must be 'dequeued'"
        );
    }

    #[test]
    fn test_buffer_state_equality() {
        assert_eq!(
            BufferState::Queued,
            BufferState::Queued,
            "same states must be equal"
        );
        assert_ne!(
            BufferState::Queued,
            BufferState::Dequeued,
            "different states must not be equal"
        );
    }
}
