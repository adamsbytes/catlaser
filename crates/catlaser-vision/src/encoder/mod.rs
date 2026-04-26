//! RKMPI VENC hardware H.264 encoder for the RV1106.
//!
//! Provides [`Encoder`] for hardware-accelerated H.264 encoding using the
//! RV1106's dedicated VEPU hardware block via Rockchip's RKMPI VENC API.
//! The library (`librkmpi.so`) is loaded at runtime via `libloading`, so
//! the crate compiles and tests pass on x86 development machines without
//! the target library present.
//!
//! Encoder output is Annex B H.264 (start-code-delimited NAL units).
//! SPS/PPS are cached from the first IDR and prepended to every subsequent
//! IDR for WebRTC compatibility — receivers joining mid-stream need these
//! parameter sets to initialize their decoders.
//!
//! Configuration targets Constrained Baseline Profile with CBR rate control,
//! matching the mandatory-to-implement WebRTC H.264 profile (RFC 7742).

pub(crate) mod error;
mod mpp;

use std::path::PathBuf;
use std::time::Instant;

pub(crate) use error::EncoderError;

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Default path to the RKMPI library on the RV1106 target.
const DEFAULT_LIB_PATH: &str = "/usr/lib/librkmpi.so";

/// Encoder configuration.
#[derive(Debug, Clone)]
pub(crate) struct EncoderConfig {
    /// Path to `librkmpi.so`.
    pub lib_path: PathBuf,
    /// Frame width in pixels.
    pub width: u32,
    /// Frame height in pixels.
    pub height: u32,
    /// Target bitrate in kbps for CBR rate control.
    pub bitrate_kbps: u32,
    /// Frames per second.
    pub fps: u32,
    /// GOP (Group of Pictures) interval in frames. An IDR frame is emitted
    /// every `gop` frames, enabling mid-stream join.
    ///
    /// At 15 fps a GOP of 15 means a one-second IDR cadence. New
    /// subscribers can begin decoding within at most one second of
    /// joining instead of waiting for the next IDR; the small bitrate
    /// uptick from doubling keyframe density is invisible at the
    /// 500 kbps target.
    pub gop: u32,
}

impl Default for EncoderConfig {
    fn default() -> Self {
        Self {
            lib_path: PathBuf::from(DEFAULT_LIB_PATH),
            width: 640,
            height: 480,
            bitrate_kbps: 500,
            fps: 15,
            gop: 15,
        }
    }
}

// ---------------------------------------------------------------------------
// Encoded frame
// ---------------------------------------------------------------------------

/// A single encoded H.264 frame output from the hardware encoder.
///
/// Contains Annex B NAL units (start-code-delimited). For IDR frames,
/// SPS and PPS are prepended for WebRTC decoder initialization.
#[derive(Debug, Clone)]
pub(crate) struct EncodedFrame {
    /// H.264 Annex B bitstream data.
    data: Vec<u8>,
    /// Whether this is a keyframe (IDR).
    keyframe: bool,
    /// Presentation timestamp (monotonic).
    timestamp: Instant,
    /// Encoder sequence number.
    sequence: u64,
}

impl EncodedFrame {
    /// Creates a new encoded frame.
    pub(crate) fn new(data: Vec<u8>, keyframe: bool, timestamp: Instant, sequence: u64) -> Self {
        Self {
            data,
            keyframe,
            timestamp,
            sequence,
        }
    }

    /// The H.264 Annex B bitstream data.
    pub(crate) fn data(&self) -> &[u8] {
        &self.data
    }

    /// Whether this frame is a keyframe (IDR).
    pub(crate) fn keyframe(&self) -> bool {
        self.keyframe
    }

    /// Presentation timestamp.
    pub(crate) fn timestamp(&self) -> Instant {
        self.timestamp
    }

    /// Encoder sequence number.
    pub(crate) fn sequence(&self) -> u64 {
        self.sequence
    }
}

// ---------------------------------------------------------------------------
// SPS/PPS cache
// ---------------------------------------------------------------------------

/// Caches SPS and PPS NAL units from the first IDR frame.
///
/// WebRTC receivers joining mid-stream need SPS/PPS to initialize their
/// decoders. The RKMPI VENC emits them with the first IDR but may omit
/// them on subsequent keyframes. This cache ensures every IDR includes
/// the parameter sets.
#[derive(Debug, Clone, Default)]
pub(crate) struct SpsPpsCache {
    /// Cached SPS NAL unit (including Annex B start code).
    sps: Vec<u8>,
    /// Cached PPS NAL unit (including Annex B start code).
    pps: Vec<u8>,
}

impl SpsPpsCache {
    /// Updates the cache from the NAL units in an IDR frame.
    ///
    /// Scans the Annex B bitstream for SPS and PPS NAL units and stores
    /// them. Called on every IDR frame output — if the encoder includes
    /// them, the cache is refreshed; if not, the previous values are retained.
    pub(crate) fn update_from_bitstream(&mut self, data: &[u8]) {
        let mut offset = 0_usize;
        let len = data.len();

        while offset < len {
            // Find next Annex B start code (0x00 0x00 0x00 0x01).
            let Some(start) = find_start_code(data, offset) else {
                break;
            };

            // NAL unit type is in the lower 5 bits of the first byte after
            // the start code.
            let nal_start = start.saturating_add(4);
            let Some(&nal_header) = data.get(nal_start) else {
                break;
            };
            let nal_type = u32::from(nal_header & 0x1F);

            // Find the end of this NAL unit (next start code or end of data).
            let nal_end = find_start_code(data, nal_start).unwrap_or(len);

            if nal_type == mpp::NALU_TYPE_SPS {
                self.sps.clear();
                if let Some(slice) = data.get(start..nal_end) {
                    self.sps.extend_from_slice(slice);
                }
            } else if nal_type == mpp::NALU_TYPE_PPS {
                self.pps.clear();
                if let Some(slice) = data.get(start..nal_end) {
                    self.pps.extend_from_slice(slice);
                }
            }

            offset = nal_end;
        }
    }

    /// Returns the cached SPS data, if any.
    pub(crate) fn sps(&self) -> &[u8] {
        &self.sps
    }

    /// Returns the cached PPS data, if any.
    pub(crate) fn pps(&self) -> &[u8] {
        &self.pps
    }

    /// Whether both SPS and PPS have been cached.
    pub(crate) fn is_complete(&self) -> bool {
        !self.sps.is_empty() && !self.pps.is_empty()
    }

    /// Prepends cached SPS/PPS to the given bitstream data.
    ///
    /// Used to ensure every IDR frame includes parameter sets for
    /// WebRTC mid-stream join. Returns the original data if the cache
    /// is incomplete.
    pub(crate) fn prepend_to(&self, data: &[u8]) -> Vec<u8> {
        if !self.is_complete() {
            return data.to_vec();
        }

        let total = self
            .sps
            .len()
            .saturating_add(self.pps.len())
            .saturating_add(data.len());
        let mut out = Vec::with_capacity(total);
        out.extend_from_slice(&self.sps);
        out.extend_from_slice(&self.pps);
        out.extend_from_slice(data);
        out
    }
}

/// Finds the next Annex B start code (`0x00 0x00 0x00 0x01`) at or after
/// `offset` in `data`. Returns the byte index of the first `0x00`.
fn find_start_code(data: &[u8], offset: usize) -> Option<usize> {
    let search = data.get(offset..)?;
    search
        .windows(4)
        .position(|w| w == [0x00, 0x00, 0x00, 0x01])
        .map(|pos| pos.saturating_add(offset))
}

// ---------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------

/// Hardware H.264 encoder using the RV1106's RKMPI VENC API.
///
/// Initialized lazily — the RKMPI library is loaded and the VENC channel
/// is created when [`init`](Self::init) is called. The encoder accepts
/// NV12 frames and produces Annex B H.264 bitstream output.
///
/// On `Drop`, the VENC channel is stopped and destroyed, and `RK_MPI_SYS_Exit`
/// is called to release hardware resources.
#[derive(Debug)]
pub(crate) struct Encoder {
    lib: mpp::MppLibrary,
    channel: i32,
    sps_pps: SpsPpsCache,
    sequence: u64,
    config: EncoderConfig,
}

impl Encoder {
    /// Initializes the hardware encoder.
    ///
    /// Loads `librkmpi.so`, initializes the RKMPI system, creates a VENC
    /// channel with H.264 Constrained Baseline Profile / CBR rate control,
    /// and starts receiving frames.
    pub(crate) fn init(config: EncoderConfig) -> Result<Self, EncoderError> {
        let lib = mpp::MppLibrary::load(&config.lib_path)?;

        // Initialize the RKMPI multimedia system.
        let ret = (lib.sys_init)();
        if ret != mpp::success_code() {
            return Err(EncoderError::SysInit { code: ret });
        }

        let channel = mpp::DEFAULT_CHANNEL;
        let attr = mpp::build_channel_attr(&config);

        // Create the VENC channel with H.264 CBP configuration.
        let ret = (lib.venc_create_chn)(channel, &raw const attr);
        if ret != mpp::success_code() {
            let _cleanup = (lib.sys_exit)();
            return Err(EncoderError::CreateChannel { channel, code: ret });
        }

        // Start receiving frames (continuous mode: recv_pic_num = -1).
        let param = mpp::VencRecvPicParam { recv_pic_num: -1 };
        let ret = (lib.venc_start_recv_frame)(channel, &raw const param);
        if ret != mpp::success_code() {
            let _cleanup = (lib.venc_destroy_chn)(channel);
            let _cleanup = (lib.sys_exit)();
            return Err(EncoderError::StartRecv { channel, code: ret });
        }

        Ok(Self {
            lib,
            channel,
            sps_pps: SpsPpsCache::default(),
            sequence: 0_u64,
            config,
        })
    }

    /// Encodes a single NV12 frame.
    ///
    /// Sends the frame to the hardware encoder and retrieves the encoded
    /// H.264 bitstream. For IDR frames, SPS/PPS are cached and prepended
    /// to ensure WebRTC compatibility.
    ///
    /// The `frame_data` pointer and `width`/`height` must correspond to a
    /// valid NV12 buffer (Y plane: width*height bytes, UV plane: width*height/2 bytes).
    #[expect(
        unsafe_code,
        reason = "RKMPI VENC FFI: sending frames and reading encoded packets requires \
                  raw pointer manipulation through the C API. frame_data lifetime is \
                  bounded by this function call. Encoded data is copied out before \
                  releasing the stream."
    )]
    pub(crate) fn encode(
        &mut self,
        frame_data: *const u8,
        width: u32,
        height: u32,
    ) -> Result<EncodedFrame, EncoderError> {
        if width != self.config.width || height != self.config.height {
            return Err(EncoderError::FrameSizeMismatch {
                expected_width: self.config.width,
                expected_height: self.config.height,
                actual_width: width,
                actual_height: height,
            });
        }

        // Build frame descriptor.
        let frame_info = mpp::VideoFrameInfo {
            width,
            height,
            vir_width: width,
            vir_height: height,
            pixel_format: 0, // NV12
            mb_blk: frame_data.cast::<std::ffi::c_void>().cast_mut(),
            _reserved: [0_u8; 128],
        };

        // Send frame to encoder.
        let ret = (self.lib.venc_send_frame)(self.channel, &raw const frame_info, -1);
        if ret != mpp::success_code() {
            return Err(EncoderError::SendFrame {
                channel: self.channel,
                code: ret,
            });
        }

        // Allocate pack buffer for GetStream.
        let mut pack = mpp::VencPack {
            mb_blk: std::ptr::null_mut(),
            len: 0,
            offset: 0,
            data_type: 0,
            _reserved: [0_u8; 64],
        };

        let mut stream = mpp::VencStream {
            pack: &raw mut pack,
            pack_count: 1,
            seq: 0,
            _reserved: [0_u8; 64],
        };

        // Retrieve encoded stream.
        let ret =
            (self.lib.venc_get_stream)(self.channel, &raw mut stream, mpp::get_stream_timeout_ms());
        if ret != mpp::success_code() {
            return Err(EncoderError::GetStream {
                channel: self.channel,
                code: ret,
            });
        }

        // Copy encoded data out of the RKMPI buffer.
        let encoded_data = if !pack.mb_blk.is_null() && pack.len > 0 {
            let vir_addr = (self.lib.mb_handle2_vir_addr)(pack.mb_blk);
            if vir_addr.is_null() {
                let _release = (self.lib.venc_release_stream)(self.channel, &raw mut stream);
                return Err(EncoderError::EmptyPacket {
                    channel: self.channel,
                });
            }
            // SAFETY: vir_addr is a valid pointer returned by mb_handle2_vir_addr.
            // Adding pack.offset stays within the RKMPI buffer allocation.
            let data_ptr = unsafe { vir_addr.add(usize::try_from(pack.offset).unwrap_or(0)) };
            let data_len = usize::try_from(pack.len).unwrap_or(0);
            // SAFETY: vir_addr is a valid CPU-accessible pointer to the RKMPI
            // buffer. data_len is the byte count reported by the encoder.
            // The data is valid until venc_release_stream is called below.
            let slice = unsafe { std::slice::from_raw_parts(data_ptr, data_len) };
            slice.to_vec()
        } else {
            let _release = (self.lib.venc_release_stream)(self.channel, &raw mut stream);
            return Err(EncoderError::EmptyPacket {
                channel: self.channel,
            });
        };

        // Release the RKMPI buffer back to the encoder.
        let _release = (self.lib.venc_release_stream)(self.channel, &raw mut stream);

        let keyframe = pack.data_type == mpp::NALU_TYPE_IDR;

        // Cache and prepend SPS/PPS for IDR frames.
        let final_data = if keyframe {
            self.sps_pps.update_from_bitstream(&encoded_data);
            if self.sps_pps.is_complete() {
                self.sps_pps.prepend_to(&encoded_data)
            } else {
                encoded_data
            }
        } else {
            encoded_data
        };

        let frame = EncodedFrame::new(final_data, keyframe, Instant::now(), self.sequence);
        self.sequence = self.sequence.saturating_add(1_u64);

        Ok(frame)
    }

    /// Requests the encoder to produce an IDR frame on the next encode.
    ///
    /// Called in response to PLI/FIR from the WebRTC receiver.
    pub(crate) fn request_idr(&self) -> Result<(), EncoderError> {
        let ret = (self.lib.venc_request_idr)(self.channel, 1);
        if ret != mpp::success_code() {
            return Err(EncoderError::RequestIdr {
                channel: self.channel,
                code: ret,
            });
        }
        Ok(())
    }

    /// Adjusts the target bitrate for bandwidth adaptation.
    ///
    /// Called when the WebRTC transport signals a bitrate change via
    /// TWCC/REMB feedback.
    pub(crate) fn set_bitrate(&mut self, bitrate_kbps: u32) -> Result<(), EncoderError> {
        self.config.bitrate_kbps = bitrate_kbps;
        // Re-create the channel attribute with the new bitrate and apply.
        // RKMPI requires rebuilding the RC params struct.
        let attr = mpp::build_channel_attr(&self.config);
        let ret = (self.lib.venc_create_chn)(self.channel, &raw const attr);
        if ret != mpp::success_code() {
            return Err(EncoderError::SetRcParam {
                channel: self.channel,
                code: ret,
            });
        }
        Ok(())
    }

    /// Returns the current encoder configuration.
    pub(crate) fn config(&self) -> &EncoderConfig {
        &self.config
    }

    /// Returns the SPS/PPS cache for external use.
    pub(crate) fn sps_pps(&self) -> &SpsPpsCache {
        &self.sps_pps
    }
}

impl Drop for Encoder {
    fn drop(&mut self) {
        let _stop = (self.lib.venc_stop_recv_frame)(self.channel);
        let _destroy = (self.lib.venc_destroy_chn)(self.channel);
        let _exit = (self.lib.sys_exit)();
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // --- EncoderConfig ---

    #[test]
    fn test_default_config() {
        let config = EncoderConfig::default();
        assert_eq!(
            config.lib_path,
            PathBuf::from("/usr/lib/librkmpi.so"),
            "default library path"
        );
        assert_eq!(config.width, 640, "default width");
        assert_eq!(config.height, 480, "default height");
        assert_eq!(config.bitrate_kbps, 500, "default bitrate");
        assert_eq!(config.fps, 15, "default fps");
        assert_eq!(config.gop, 15, "default gop");
    }

    // --- SpsPpsCache ---

    #[test]
    fn test_empty_cache_is_not_complete() {
        let cache = SpsPpsCache::default();
        assert!(!cache.is_complete(), "empty cache should not be complete");
        assert!(cache.sps().is_empty(), "empty SPS");
        assert!(cache.pps().is_empty(), "empty PPS");
    }

    #[test]
    fn test_cache_extracts_sps_pps_from_bitstream() {
        // Construct a minimal Annex B bitstream with SPS (type 7) and PPS (type 8).
        // NAL header byte: forbidden_zero_bit=0, nal_ref_idc=3, nal_unit_type=7|8
        let mut data = Vec::new();

        // SPS NAL: start code + header (type 7) + dummy data
        data.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]);
        data.push(0x67); // 0b0_11_00111 = type 7 (SPS)
        data.extend_from_slice(&[0xAA, 0xBB, 0xCC]);

        // PPS NAL: start code + header (type 8) + dummy data
        data.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]);
        data.push(0x68); // 0b0_11_01000 = type 8 (PPS)
        data.extend_from_slice(&[0xDD, 0xEE]);

        // IDR NAL: start code + header (type 5) + dummy data
        data.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]);
        data.push(0x65); // 0b0_11_00101 = type 5 (IDR)
        data.extend_from_slice(&[0x01, 0x02, 0x03]);

        let mut cache = SpsPpsCache::default();
        cache.update_from_bitstream(&data);

        assert!(
            cache.is_complete(),
            "cache should be complete after SPS+PPS"
        );
        assert_eq!(
            cache.sps(),
            &[0x00, 0x00, 0x00, 0x01, 0x67, 0xAA, 0xBB, 0xCC],
            "SPS should include start code and data"
        );
        assert_eq!(
            cache.pps(),
            &[0x00, 0x00, 0x00, 0x01, 0x68, 0xDD, 0xEE],
            "PPS should include start code and data"
        );
    }

    #[test]
    fn test_cache_prepend_adds_sps_pps_to_idr() {
        let cache = SpsPpsCache {
            sps: vec![0x00, 0x00, 0x00, 0x01, 0x67, 0x42],
            pps: vec![0x00, 0x00, 0x00, 0x01, 0x68, 0xCE],
        };

        let idr = vec![0x00, 0x00, 0x00, 0x01, 0x65, 0x88];
        let result = cache.prepend_to(&idr);

        assert_eq!(
            result,
            vec![
                // SPS
                0x00, 0x00, 0x00, 0x01, 0x67, 0x42, // PPS
                0x00, 0x00, 0x00, 0x01, 0x68, 0xCE, // IDR
                0x00, 0x00, 0x00, 0x01, 0x65, 0x88,
            ],
            "prepend should concatenate SPS+PPS+IDR"
        );
    }

    #[test]
    fn test_cache_prepend_returns_original_when_incomplete() {
        let cache = SpsPpsCache::default();
        let data = vec![0x00, 0x00, 0x00, 0x01, 0x65, 0x88];
        let result = cache.prepend_to(&data);
        assert_eq!(result, data, "incomplete cache should return original data");
    }

    #[test]
    fn test_cache_update_with_no_sps_pps() {
        // Bitstream with only an IDR NAL, no SPS/PPS.
        let data = vec![0x00, 0x00, 0x00, 0x01, 0x65, 0x01, 0x02, 0x03];
        let mut cache = SpsPpsCache::default();
        cache.update_from_bitstream(&data);
        assert!(
            !cache.is_complete(),
            "cache without SPS/PPS should not be complete"
        );
    }

    #[test]
    fn test_cache_update_with_empty_data() {
        let mut cache = SpsPpsCache::default();
        cache.update_from_bitstream(&[]);
        assert!(!cache.is_complete(), "empty data should not complete cache");
    }

    // --- EncodedFrame ---

    #[test]
    fn test_encoded_frame_construction() {
        let data = vec![0x00, 0x00, 0x00, 0x01, 0x65, 0x88];
        let timestamp = Instant::now();
        let frame = EncodedFrame::new(data.clone(), true, timestamp, 42_u64);

        assert_eq!(frame.data(), &data, "frame data");
        assert!(frame.keyframe(), "keyframe flag");
        assert_eq!(frame.timestamp(), timestamp, "timestamp");
        assert_eq!(frame.sequence(), 42_u64, "sequence");
    }

    #[test]
    fn test_encoded_frame_non_keyframe() {
        let data = vec![0x00, 0x00, 0x00, 0x01, 0x41, 0x01];
        let frame = EncodedFrame::new(data, false, Instant::now(), 0_u64);
        assert!(!frame.keyframe(), "non-keyframe flag");
    }

    // --- find_start_code ---

    #[test]
    fn test_find_start_code() {
        let data = [0x00, 0x00, 0x00, 0x01, 0x67, 0x42];
        assert_eq!(
            find_start_code(&data, 0),
            Some(0),
            "start code at beginning"
        );
    }

    #[test]
    fn test_find_start_code_offset() {
        let data = [0xFF, 0xFF, 0x00, 0x00, 0x00, 0x01, 0x67];
        assert_eq!(find_start_code(&data, 0), Some(2), "start code at offset 2");
        assert_eq!(
            find_start_code(&data, 3),
            None,
            "no start code after offset 3"
        );
    }

    #[test]
    fn test_find_start_code_not_found() {
        let data = [0x00, 0x00, 0x00, 0x00, 0x67];
        assert_eq!(
            find_start_code(&data, 0),
            None,
            "0x00000000 is not a start code"
        );
    }

    #[test]
    fn test_find_start_code_empty() {
        assert_eq!(find_start_code(&[], 0), None, "empty data");
    }

    // --- Error display snapshots ---

    #[test]
    fn test_error_display_library_load() {
        let err = EncoderError::LibraryLoad {
            path: PathBuf::from("/usr/lib/librkmpi.so"),
            source: libloading::Error::DlOpenUnknown,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"failed to load RKMPI library from /usr/lib/librkmpi.so: dlopen failed, but system did not report the error"
        );
    }

    #[test]
    fn test_error_display_create_channel() {
        let err = EncoderError::CreateChannel {
            channel: 0_i32,
            code: -1_i32,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"RK_MPI_VENC_CreateChn(0) failed with code -1"
        );
    }

    #[test]
    fn test_error_display_send_frame() {
        let err = EncoderError::SendFrame {
            channel: 0_i32,
            code: -2_i32,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"RK_MPI_VENC_SendFrame(0) failed with code -2"
        );
    }

    #[test]
    fn test_error_display_get_stream() {
        let err = EncoderError::GetStream {
            channel: 0_i32,
            code: -3_i32,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"RK_MPI_VENC_GetStream(0) failed with code -3"
        );
    }

    #[test]
    fn test_error_display_frame_size_mismatch() {
        let err = EncoderError::FrameSizeMismatch {
            expected_width: 640,
            expected_height: 480,
            actual_width: 320,
            actual_height: 240,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"frame size mismatch: encoder configured for 640x480, got 320x240"
        );
    }

    #[test]
    fn test_error_display_empty_packet() {
        let err = EncoderError::EmptyPacket { channel: 0_i32 };
        insta::assert_snapshot!(
            err.to_string(),
            @"encoder returned empty packet on channel 0"
        );
    }

    #[test]
    fn test_error_display_request_idr() {
        let err = EncoderError::RequestIdr {
            channel: 0_i32,
            code: -1_i32,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"RK_MPI_VENC_RequestIDR(0) failed with code -1"
        );
    }

    #[test]
    fn test_error_display_set_rc_param() {
        let err = EncoderError::SetRcParam {
            channel: 0_i32,
            code: -1_i32,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"RK_MPI_VENC_SetRcParam(0) failed with code -1"
        );
    }

    #[test]
    fn test_error_display_sys_init() {
        let err = EncoderError::SysInit { code: -1_i32 };
        insta::assert_snapshot!(err.to_string(), @"RK_MPI_SYS_Init failed with code -1");
    }

    #[test]
    fn test_error_display_start_recv() {
        let err = EncoderError::StartRecv {
            channel: 0_i32,
            code: -1_i32,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"RK_MPI_VENC_StartRecvFrame(0) failed with code -1"
        );
    }
}
