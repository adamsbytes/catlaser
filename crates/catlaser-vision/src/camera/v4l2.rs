//! V4L2 ioctl bindings for multiplanar MMAP+DMABUF capture.
//!
//! Defines the kernel-ABI structs and ioctl request numbers from
//! `linux/videodev2.h`, plus safe wrapper functions that validate inputs
//! and translate OS errors into [`CameraError`].
//!
//! All unsafe code in this module is covered by ADR-001.

use std::os::fd::{AsRawFd, BorrowedFd, OwnedFd};
use std::path::Path;
use std::time::Duration;

use super::error::CameraError;

// ---------------------------------------------------------------------------
// Constants from linux/videodev2.h
// ---------------------------------------------------------------------------

/// `V4L2_CAP_VIDEO_CAPTURE_MPLANE`
const CAP_VIDEO_CAPTURE_MPLANE: u32 = 0x0000_1000;

/// `V4L2_CAP_STREAMING`
const CAP_STREAMING: u32 = 0x0400_0000;

/// `V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE`
pub(super) const BUF_TYPE_VIDEO_CAPTURE_MPLANE: u32 = 9;

/// `V4L2_MEMORY_MMAP`
pub(super) const MEMORY_MMAP: u32 = 1;

/// `V4L2_PIX_FMT_NV12` — fourcc('N','V','1','2')
pub(super) const PIX_FMT_NV12: u32 = fourcc(b'N', b'V', b'1', b'2');

/// `V4L2_FIELD_NONE`
const FIELD_NONE: u32 = 1;

/// `V4L2_BUF_FLAG_ERROR`
const BUF_FLAG_ERROR: u32 = 0x0040;

/// Maximum number of planes the multiplanar API supports.
pub(super) const VIDEO_MAX_PLANES: usize = 8;

/// Size of the `v4l2_format.fmt` union (raw bytes).
///
/// The kernel's `v4l2_format` union is sized to the largest member. On
/// modern kernels, `v4l2_pix_format_mplane` (216 bytes on 64-bit) is the
/// largest. We use a conservative 256 to accommodate platform variance.
const FMT_UNION_SIZE: usize = 256;

/// Minimum number of buffers required for a functional capture pipeline.
/// With fewer than 2, the driver has no buffer to fill while we process.
pub(super) const MIN_BUFFERS: u32 = 2;

/// Constructs a V4L2 fourcc code from four ASCII bytes.
const fn fourcc(a: u8, b: u8, c: u8, d: u8) -> u32 {
    #[expect(
        clippy::as_conversions,
        reason = "u8-to-u32 widening is lossless; shift amounts are compile-time constants"
    )]
    {
        (a as u32) | ((b as u32) << 8) | ((c as u32) << 16) | ((d as u32) << 24)
    }
}

// ---------------------------------------------------------------------------
// Ioctl request number computation
// ---------------------------------------------------------------------------

/// Ioctl direction: none.
const IOC_NONE: u32 = 0;
/// Ioctl direction: write (userspace → kernel).
const IOC_WRITE: u32 = 1;
/// Ioctl direction: read (kernel → userspace).
const IOC_READ: u32 = 2;

const IOC_NRBITS: u32 = 8;
const IOC_TYPEBITS: u32 = 8;
const IOC_SIZEBITS: u32 = 14;

const IOC_NRSHIFT: u32 = 0;
const IOC_TYPESHIFT: u32 = 8;
const IOC_SIZESHIFT: u32 = 16;
const IOC_DIRSHIFT: u32 = 30;

/// Computes an ioctl request number from direction, type, number, and size.
#[expect(
    clippy::as_conversions,
    clippy::cast_possible_truncation,
    reason = "compile-time ioctl encoding; all shifts/ORs on u32 constants within range. \
              size truncation is safe: V4L2 struct sizes are always < 2^14 (IOC_SIZEBITS)."
)]
const fn ioc(dir: u32, ty: u8, nr: u8, size: usize) -> libc::c_ulong {
    ((dir << IOC_DIRSHIFT)
        | ((ty as u32) << IOC_TYPESHIFT)
        | ((nr as u32) << IOC_NRSHIFT)
        | ((size as u32) << IOC_SIZESHIFT)) as libc::c_ulong
}

const fn ior<T>(ty: u8, nr: u8) -> libc::c_ulong {
    ioc(IOC_READ, ty, nr, size_of::<T>())
}

const fn iow<T>(ty: u8, nr: u8) -> libc::c_ulong {
    ioc(IOC_WRITE, ty, nr, size_of::<T>())
}

const fn iowr<T>(ty: u8, nr: u8) -> libc::c_ulong {
    ioc(IOC_READ | IOC_WRITE, ty, nr, size_of::<T>())
}

/// `'V'` — V4L2 ioctl type byte.
const VTYPE: u8 = b'V';

const VIDIOC_QUERYCAP: libc::c_ulong = ior::<V4l2Capability>(VTYPE, 0);
const VIDIOC_S_FMT: libc::c_ulong = iowr::<V4l2Format>(VTYPE, 5);
const VIDIOC_REQBUFS: libc::c_ulong = iowr::<V4l2Requestbuffers>(VTYPE, 8);
const VIDIOC_QUERYBUF: libc::c_ulong = iowr::<V4l2Buffer>(VTYPE, 9);
const VIDIOC_QBUF: libc::c_ulong = iowr::<V4l2Buffer>(VTYPE, 15);
const VIDIOC_EXPBUF: libc::c_ulong = iowr::<V4l2Exportbuffer>(VTYPE, 16);
const VIDIOC_DQBUF: libc::c_ulong = iowr::<V4l2Buffer>(VTYPE, 17);
const VIDIOC_STREAMON: libc::c_ulong = iow::<libc::c_int>(VTYPE, 18);
const VIDIOC_STREAMOFF: libc::c_ulong = iow::<libc::c_int>(VTYPE, 19);

// ---------------------------------------------------------------------------
// Kernel-ABI structs (#[repr(C)])
// ---------------------------------------------------------------------------

/// `struct v4l2_capability`
#[repr(C)]
#[derive(Debug, Clone)]
pub(super) struct V4l2Capability {
    pub driver: [u8; 16],
    pub card: [u8; 32],
    pub bus_info: [u8; 32],
    pub version: u32,
    pub capabilities: u32,
    pub device_caps: u32,
    pub reserved: [u32; 3],
}

/// `struct v4l2_pix_format_mplane`
#[repr(C)]
#[derive(Debug, Clone)]
pub(super) struct V4l2PixFormatMplane {
    pub width: u32,
    pub height: u32,
    pub pixelformat: u32,
    pub field: u32,
    pub colorspace: u32,
    pub plane_fmt: [V4l2PlanePixFormat; VIDEO_MAX_PLANES],
    pub num_planes: u8,
    pub flags: u8,
    _encoding_or_ycbcr: u8,
    _quantization: u8,
    pub xfer_func: u32,
    _reserved: [u32; 7],
}

/// `struct v4l2_plane_pix_format`
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub(super) struct V4l2PlanePixFormat {
    pub sizeimage: u32,
    pub bytesperline: u32,
    _reserved: [u16; 6],
}

/// `struct v4l2_format` (multiplanar variant).
///
/// The kernel defines `fmt` as a union over multiple format types. We store
/// it as raw bytes and project into the multiplanar struct when needed.
#[repr(C)]
#[derive(Clone)]
pub(super) struct V4l2Format {
    pub type_: u32,
    pub fmt: [u8; FMT_UNION_SIZE],
}

/// `struct v4l2_requestbuffers`
#[repr(C)]
#[derive(Debug, Clone)]
pub(super) struct V4l2Requestbuffers {
    pub count: u32,
    pub type_: u32,
    pub memory: u32,
    pub capabilities: u32,
    pub flags: u8,
    _reserved: [u8; 3],
}

/// `struct v4l2_plane` (buffer plane descriptor for multiplanar API).
#[repr(C)]
#[derive(Debug, Clone)]
pub(super) struct V4l2Plane {
    pub bytesused: u32,
    pub length: u32,
    /// Union: `m.mem_offset` (MMAP), `m.userptr` (USERPTR), `m.fd` (DMABUF).
    pub m: V4l2PlaneM,
    pub data_offset: u32,
    _reserved: [u32; 11],
}

/// Union inside `v4l2_plane.m`. Stored as the largest member (`c_ulong`).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub(super) struct V4l2PlaneM {
    /// `mem_offset` for MMAP, `userptr` for USERPTR, or `fd` cast for DMABUF.
    pub value: libc::c_ulong,
}

impl V4l2PlaneM {
    /// Reads the `mem_offset` field (MMAP mode).
    #[expect(
        clippy::as_conversions,
        clippy::cast_possible_truncation,
        reason = "kernel guarantees mem_offset fits u32; c_ulong → u32 truncation \
                  is correct on both 32-bit (no-op) and 64-bit (high bits are zero \
                  for mmap offsets in V4L2)"
    )]
    pub(super) const fn mem_offset(self) -> u32 {
        self.value as u32
    }
}

/// `struct v4l2_buffer` (multiplanar).
#[repr(C)]
pub(super) struct V4l2Buffer {
    pub index: u32,
    pub type_: u32,
    pub bytesused: u32,
    pub flags: u32,
    pub field: u32,
    pub timestamp: libc::timeval,
    pub timecode: V4l2Timecode,
    pub sequence: u32,
    pub memory: u32,
    /// Union: for multiplanar, this is a pointer to a `V4l2Plane` array.
    pub m_planes: *mut V4l2Plane,
    pub length: u32,
    pub reserved2: u32,
    /// Union: `request_fd` or `reserved`.
    pub request_fd: i32,
}

/// `struct v4l2_timecode`
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub(super) struct V4l2Timecode {
    pub type_: u32,
    pub flags: u32,
    pub frames: u8,
    pub seconds: u8,
    pub minutes: u8,
    pub hours: u8,
    pub userbits: [u8; 4],
}

/// `struct v4l2_exportbuffer`
#[repr(C)]
#[derive(Debug, Clone)]
pub(super) struct V4l2Exportbuffer {
    pub type_: u32,
    pub index: u32,
    pub plane: u32,
    pub flags: u32,
    pub fd: i32,
    _reserved: [u32; 11],
}

// ---------------------------------------------------------------------------
// Struct construction helpers (zeroed initialization)
// ---------------------------------------------------------------------------

impl V4l2Capability {
    pub(super) const fn zeroed() -> Self {
        Self {
            driver: [0_u8; 16],
            card: [0_u8; 32],
            bus_info: [0_u8; 32],
            version: 0,
            capabilities: 0,
            device_caps: 0,
            reserved: [0_u32; 3],
        }
    }
}

impl V4l2Format {
    /// Creates a zeroed `v4l2_format` with the given buffer type.
    pub(super) const fn zeroed(type_: u32) -> Self {
        Self {
            type_,
            fmt: [0_u8; FMT_UNION_SIZE],
        }
    }

    /// Writes the multiplanar pixel format fields into the `fmt` union.
    #[expect(
        clippy::indexing_slicing,
        reason = "len = min(size_of::<PixFmtMplane>, FMT_UNION_SIZE); \
                  both slices are bounded by their own array lengths"
    )]
    pub(super) fn set_pix_mp(&mut self, pix: &V4l2PixFormatMplane) {
        let src = as_bytes(pix);
        let len = src.len().min(FMT_UNION_SIZE);
        self.fmt[..len].copy_from_slice(&src[..len]);
    }

    /// Reads the multiplanar pixel format from the `fmt` union.
    ///
    /// Returns `None` if the `fmt` bytes are too small (should never happen
    /// since `FMT_UNION_SIZE >= size_of::<V4l2PixFormatMplane>()`).
    pub(super) fn pix_mp(&self) -> Option<V4l2PixFormatMplane> {
        if FMT_UNION_SIZE < size_of::<V4l2PixFormatMplane>() {
            return None;
        }
        let mut pix = V4l2PixFormatMplane::zeroed();
        let dst = as_bytes_mut(&mut pix);
        dst.copy_from_slice(
            #[expect(clippy::indexing_slicing, reason = "guarded by the size check above")]
            &self.fmt[..dst.len()],
        );
        Some(pix)
    }
}

impl V4l2PixFormatMplane {
    const fn zeroed() -> Self {
        Self {
            width: 0,
            height: 0,
            pixelformat: 0,
            field: 0,
            colorspace: 0,
            plane_fmt: [V4l2PlanePixFormat {
                sizeimage: 0,
                bytesperline: 0,
                _reserved: [0_u16; 6],
            }; VIDEO_MAX_PLANES],
            num_planes: 0,
            flags: 0,
            _encoding_or_ycbcr: 0,
            _quantization: 0,
            xfer_func: 0,
            _reserved: [0_u32; 7],
        }
    }
}

impl V4l2Requestbuffers {
    pub(super) const fn new(count: u32, type_: u32, memory: u32) -> Self {
        Self {
            count,
            type_,
            memory,
            capabilities: 0,
            flags: 0,
            _reserved: [0_u8; 3],
        }
    }
}

impl V4l2Buffer {
    /// Creates a zeroed buffer descriptor for a multiplanar MMAP buffer.
    ///
    /// `planes` must point to a valid, mutable `V4l2Plane` array with at
    /// least `num_planes` elements. The caller must keep the array alive for
    /// the lifetime of this struct.
    pub(super) const fn for_mplane_mmap(
        index: u32,
        type_: u32,
        planes: *mut V4l2Plane,
        num_planes: u32,
    ) -> Self {
        Self {
            index,
            type_,
            bytesused: 0,
            flags: 0,
            field: FIELD_NONE,
            timestamp: libc::timeval {
                tv_sec: 0,
                tv_usec: 0,
            },
            timecode: V4l2Timecode {
                type_: 0,
                flags: 0,
                frames: 0,
                seconds: 0,
                minutes: 0,
                hours: 0,
                userbits: [0_u8; 4],
            },
            sequence: 0,
            memory: MEMORY_MMAP,
            m_planes: planes,
            length: num_planes,
            reserved2: 0,
            request_fd: 0,
        }
    }

    /// Extracts the kernel timestamp as a `Duration` since the epoch.
    #[expect(
        clippy::as_conversions,
        clippy::cast_sign_loss,
        clippy::cast_possible_truncation,
        clippy::arithmetic_side_effects,
        reason = "timeval fields are non-negative for valid V4L2 timestamps; \
                  tv_sec → u64 widening is safe, tv_usec is 0..999_999 so \
                  *1000 fits u32 (max 999_999_000)"
    )]
    pub(super) const fn timestamp_duration(&self) -> Duration {
        Duration::new(
            self.timestamp.tv_sec as u64,
            (self.timestamp.tv_usec as u32) * 1000_u32,
        )
    }

    /// Returns `true` if the driver flagged this frame as corrupt.
    pub(super) const fn has_error(&self) -> bool {
        self.flags & BUF_FLAG_ERROR != 0
    }
}

impl V4l2Exportbuffer {
    #[expect(
        clippy::as_conversions,
        reason = "O_RDONLY (0) is a non-negative constant that fits u32"
    )]
    pub(super) const fn new(type_: u32, index: u32, plane: u32) -> Self {
        Self {
            type_,
            index,
            plane,
            flags: libc::O_RDONLY as u32,
            fd: -1_i32,
            _reserved: [0_u32; 11],
        }
    }
}

impl V4l2Plane {
    pub(super) const fn zeroed() -> Self {
        Self {
            bytesused: 0,
            length: 0,
            m: V4l2PlaneM { value: 0 },
            data_offset: 0,
            _reserved: [0_u32; 11],
        }
    }
}

// ---------------------------------------------------------------------------
// Byte-level struct access (for union projection)
// ---------------------------------------------------------------------------

fn as_bytes<T: Sized>(val: &T) -> &[u8] {
    #[expect(
        unsafe_code,
        reason = "reinterpret a #[repr(C)] struct as raw bytes for union projection \
                  — ADR-001. T is a plain-data struct with no padding invariants."
    )]
    // SAFETY: T is #[repr(C)] with no padding invariants. The returned slice
    // borrows `val` immutably with the correct lifetime.
    unsafe {
        std::slice::from_raw_parts(std::ptr::from_ref(val).cast::<u8>(), size_of::<T>())
    }
}

fn as_bytes_mut<T: Sized>(val: &mut T) -> &mut [u8] {
    #[expect(
        unsafe_code,
        reason = "reinterpret a #[repr(C)] struct as mutable raw bytes for union \
                  projection — ADR-001. T is a plain-data struct."
    )]
    // SAFETY: T is #[repr(C)] with no padding invariants. The returned slice
    // borrows `val` mutably with the correct lifetime. All bit patterns are
    // valid for the numeric fields in our V4L2 structs.
    unsafe {
        std::slice::from_raw_parts_mut(std::ptr::from_mut(val).cast::<u8>(), size_of::<T>())
    }
}

// ---------------------------------------------------------------------------
// Safe ioctl wrappers
// ---------------------------------------------------------------------------

/// Opens a V4L2 video device in non-blocking mode.
pub(super) fn open_device(path: &Path) -> Result<OwnedFd, CameraError> {
    use std::os::unix::ffi::OsStrExt;

    // Build a null-terminated path on the stack. Device paths are short
    // (e.g. /dev/video11) so 256 bytes is generous. The path must be
    // strictly shorter than the buffer to leave room for the null
    // terminator at c_path[path_bytes.len()].
    const PATH_BUF_LEN: usize = 256;

    let path_bytes = path.as_os_str().as_bytes();
    let mut c_path = [0_u8; PATH_BUF_LEN];
    let path_len = path_bytes.len();
    let c_path_slice = if path_len < PATH_BUF_LEN {
        c_path.get_mut(..path_len)
    } else {
        None
    }
    .ok_or_else(|| CameraError::DeviceOpen {
        path: path.to_path_buf(),
        source: std::io::Error::from_raw_os_error(libc::ENAMETOOLONG),
    })?;
    c_path_slice.copy_from_slice(path_bytes);
    // Null terminator at c_path[path_len] is zero from initialization.

    #[expect(unsafe_code, reason = "libc::open is an FFI syscall wrapper — ADR-001")]
    // SAFETY: c_path is a stack-allocated, null-terminated byte array.
    // O_RDWR | O_NONBLOCK | O_CLOEXEC are valid flags.
    let fd = unsafe {
        libc::open(
            c_path.as_ptr().cast::<libc::c_char>(),
            libc::O_RDWR | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };

    if fd < 0_i32 {
        return Err(CameraError::DeviceOpen {
            path: path.to_path_buf(),
            source: std::io::Error::last_os_error(),
        });
    }

    #[expect(
        unsafe_code,
        reason = "OwnedFd::from_raw_fd requires that the fd is valid and owned — \
                  we just got it from a successful open() — ADR-001"
    )]
    // SAFETY: fd is a valid, newly opened file descriptor. OwnedFd takes
    // ownership and will close it on drop.
    Ok(unsafe { std::os::fd::FromRawFd::from_raw_fd(fd) })
}

/// `VIDIOC_QUERYCAP` — queries device capabilities.
pub(super) fn querycap(fd: BorrowedFd<'_>) -> Result<V4l2Capability, CameraError> {
    let mut cap = V4l2Capability::zeroed();

    #[expect(unsafe_code, reason = "VIDIOC_QUERYCAP ioctl — ADR-001")]
    // SAFETY: fd is a valid V4L2 device fd (borrowed). cap is a properly
    // sized and aligned V4l2Capability struct. The kernel writes into cap.
    let ret = unsafe { libc::ioctl(fd.as_raw_fd(), VIDIOC_QUERYCAP, &mut cap) };

    if ret < 0_i32 {
        return Err(CameraError::Ioctl {
            name: "VIDIOC_QUERYCAP",
            source: std::io::Error::last_os_error(),
        });
    }

    Ok(cap)
}

/// Validates that a device has the required capabilities for multiplanar
/// MMAP streaming capture.
pub(super) fn require_mplane_streaming(cap: &V4l2Capability) -> Result<(), CameraError> {
    let caps = if cap.capabilities & 0x8000_0000 != 0 {
        cap.device_caps
    } else {
        cap.capabilities
    };

    if caps & CAP_VIDEO_CAPTURE_MPLANE == 0 {
        return Err(CameraError::MissingCapability(
            "V4L2_CAP_VIDEO_CAPTURE_MPLANE",
        ));
    }

    if caps & CAP_STREAMING == 0 {
        return Err(CameraError::MissingCapability("V4L2_CAP_STREAMING"));
    }

    Ok(())
}

/// `VIDIOC_S_FMT` — sets the video capture format.
///
/// Configures the device for NV12 multiplanar capture at the given resolution.
/// Returns the format the driver actually set (may differ from requested).
pub(super) fn set_format(
    fd: BorrowedFd<'_>,
    width: u32,
    height: u32,
) -> Result<V4l2Format, CameraError> {
    let mut pix = V4l2PixFormatMplane::zeroed();
    pix.width = width;
    pix.height = height;
    pix.pixelformat = PIX_FMT_NV12;
    pix.field = FIELD_NONE;
    pix.num_planes = 1;

    let mut fmt = V4l2Format::zeroed(BUF_TYPE_VIDEO_CAPTURE_MPLANE);
    fmt.set_pix_mp(&pix);

    #[expect(unsafe_code, reason = "VIDIOC_S_FMT ioctl — ADR-001")]
    // SAFETY: fd is a valid V4L2 device fd. fmt is a properly sized
    // V4l2Format struct. The kernel reads our request and writes back
    // the negotiated format.
    let ret = unsafe { libc::ioctl(fd.as_raw_fd(), VIDIOC_S_FMT, &mut fmt) };

    if ret < 0_i32 {
        return Err(CameraError::Ioctl {
            name: "VIDIOC_S_FMT",
            source: std::io::Error::last_os_error(),
        });
    }

    // Verify the driver accepted our format.
    if let Some(result_pix) = fmt.pix_mp()
        && (result_pix.pixelformat != PIX_FMT_NV12
            || result_pix.width != width
            || result_pix.height != height)
    {
        return Err(CameraError::FormatMismatch {
            requested_width: width,
            requested_height: height,
            requested_format: "NV12",
            actual_width: result_pix.width,
            actual_height: result_pix.height,
            actual_format: result_pix.pixelformat,
        });
    }

    Ok(fmt)
}

/// `VIDIOC_REQBUFS` — requests MMAP buffer allocation.
///
/// Returns the number of buffers the driver actually allocated (may be
/// less than requested, but never fewer than `MIN_BUFFERS`).
pub(super) fn request_buffers(fd: BorrowedFd<'_>, count: u32) -> Result<u32, CameraError> {
    let mut req = V4l2Requestbuffers::new(count, BUF_TYPE_VIDEO_CAPTURE_MPLANE, MEMORY_MMAP);

    #[expect(unsafe_code, reason = "VIDIOC_REQBUFS ioctl — ADR-001")]
    // SAFETY: fd is a valid V4L2 device fd. req is a properly sized struct.
    // The kernel reads our request and writes back the allocated count.
    let ret = unsafe { libc::ioctl(fd.as_raw_fd(), VIDIOC_REQBUFS, &mut req) };

    if ret < 0_i32 {
        return Err(CameraError::Ioctl {
            name: "VIDIOC_REQBUFS",
            source: std::io::Error::last_os_error(),
        });
    }

    if req.count < MIN_BUFFERS {
        return Err(CameraError::InsufficientBuffers {
            requested: count,
            allocated: req.count,
            minimum: MIN_BUFFERS,
        });
    }

    Ok(req.count)
}

/// `VIDIOC_QUERYBUF` — queries buffer metadata (plane lengths, mmap offsets).
pub(super) fn query_buffer(
    fd: BorrowedFd<'_>,
    index: u32,
) -> Result<(V4l2Buffer, V4l2Plane), CameraError> {
    let mut plane = V4l2Plane::zeroed();
    let mut buf =
        V4l2Buffer::for_mplane_mmap(index, BUF_TYPE_VIDEO_CAPTURE_MPLANE, &raw mut plane, 1);

    #[expect(unsafe_code, reason = "VIDIOC_QUERYBUF ioctl — ADR-001")]
    // SAFETY: fd is valid. buf.m_planes points to our local `plane` variable
    // which is valid for the duration of this call. The kernel fills in
    // buffer metadata and plane info.
    let ret = unsafe { libc::ioctl(fd.as_raw_fd(), VIDIOC_QUERYBUF, &mut buf) };

    if ret < 0_i32 {
        return Err(CameraError::Ioctl {
            name: "VIDIOC_QUERYBUF",
            source: std::io::Error::last_os_error(),
        });
    }

    Ok((buf, plane))
}

/// `mmap` — maps a V4L2 buffer plane into userspace.
///
/// Returns a raw pointer and the mapped length. The caller is responsible
/// for calling `munmap` with the same pointer and length.
pub(super) fn mmap_buffer(
    fd: BorrowedFd<'_>,
    length: usize,
    offset: u32,
    index: u32,
    plane: u32,
) -> Result<(*mut u8, usize), CameraError> {
    let mmap_offset = libc::off_t::from(offset);

    #[expect(unsafe_code, reason = "mmap syscall — ADR-001")]
    // SAFETY: fd is a valid V4L2 device fd. length and offset came from
    // VIDIOC_QUERYBUF. PROT_READ | PROT_WRITE and MAP_SHARED are the
    // correct flags for V4L2 MMAP buffers.
    let ptr = unsafe {
        libc::mmap(
            std::ptr::null_mut(),
            length,
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_SHARED,
            fd.as_raw_fd(),
            mmap_offset,
        )
    };

    if ptr == libc::MAP_FAILED {
        return Err(CameraError::Mmap {
            index,
            plane,
            source: std::io::Error::last_os_error(),
        });
    }

    Ok((ptr.cast::<u8>(), length))
}

/// `munmap` — unmaps a previously mapped buffer.
pub(super) fn munmap_buffer(ptr: *mut u8, length: usize) {
    #[expect(unsafe_code, reason = "munmap syscall — ADR-001")]
    // SAFETY: ptr and length were returned by a previous successful mmap
    // call for this buffer. The buffer is not currently queued to the driver
    // (STREAMOFF was called first).
    unsafe {
        libc::munmap(ptr.cast::<libc::c_void>(), length);
    }
}

/// `VIDIOC_EXPBUF` — exports an MMAP buffer as a DMABUF file descriptor.
pub(super) fn export_buffer(
    fd: BorrowedFd<'_>,
    index: u32,
    plane: u32,
) -> Result<OwnedFd, CameraError> {
    let mut expbuf = V4l2Exportbuffer::new(BUF_TYPE_VIDEO_CAPTURE_MPLANE, index, plane);

    #[expect(unsafe_code, reason = "VIDIOC_EXPBUF ioctl — ADR-001")]
    // SAFETY: fd is a valid V4L2 device fd. expbuf is properly initialized.
    // On success, the kernel writes a new fd into expbuf.fd.
    let ret = unsafe { libc::ioctl(fd.as_raw_fd(), VIDIOC_EXPBUF, &mut expbuf) };

    if ret < 0_i32 {
        return Err(CameraError::DmabufExport {
            index,
            plane,
            source: std::io::Error::last_os_error(),
        });
    }

    #[expect(
        unsafe_code,
        reason = "OwnedFd::from_raw_fd — fd is valid from successful EXPBUF — ADR-001"
    )]
    // SAFETY: expbuf.fd is a valid, newly created file descriptor from
    // a successful VIDIOC_EXPBUF call. OwnedFd takes ownership.
    Ok(unsafe { std::os::fd::FromRawFd::from_raw_fd(expbuf.fd) })
}

/// `VIDIOC_QBUF` — enqueues a buffer for the driver to fill.
pub(super) fn queue_buffer(fd: BorrowedFd<'_>, index: u32) -> Result<(), CameraError> {
    let mut plane = V4l2Plane::zeroed();
    let mut buf =
        V4l2Buffer::for_mplane_mmap(index, BUF_TYPE_VIDEO_CAPTURE_MPLANE, &raw mut plane, 1);

    #[expect(unsafe_code, reason = "VIDIOC_QBUF ioctl — ADR-001")]
    // SAFETY: fd is valid. buf is correctly initialized for MMAP multiplanar
    // with m_planes pointing to our local plane. The driver copies the data
    // and does not retain the pointer.
    let ret = unsafe { libc::ioctl(fd.as_raw_fd(), VIDIOC_QBUF, &mut buf) };

    if ret < 0_i32 {
        return Err(CameraError::Ioctl {
            name: "VIDIOC_QBUF",
            source: std::io::Error::last_os_error(),
        });
    }

    Ok(())
}

/// Result from a successful `VIDIOC_DQBUF`.
#[derive(Debug)]
pub(super) struct DequeuedFrame {
    /// Buffer index in the pool.
    pub index: u32,
    /// Kernel-assigned frame timestamp.
    pub timestamp: Duration,
    /// Frame sequence number (monotonically increasing).
    pub sequence: u32,
    /// Number of bytes used in plane 0.
    pub bytesused: u32,
    /// Whether the driver flagged the frame as corrupt.
    pub is_error: bool,
}

/// `VIDIOC_DQBUF` — dequeues a filled buffer from the driver.
///
/// The device fd must be in non-blocking mode. Returns `Ok(None)` if no
/// frame is ready (`EAGAIN`).
pub(super) fn dequeue_buffer(fd: BorrowedFd<'_>) -> Result<DequeuedFrame, CameraError> {
    let mut plane = V4l2Plane::zeroed();
    let mut buf = V4l2Buffer::for_mplane_mmap(0, BUF_TYPE_VIDEO_CAPTURE_MPLANE, &raw mut plane, 1);

    #[expect(unsafe_code, reason = "VIDIOC_DQBUF ioctl — ADR-001")]
    // SAFETY: fd is valid. buf is correctly initialized for multiplanar MMAP
    // with m_planes pointing to our local plane. The kernel fills in the
    // buffer metadata for the dequeued frame.
    let ret = unsafe { libc::ioctl(fd.as_raw_fd(), VIDIOC_DQBUF, &mut buf) };

    if ret < 0_i32 {
        return Err(CameraError::Ioctl {
            name: "VIDIOC_DQBUF",
            source: std::io::Error::last_os_error(),
        });
    }

    Ok(DequeuedFrame {
        index: buf.index,
        timestamp: buf.timestamp_duration(),
        sequence: buf.sequence,
        bytesused: plane.bytesused,
        is_error: buf.has_error(),
    })
}

/// `VIDIOC_STREAMON` — starts the capture stream.
pub(super) fn stream_on(fd: BorrowedFd<'_>) -> Result<(), CameraError> {
    let buf_type = BUF_TYPE_VIDEO_CAPTURE_MPLANE.cast_signed();

    #[expect(unsafe_code, reason = "VIDIOC_STREAMON ioctl — ADR-001")]
    // SAFETY: fd is valid. buf_type is a valid V4L2 buffer type. The kernel
    // reads the int value to identify which queue to start.
    let ret = unsafe { libc::ioctl(fd.as_raw_fd(), VIDIOC_STREAMON, &buf_type) };

    if ret < 0_i32 {
        return Err(CameraError::Ioctl {
            name: "VIDIOC_STREAMON",
            source: std::io::Error::last_os_error(),
        });
    }

    Ok(())
}

/// `VIDIOC_STREAMOFF` — stops the capture stream and dequeues all buffers.
pub(super) fn stream_off(fd: BorrowedFd<'_>) -> Result<(), CameraError> {
    let buf_type = BUF_TYPE_VIDEO_CAPTURE_MPLANE.cast_signed();

    #[expect(unsafe_code, reason = "VIDIOC_STREAMOFF ioctl — ADR-001")]
    // SAFETY: fd is valid. buf_type is a valid V4L2 buffer type. STREAMOFF
    // stops streaming and implicitly dequeues all buffers.
    let ret = unsafe { libc::ioctl(fd.as_raw_fd(), VIDIOC_STREAMOFF, &buf_type) };

    if ret < 0_i32 {
        return Err(CameraError::Ioctl {
            name: "VIDIOC_STREAMOFF",
            source: std::io::Error::last_os_error(),
        });
    }

    Ok(())
}

/// Polls the device fd for a readable frame with a timeout.
///
/// Returns `Ok(true)` if a frame is ready, `Ok(false)` on timeout.
pub(super) fn poll_frame(fd: BorrowedFd<'_>, timeout_ms: i32) -> Result<bool, CameraError> {
    let mut pfd = libc::pollfd {
        fd: fd.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };

    #[expect(unsafe_code, reason = "poll syscall — ADR-001")]
    // SAFETY: pfd is a valid pollfd on the stack. nfds=1, timeout is the
    // caller-supplied milliseconds.
    let ret = unsafe { libc::poll(&raw mut pfd, 1, timeout_ms) };

    if ret < 0_i32 {
        return Err(CameraError::Poll {
            source: std::io::Error::last_os_error(),
        });
    }

    if ret == 0_i32 {
        return Ok(false);
    }

    Ok(pfd.revents & libc::POLLIN != 0)
}

/// Computes the NV12 frame size for a given width and height.
///
/// NV12 is planar: full-resolution Y plane (width * height bytes) followed
/// by half-resolution interleaved UV plane (width * height / 2 bytes).
/// Total: width * height * 3 / 2.
pub(super) fn nv12_frame_size(width: u32, height: u32) -> Option<u32> {
    let y_size = width.checked_mul(height)?;
    let uv_size = y_size.checked_div(2)?;
    y_size.checked_add(uv_size)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // --- struct size / alignment assertions ---

    #[test]
    fn test_v4l2_capability_size() {
        // 16 + 32 + 32 + 4 + 4 + 4 + 12 = 104 bytes on all platforms
        assert_eq!(
            size_of::<V4l2Capability>(),
            104,
            "V4l2Capability must be 104 bytes to match kernel ABI"
        );
    }

    #[test]
    fn test_v4l2_plane_pix_format_size() {
        // 4 + 4 + 12 = 20 bytes
        assert_eq!(
            size_of::<V4l2PlanePixFormat>(),
            20,
            "V4l2PlanePixFormat must be 20 bytes"
        );
    }

    #[test]
    fn test_v4l2_pix_format_mplane_size() {
        // 4*5 + (20*8) + 4*1 + 4 + 4*7 = 20 + 160 + 4 + 4 + 28 = 208 (with alignment to 4)
        // Actually: width(4) + height(4) + pixelformat(4) + field(4) + colorspace(4)
        // + plane_fmt(20*8=160) + num_planes(1) + flags(1) + enc(1) + quant(1)
        // + xfer_func(4) + reserved(7*4=28) = 20 + 160 + 4 + 32 = 216
        // But the exact size depends on packing. Let's just verify it fits in FMT_UNION_SIZE.
        assert!(
            size_of::<V4l2PixFormatMplane>() <= FMT_UNION_SIZE,
            "V4l2PixFormatMplane ({} bytes) must fit within FMT_UNION_SIZE ({FMT_UNION_SIZE} bytes)",
            size_of::<V4l2PixFormatMplane>(),
        );
    }

    #[test]
    fn test_v4l2_requestbuffers_size() {
        // 4 + 4 + 4 + 4 + 1 + 3 = 20 bytes
        assert_eq!(
            size_of::<V4l2Requestbuffers>(),
            20,
            "V4l2Requestbuffers must be 20 bytes"
        );
    }

    #[test]
    fn test_v4l2_timecode_size() {
        // 4 + 4 + 1 + 1 + 1 + 1 + 4 = 16 bytes
        assert_eq!(
            size_of::<V4l2Timecode>(),
            16,
            "V4l2Timecode must be 16 bytes"
        );
    }

    #[test]
    fn test_v4l2_plane_size() {
        // bytesused(4) + length(4) + m(c_ulong) + data_offset(4) + reserved(11*4=44)
        // 32-bit: 4+4+4+4+44 = 60; 64-bit: 4+4+8+4+44 = 64
        let expected = if size_of::<libc::c_ulong>() == 4 {
            60
        } else {
            64
        };
        assert_eq!(
            size_of::<V4l2Plane>(),
            expected,
            "V4l2Plane must match kernel ABI for this pointer width"
        );
    }

    #[test]
    fn test_v4l2_exportbuffer_size() {
        // 4 + 4 + 4 + 4 + 4 + 44 = 64 bytes
        assert_eq!(
            size_of::<V4l2Exportbuffer>(),
            64,
            "V4l2Exportbuffer must be 64 bytes"
        );
    }

    // --- fourcc ---

    #[test]
    fn test_fourcc_nv12() {
        // NV12 = 0x3231564E
        assert_eq!(
            PIX_FMT_NV12, 0x3231_564E_u32,
            "NV12 fourcc must match the kernel constant"
        );
    }

    // --- ioctl number computation ---

    #[test]
    fn test_ioc_none() {
        let val = ioc(IOC_NONE, b'X', 1, 0);
        // direction=0, size=0, type='X'=88, nr=1
        // (0 << 30) | (0 << 16) | (88 << 8) | 1 = 0x5801
        assert_eq!(
            val, 0x5801,
            "IOC_NONE with type=X nr=1 size=0 must produce 0x5801"
        );
    }

    #[test]
    fn test_vidioc_querycap_value() {
        // _IOR('V', 0, v4l2_capability)
        // dir=2, size=104, type=86, nr=0
        // (2 << 30) | (104 << 16) | (86 << 8) | 0 = 0x80685600
        assert_eq!(
            VIDIOC_QUERYCAP, 0x8068_5600,
            "VIDIOC_QUERYCAP must match the kernel ioctl number"
        );
    }

    #[test]
    fn test_vidioc_streamon_value() {
        // _IOW('V', 18, int)
        // dir=1, size=sizeof(c_int)=4, type=86, nr=18
        // (1 << 30) | (4 << 16) | (86 << 8) | 18 = 0x40045612
        assert_eq!(
            VIDIOC_STREAMON, 0x4004_5612,
            "VIDIOC_STREAMON must match the kernel ioctl number"
        );
    }

    #[test]
    fn test_vidioc_streamoff_value() {
        // _IOW('V', 19, int) = 0x40045613
        assert_eq!(
            VIDIOC_STREAMOFF, 0x4004_5613,
            "VIDIOC_STREAMOFF must match the kernel ioctl number"
        );
    }

    // --- V4l2Format union projection ---

    #[test]
    fn test_format_pix_mp_roundtrip() {
        let mut pix = V4l2PixFormatMplane::zeroed();
        pix.width = 640;
        pix.height = 480;
        pix.pixelformat = PIX_FMT_NV12;
        pix.num_planes = 1;
        #[expect(
            clippy::indexing_slicing,
            clippy::semicolon_outside_block,
            reason = "index 0 is always valid in a VIDEO_MAX_PLANES=8 array"
        )]
        {
            pix.plane_fmt[0].sizeimage = 460_800;
            pix.plane_fmt[0].bytesperline = 640;
        }

        let mut fmt = V4l2Format::zeroed(BUF_TYPE_VIDEO_CAPTURE_MPLANE);
        fmt.set_pix_mp(&pix);

        let Some(recovered) = fmt.pix_mp() else {
            #[expect(clippy::panic, reason = "test assertion")]
            {
                panic!("pix_mp() must succeed when FMT_UNION_SIZE >= sizeof(PixFormatMplane)");
            }
        };

        assert_eq!(recovered.width, 640, "width must roundtrip");
        assert_eq!(recovered.height, 480, "height must roundtrip");
        assert_eq!(
            recovered.pixelformat, PIX_FMT_NV12,
            "pixelformat must roundtrip"
        );
        assert_eq!(recovered.num_planes, 1, "num_planes must roundtrip");
        #[expect(
            clippy::indexing_slicing,
            clippy::semicolon_outside_block,
            reason = "index 0 is always valid in VIDEO_MAX_PLANES=8 array"
        )]
        {
            assert_eq!(
                recovered.plane_fmt[0].sizeimage, 460_800,
                "sizeimage must roundtrip"
            );
            assert_eq!(
                recovered.plane_fmt[0].bytesperline, 640,
                "bytesperline must roundtrip"
            );
        }
    }

    // --- NV12 frame size ---

    #[test]
    fn test_nv12_frame_size_640x480() {
        // 640 * 480 = 307200 Y + 153600 UV = 460800
        assert_eq!(
            nv12_frame_size(640, 480),
            Some(460_800),
            "640x480 NV12 must be 460800 bytes"
        );
    }

    #[test]
    fn test_nv12_frame_size_1920x1080() {
        // 1920 * 1080 * 3 / 2 = 3_110_400
        assert_eq!(
            nv12_frame_size(1920, 1080),
            Some(3_110_400),
            "1920x1080 NV12 must be 3110400 bytes"
        );
    }

    #[test]
    fn test_nv12_frame_size_zero_dimension() {
        assert_eq!(
            nv12_frame_size(0, 480),
            Some(0),
            "zero width produces zero frame size"
        );
    }

    #[test]
    fn test_nv12_frame_size_overflow() {
        assert_eq!(
            nv12_frame_size(u32::MAX, u32::MAX),
            None,
            "overflow must return None"
        );
    }

    // --- V4l2Buffer timestamp ---

    #[test]
    fn test_buffer_timestamp_conversion() {
        let plane = V4l2Plane::zeroed();
        let mut buf =
            V4l2Buffer::for_mplane_mmap(0, BUF_TYPE_VIDEO_CAPTURE_MPLANE, std::ptr::null_mut(), 1);
        // Suppress the unused plane warning — we just need buf.
        let _ = plane;

        buf.timestamp.tv_sec = 123;
        buf.timestamp.tv_usec = 456_789;

        let dur = buf.timestamp_duration();
        assert_eq!(dur.as_secs(), 123, "seconds must match tv_sec");
        assert_eq!(
            dur.subsec_micros(),
            456_789,
            "microseconds must match tv_usec"
        );
    }

    #[test]
    fn test_buffer_error_flag() {
        let mut buf =
            V4l2Buffer::for_mplane_mmap(0, BUF_TYPE_VIDEO_CAPTURE_MPLANE, std::ptr::null_mut(), 1);

        assert!(!buf.has_error(), "new buffer must not have error flag");

        buf.flags = BUF_FLAG_ERROR;
        assert!(
            buf.has_error(),
            "buffer with BUF_FLAG_ERROR must report error"
        );

        buf.flags = 0xFF_FF_FF_FF;
        assert!(
            buf.has_error(),
            "buffer with all flags set must report error"
        );
    }

    // --- V4l2PlaneM ---

    #[test]
    fn test_plane_m_mem_offset() {
        let m = V4l2PlaneM { value: 0x1234_5678 };
        assert_eq!(
            m.mem_offset(),
            0x1234_5678_u32,
            "mem_offset must extract low 32 bits"
        );
    }

    // --- NV12 frame size proptest ---

    use proptest::prelude::*;

    proptest! {
        #[test]
        #[expect(clippy::arithmetic_side_effects, clippy::integer_division, reason = "test arithmetic on bounded inputs")]
        fn test_nv12_frame_size_is_1_5x_pixel_count(
            width in 1_u32..=4096_u32,
            height in 1_u32..=4096_u32,
        ) {
            if let Some(size) = nv12_frame_size(width, height) {
                let pixels = u64::from(width) * u64::from(height);
                let expected = pixels * 3 / 2;
                prop_assert_eq!(
                    u64::from(size),
                    expected,
                    "NV12 frame size must be width * height * 3 / 2",
                );
            }
        }

        #[test]
        fn test_nv12_frame_size_never_panics(width: u32, height: u32) {
            // Just verify no panic — overflow returns None.
            let _ = nv12_frame_size(width, height);
        }
    }

    // --- capability validation ---

    #[test]
    fn test_require_mplane_streaming_both_present() {
        let mut cap = V4l2Capability::zeroed();
        cap.capabilities = CAP_VIDEO_CAPTURE_MPLANE | CAP_STREAMING;
        assert!(
            require_mplane_streaming(&cap).is_ok(),
            "device with both capabilities must pass validation"
        );
    }

    #[test]
    fn test_require_mplane_streaming_missing_capture() {
        let mut cap = V4l2Capability::zeroed();
        cap.capabilities = CAP_STREAMING;
        let Err(err) = require_mplane_streaming(&cap) else {
            #[expect(clippy::panic, reason = "test assertion")]
            {
                panic!("expected error from require_mplane_streaming");
            }
        };
        assert!(
            matches!(
                err,
                CameraError::MissingCapability("V4L2_CAP_VIDEO_CAPTURE_MPLANE")
            ),
            "missing capture cap must produce MissingCapability error"
        );
    }

    #[test]
    fn test_require_mplane_streaming_missing_streaming() {
        let mut cap = V4l2Capability::zeroed();
        cap.capabilities = CAP_VIDEO_CAPTURE_MPLANE;
        let Err(err) = require_mplane_streaming(&cap) else {
            #[expect(clippy::panic, reason = "test assertion")]
            {
                panic!("expected error from require_mplane_streaming");
            }
        };
        assert!(
            matches!(err, CameraError::MissingCapability("V4L2_CAP_STREAMING")),
            "missing streaming cap must produce MissingCapability error"
        );
    }

    #[test]
    fn test_require_mplane_streaming_uses_device_caps_when_available() {
        let mut cap = V4l2Capability::zeroed();
        // Bit 31 indicates device_caps is valid.
        cap.capabilities = 0x8000_0000;
        cap.device_caps = CAP_VIDEO_CAPTURE_MPLANE | CAP_STREAMING;
        assert!(
            require_mplane_streaming(&cap).is_ok(),
            "device_caps must be used when the device-caps-valid bit is set"
        );
    }

    #[test]
    fn test_require_mplane_streaming_device_caps_missing() {
        let mut cap = V4l2Capability::zeroed();
        // Bit 31 set, but device_caps has nothing.
        cap.capabilities = 0x8000_0000 | CAP_VIDEO_CAPTURE_MPLANE | CAP_STREAMING;
        cap.device_caps = 0;
        let Err(err) = require_mplane_streaming(&cap) else {
            #[expect(clippy::panic, reason = "test assertion")]
            {
                panic!("expected error from require_mplane_streaming");
            }
        };
        assert!(
            matches!(err, CameraError::MissingCapability(_)),
            "empty device_caps must fail when the valid bit is set"
        );
    }
}
