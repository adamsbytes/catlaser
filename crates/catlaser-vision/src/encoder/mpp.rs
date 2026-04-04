//! RKMPI VENC FFI bindings for H.264 hardware encoding on the RV1106.
//!
//! Wraps `librkmpi.so` (Rockchip RKMPI multimedia framework) via `libloading`
//! for runtime dynamic loading. Provides C-ABI struct definitions matching
//! `rk_mpi_venc.h` and safe wrapper functions.
//!
//! All unsafe code in this module requires an ADR before use. The FFI
//! boundary is isolated here; the rest of the encoder module operates on
//! safe Rust types.

use std::ffi::c_void;
use std::path::Path;

use super::EncoderConfig;
use super::error::EncoderError;

// ---------------------------------------------------------------------------
// RKMPI constants from rk_mpi_venc.h
// ---------------------------------------------------------------------------

/// Successful return code from all RKMPI calls.
const RK_SUCCESS: i32 = 0;

/// `RK_VIDEO_ID_AVC` — H.264 encoding type.
const RK_VIDEO_ID_AVC: u32 = 0x0008_0000;

/// `H264E_PROFILE_BASELINE` — Constrained Baseline Profile for WebRTC.
const H264E_PROFILE_BASELINE: u32 = 0;

/// `VENC_RC_MODE_H264CBR` — Constant Bitrate rate control.
const VENC_RC_MODE_H264CBR: u32 = 1;

/// `VENC_NALU_H264_IDR` — IDR frame type.
pub(super) const NALU_TYPE_IDR: u32 = 5;

/// `VENC_NALU_H264_SPS` — SPS NAL unit type.
pub(super) const NALU_TYPE_SPS: u32 = 7;

/// `VENC_NALU_H264_PPS` — PPS NAL unit type.
pub(super) const NALU_TYPE_PPS: u32 = 8;

/// Default VENC channel used for the live stream.
pub(super) const DEFAULT_CHANNEL: i32 = 0;

/// Timeout for `RK_MPI_VENC_GetStream` in milliseconds.
/// One frame at 15 FPS is ~67ms. 200ms gives generous headroom.
const GET_STREAM_TIMEOUT_MS: i32 = 200;

// ---------------------------------------------------------------------------
// C-ABI structs from rk_mpi_venc.h (#[repr(C)])
// ---------------------------------------------------------------------------

/// `VENC_ATTR_S` — encoder attribute configuration.
#[repr(C)]
#[derive(Debug, Clone)]
pub(super) struct VencAttr {
    pub enc_type: u32,
    pub max_pic_width: u32,
    pub max_pic_height: u32,
    pub pic_width: u32,
    pub pic_height: u32,
    pub vir_width: u32,
    pub vir_height: u32,
    pub buf_size: u32,
    pub profile: u32,
    pub is_by_frame: u32,
    pub pic_format: u32,
    _reserved: [u32; 16],
}

/// `VENC_RC_ATTR_S` — rate control attribute configuration.
#[repr(C)]
#[derive(Debug, Clone)]
pub(super) struct VencRcAttr {
    pub rc_mode: u32,
    /// CBR target bitrate in kbps.
    pub bit_rate: u32,
    /// CBR max bitrate in kbps.
    pub max_bit_rate: u32,
    /// CBR min bitrate in kbps.
    pub min_bit_rate: u32,
    pub src_frame_rate_num: u32,
    pub src_frame_rate_den: u32,
    pub dst_frame_rate_num: u32,
    pub dst_frame_rate_den: u32,
    pub gop: u32,
    pub stat_time: u32,
    pub first_frame_start_qp: u32,
    _reserved: [u32; 16],
}

/// `VENC_CHN_ATTR_S` — combined channel attributes for creation.
#[repr(C)]
#[derive(Debug, Clone)]
pub(super) struct VencChnAttr {
    pub venc: VencAttr,
    pub rc: VencRcAttr,
    _gop: [u8; 128],
}

/// `MB_BLK` — media buffer block handle (opaque pointer).
pub(super) type MbBlk = *mut c_void;

/// `VIDEO_FRAME_INFO_S` — frame input descriptor for the encoder.
#[repr(C)]
pub(super) struct VideoFrameInfo {
    pub width: u32,
    pub height: u32,
    pub vir_width: u32,
    pub vir_height: u32,
    pub pixel_format: u32,
    pub mb_blk: MbBlk,
    pub(super) _reserved: [u8; 128],
}

/// `VENC_PACK_S` — single NAL unit packet in an encoded stream.
#[repr(C)]
pub(super) struct VencPack {
    /// Media buffer handle containing the encoded data.
    pub mb_blk: MbBlk,
    /// Byte length of the encoded data.
    pub len: u32,
    /// Byte offset into the buffer.
    pub offset: u32,
    /// NAL unit type (IDR, SPS, PPS, etc.).
    pub data_type: u32,
    pub(super) _reserved: [u8; 64],
}

/// `VENC_STREAM_S` — container for one or more encoded NAL unit packets.
#[repr(C)]
pub(super) struct VencStream {
    /// Pointer to array of `VencPack` structs.
    pub pack: *mut VencPack,
    /// Number of packs in the array.
    pub pack_count: u32,
    /// Sequence number.
    pub seq: u32,
    pub(super) _reserved: [u8; 64],
}

/// `VENC_RECV_PIC_PARAM_S` — parameter for `StartRecvFrame`.
#[repr(C)]
pub(super) struct VencRecvPicParam {
    /// Number of frames to receive. -1 for continuous.
    pub recv_pic_num: i32,
}

// ---------------------------------------------------------------------------
// Function pointer types matching rk_mpi_venc.h signatures
// ---------------------------------------------------------------------------

/// `RK_MPI_SYS_Init() -> RK_S32`
type FnSysInit = extern "C" fn() -> i32;

/// `RK_MPI_SYS_Exit() -> RK_S32`
type FnSysExit = extern "C" fn() -> i32;

/// `RK_MPI_VENC_CreateChn(channel, attr) -> RK_S32`
type FnVencCreateChn = extern "C" fn(i32, *const VencChnAttr) -> i32;

/// `RK_MPI_VENC_DestroyChn(channel) -> RK_S32`
type FnVencDestroyChn = extern "C" fn(i32) -> i32;

/// `RK_MPI_VENC_StartRecvFrame(channel, param) -> RK_S32`
type FnVencStartRecvFrame = extern "C" fn(i32, *const VencRecvPicParam) -> i32;

/// `RK_MPI_VENC_StopRecvFrame(channel) -> RK_S32`
type FnVencStopRecvFrame = extern "C" fn(i32) -> i32;

/// `RK_MPI_VENC_SendFrame(channel, frame, timeout_ms) -> RK_S32`
type FnVencSendFrame = extern "C" fn(i32, *const VideoFrameInfo, i32) -> i32;

/// `RK_MPI_VENC_GetStream(channel, stream, timeout_ms) -> RK_S32`
type FnVencGetStream = extern "C" fn(i32, *mut VencStream, i32) -> i32;

/// `RK_MPI_VENC_ReleaseStream(channel, stream) -> RK_S32`
type FnVencReleaseStream = extern "C" fn(i32, *mut VencStream) -> i32;

/// `RK_MPI_VENC_RequestIDR(channel, instant) -> RK_S32`
type FnVencRequestIdr = extern "C" fn(i32, u32) -> i32;

/// `RK_MPI_MB_Handle2VirAddr(mb_blk) -> void*`
type FnMbHandle2VirAddr = extern "C" fn(MbBlk) -> *const u8;

// ---------------------------------------------------------------------------
// Library handle
// ---------------------------------------------------------------------------

/// Dynamically loaded RKMPI function table.
///
/// Loads `librkmpi.so` at runtime and resolves all required symbols.
/// The library handle is held for the lifetime of this struct — dropping
/// it unloads the library.
pub(super) struct MppLibrary {
    // Keep the library loaded for the lifetime of the function pointers.
    _lib: libloading::Library,
    pub sys_init: FnSysInit,
    pub sys_exit: FnSysExit,
    pub venc_create_chn: FnVencCreateChn,
    pub venc_destroy_chn: FnVencDestroyChn,
    pub venc_start_recv_frame: FnVencStartRecvFrame,
    pub venc_stop_recv_frame: FnVencStopRecvFrame,
    pub venc_send_frame: FnVencSendFrame,
    pub venc_get_stream: FnVencGetStream,
    pub venc_release_stream: FnVencReleaseStream,
    pub venc_request_idr: FnVencRequestIdr,
    pub mb_handle2_vir_addr: FnMbHandle2VirAddr,
}

impl std::fmt::Debug for MppLibrary {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MppLibrary").finish_non_exhaustive()
    }
}

impl MppLibrary {
    /// Load the RKMPI library and resolve all required symbols.
    #[expect(
        unsafe_code,
        reason = "libloading::Library::new and get are unsafe FFI operations — \
                  the library path is caller-controlled and symbol names match \
                  the C headers exactly"
    )]
    pub(super) fn load(path: &Path) -> Result<Self, EncoderError> {
        let lib_path = path.to_path_buf();

        // SAFETY: Loading a shared library is inherently unsafe. The path
        // is provided by the caller (typically a compile-time constant).
        // Symbol resolution validates that the library exports the expected
        // ABI. If the library is ABI-incompatible, symbol lookup fails here
        // rather than at call time.
        let lib = unsafe {
            libloading::Library::new(path).map_err(|source| EncoderError::LibraryLoad {
                path: lib_path.clone(),
                source,
            })?
        };

        macro_rules! load_sym {
            ($name:ident, $symbol:expr) => {{
                // SAFETY: Symbol name matches the C header declaration.
                // The function pointer type is defined above to match the
                // C signature exactly (repr(C) structs, i32 return codes).
                let sym = *unsafe {
                    lib.get::<$name>($symbol)
                        .map_err(|source| EncoderError::Symbol {
                            symbol: std::str::from_utf8($symbol).unwrap_or("<invalid>"),
                            source,
                        })?
                };
                sym
            }};
        }

        Ok(Self {
            sys_init: load_sym!(FnSysInit, b"RK_MPI_SYS_Init\0"),
            sys_exit: load_sym!(FnSysExit, b"RK_MPI_SYS_Exit\0"),
            venc_create_chn: load_sym!(FnVencCreateChn, b"RK_MPI_VENC_CreateChn\0"),
            venc_destroy_chn: load_sym!(FnVencDestroyChn, b"RK_MPI_VENC_DestroyChn\0"),
            venc_start_recv_frame: load_sym!(FnVencStartRecvFrame, b"RK_MPI_VENC_StartRecvFrame\0"),
            venc_stop_recv_frame: load_sym!(FnVencStopRecvFrame, b"RK_MPI_VENC_StopRecvFrame\0"),
            venc_send_frame: load_sym!(FnVencSendFrame, b"RK_MPI_VENC_SendFrame\0"),
            venc_get_stream: load_sym!(FnVencGetStream, b"RK_MPI_VENC_GetStream\0"),
            venc_release_stream: load_sym!(FnVencReleaseStream, b"RK_MPI_VENC_ReleaseStream\0"),
            venc_request_idr: load_sym!(FnVencRequestIdr, b"RK_MPI_VENC_RequestIDR\0"),
            mb_handle2_vir_addr: load_sym!(FnMbHandle2VirAddr, b"RK_MPI_MB_Handle2VirAddr\0"),
            _lib: lib,
        })
    }
}

// ---------------------------------------------------------------------------
// Channel attribute construction
// ---------------------------------------------------------------------------

/// Builds a `VencChnAttr` for H.264 Constrained Baseline Profile with CBR.
pub(super) fn build_channel_attr(config: &EncoderConfig) -> VencChnAttr {
    let venc_attr = VencAttr {
        enc_type: RK_VIDEO_ID_AVC,
        max_pic_width: config.width,
        max_pic_height: config.height,
        pic_width: config.width,
        pic_height: config.height,
        vir_width: config.width,
        vir_height: config.height,
        buf_size: 0,
        profile: H264E_PROFILE_BASELINE,
        is_by_frame: 1,
        pic_format: 0, // NV12
        _reserved: [0_u32; 16],
    };

    let rc_attr = VencRcAttr {
        rc_mode: VENC_RC_MODE_H264CBR,
        bit_rate: config.bitrate_kbps,
        max_bit_rate: config.bitrate_kbps,
        min_bit_rate: config.bitrate_kbps,
        src_frame_rate_num: config.fps,
        src_frame_rate_den: 1,
        dst_frame_rate_num: config.fps,
        dst_frame_rate_den: 1,
        gop: config.gop,
        stat_time: 1,
        first_frame_start_qp: 26,
        _reserved: [0_u32; 16],
    };

    VencChnAttr {
        venc: venc_attr,
        rc: rc_attr,
        _gop: [0_u8; 128],
    }
}

/// Returns the `GET_STREAM_TIMEOUT_MS` constant for use by the safe wrapper.
pub(super) const fn get_stream_timeout_ms() -> i32 {
    GET_STREAM_TIMEOUT_MS
}

/// Returns the `RK_SUCCESS` constant for result checking.
pub(super) const fn success_code() -> i32 {
    RK_SUCCESS
}
