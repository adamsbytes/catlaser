//! Cat re-ID embedding via `MobileNetV2` on the RV1106 NPU.
//!
//! Crops a tracked cat's bounding box from the NV12 camera frame, converts
//! to RGB, resizes to 128x128, runs the embedding model on the NPU, and
//! produces an L2-normalized 128-dimensional vector. Embeddings are averaged
//! over multiple frames before being sent to Python for catalog matching.
//!
//! The embedding model runs at `ModelPriority::Low` so the latency-critical
//! YOLO detection model is never preempted. Re-ID inference (~15 ms) runs
//! only on track confirmation and re-acquisition — a few times per session,
//! not per frame.

use std::collections::HashMap;
use std::path::PathBuf;

use jpeg_encoder::{ColorType, Encoder as JpegEncoder, EncodingError as JpegEncodingError};

use crate::npu::tensor::{QuantType, TensorFormat, dequantize_affine_buffer, nc1hwc2_to_nchw};
use crate::npu::{Model, ModelPriority, NpuConfig};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Default path to the re-ID RKNN model file on the target filesystem.
const DEFAULT_REID_MODEL_PATH: &str = "/opt/catlaser/models/cat_reid_mobilenet.rknn";

/// Embedding model input size (width and height, square crop).
const INPUT_SIZE: u32 = 128;

/// Embedding vector dimensionality.
const EMBEDDING_DIM: usize = 128;

/// Number of frames to average embeddings over before emitting.
const AVERAGING_FRAMES: u32 = 5;

/// C2 channel block size for NC1HWC2 layout on RV1106 INT8 tensors.
const C2_BLOCK: u32 = 16;

/// JPEG quality (0-100) for the cat thumbnail shipped to Python.
///
/// 80 is well into the perceptually-lossless range for a 128×128 photo
/// crop; the resulting payload is ~3-5 KB which is comfortably below
/// any IPC or app data-channel ceiling. Re-ID accuracy is not affected
/// because Python never re-decodes the thumbnail for matching — the
/// embedding vector is the load-bearing artefact.
const THUMBNAIL_JPEG_QUALITY: u8 = 80;

/// Pre-allocated capacity for the per-track thumbnail JPEG byte vector.
/// 8 KB safely covers the 80-quality 128×128 RGB envelope (~3-5 KB
/// payload + JPEG headers) without the writer needing to grow during
/// encoding. Picked to amortise allocation across the typical
/// dispatch cycle (a few new tracks per session, each finalising once).
const THUMBNAIL_JPEG_CAPACITY: usize = 8 * 1024;

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Embedding engine configuration.
#[derive(Debug, Clone)]
pub(crate) struct EmbedConfig {
    /// Path to the `MobileNetV2` `.rknn` model file.
    pub model_path: PathBuf,
    /// NPU runtime configuration (library path).
    pub npu: NpuConfig,
    /// Number of frames to average embeddings over.
    pub averaging_frames: u32,
}

impl Default for EmbedConfig {
    fn default() -> Self {
        Self {
            model_path: PathBuf::from(DEFAULT_REID_MODEL_PATH),
            npu: NpuConfig::default(),
            averaging_frames: AVERAGING_FRAMES,
        }
    }
}

// ---------------------------------------------------------------------------
// Error
// ---------------------------------------------------------------------------

/// Errors from the embedding engine.
#[derive(Debug, thiserror::Error)]
pub(crate) enum EmbedError {
    /// Failed to read the model file from disk.
    #[error("failed to read re-ID model file {path}: {source}")]
    ModelRead {
        /// Filesystem path attempted.
        path: PathBuf,
        /// Underlying OS error.
        source: std::io::Error,
    },

    /// NPU model loading or inference failed.
    #[error("npu: {0}")]
    Npu(#[from] crate::npu::error::NpuError),

    /// The model's output does not match expected embedding dimensions.
    #[error(
        "embedding output mismatch: expected {expected} elements, model produces {actual} \
         (format: {format:?}, type: {data_type:?}, qnt: {qnt_type:?})"
    )]
    OutputMismatch {
        /// Expected element count.
        expected: u32,
        /// Actual element count from the model.
        actual: u32,
        /// Output tensor format.
        format: TensorFormat,
        /// Output tensor data type.
        data_type: crate::npu::tensor::TensorType,
        /// Output tensor quantization type.
        qnt_type: QuantType,
    },

    /// Encoding the embedding crop as a JPEG thumbnail failed.
    ///
    /// Non-fatal at the call site: the engine logs and ships a
    /// completed embedding with an empty thumbnail rather than
    /// dropping the identity match outright. Python tolerates an
    /// empty thumbnail by falling back to a placeholder image in
    /// the iOS naming sheet.
    #[error("jpeg encode of {width}x{height} thumbnail failed: {source}")]
    ThumbnailEncode {
        /// Source crop width in pixels.
        width: u32,
        /// Source crop height in pixels.
        height: u32,
        /// Underlying encoder error.
        source: JpegEncodingError,
    },
}

// ---------------------------------------------------------------------------
// Crop region
// ---------------------------------------------------------------------------

/// Pixel-space crop region within an NV12 frame.
///
/// Coordinates are clamped to frame boundaries. The region is guaranteed
/// non-empty (width >= 1, height >= 1) after construction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct CropRegion {
    /// Left edge (inclusive), in pixels.
    pub x: u32,
    /// Top edge (inclusive), in pixels.
    pub y: u32,
    /// Width in pixels (>= 1).
    pub w: u32,
    /// Height in pixels (>= 1).
    pub h: u32,
}

impl CropRegion {
    /// Computes a crop region from a normalized bounding box `[cx, cy, w, h]`
    /// (each in 0.0-1.0) and frame dimensions.
    ///
    /// The bbox is expanded by 10% on each side to include some context
    /// around the cat (fur edges, posture). The result is clamped to frame
    /// boundaries and guaranteed non-empty.
    #[expect(
        clippy::as_conversions,
        clippy::cast_possible_truncation,
        clippy::cast_precision_loss,
        clippy::cast_sign_loss,
        clippy::arithmetic_side_effects,
        reason = "normalized coords in [0,1] multiplied by frame dims produce values in \
                  [0, frame_dim]; clamped to u32 range before cast. Frame dims are ≤ 4096, \
                  exact in f32 (23-bit mantissa covers integers up to 2^24). Subtraction is \
                  safe because x2 >= x1 and y2 >= y1 after clamping (both derived from the \
                  same base with additive half-widths). Addition of 1 for minimum size \
                  cannot overflow because frame dims are <= 4096."
    )]
    pub(crate) fn from_normalized_bbox(
        bbox: [f32; 4],
        frame_width: u32,
        frame_height: u32,
    ) -> Self {
        let [cx, cy, w, h] = bbox;
        let fw = frame_width as f32;
        let fh = frame_height as f32;

        // Expand bbox by 10% on each side for context.
        let half_w = w * 0.6_f32 * fw;
        let half_h = h * 0.6_f32 * fh;
        let center_x = cx * fw;
        let center_y = cy * fh;

        let x1 = (center_x - half_w).max(0.0_f32) as u32;
        let y1 = (center_y - half_h).max(0.0_f32) as u32;
        let x2 = ((center_x + half_w) as u32).min(frame_width.saturating_sub(1));
        let y2 = ((center_y + half_h) as u32).min(frame_height.saturating_sub(1));

        // Guarantee non-empty: at least 1x1 pixel.
        let crop_w = (x2 - x1).max(1);
        let crop_h = (y2 - y1).max(1);

        Self {
            x: x1,
            y: y1,
            w: crop_w,
            h: crop_h,
        }
    }
}

// ---------------------------------------------------------------------------
// Bilinear sample coordinate computation
// ---------------------------------------------------------------------------

/// Computes source sample coordinates and interpolation weights for one
/// output pixel during bilinear-interpolated crop-and-resize.
///
/// Returns `(x0, y0, x1, y1, xfrac, yfrac)` where `(x0,y0)` and `(x1,y1)`
/// are the integer pixel coordinates of the four neighbors and `xfrac`/`yfrac`
/// are the fractional weights.
#[expect(
    clippy::as_conversions,
    clippy::cast_possible_truncation,
    clippy::cast_precision_loss,
    clippy::cast_sign_loss,
    clippy::arithmetic_side_effects,
    clippy::too_many_arguments,
    reason = "output indices and crop dimensions produce coordinates within frame bounds; \
              clamped to [0, frame_dim) before integer cast. u32 values are <= 4096, \
              exact in f32. 8 args are the minimal decomposition of a 2D bilinear sample: \
              output coords, crop origin, crop size, frame bounds."
)]
fn bilinear_sample_coords(
    out_x: usize,
    out_y: usize,
    crop_x: f32,
    crop_y: f32,
    crop_w: f32,
    crop_h: f32,
    frame_width: u32,
    frame_height: u32,
) -> (u32, u32, u32, u32, f32, f32) {
    let src_col = crop_x + (out_x as f32 + 0.5_f32) * crop_w / INPUT_SIZE as f32 - 0.5_f32;
    let src_row = crop_y + (out_y as f32 + 0.5_f32) * crop_h / INPUT_SIZE as f32 - 0.5_f32;

    let src_col = src_col.clamp(0.0_f32, (frame_width - 1) as f32);
    let src_row = src_row.clamp(0.0_f32, (frame_height - 1) as f32);

    let x0 = src_col as u32;
    let y0 = src_row as u32;
    let x1 = (x0 + 1).min(frame_width - 1);
    let y1 = (y0 + 1).min(frame_height - 1);
    let xfrac = src_col - x0 as f32;
    let yfrac = src_row - y0 as f32;

    (x0, y0, x1, y1, xfrac, yfrac)
}

// ---------------------------------------------------------------------------
// NV12 crop + RGB resize
// ---------------------------------------------------------------------------

/// Extracts a crop from an NV12 frame and resizes to 128x128 RGB in NHWC
/// layout, ready for the NPU.
///
/// NV12 layout: Y plane (width * height bytes) followed by interleaved
/// UV plane (width * height / 2 bytes, with U and V subsampled 2x in both
/// dimensions).
///
/// The resize uses bilinear interpolation for quality. Output is packed
/// `[H, W, C]` with `C=3` (RGB), `u8` values matching the model's expected
/// input normalization (the RKNN conversion pipeline bakes mean/std into
/// the quantized model, so raw 0-255 RGB is correct).
#[expect(
    clippy::as_conversions,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::cast_precision_loss,
    clippy::arithmetic_side_effects,
    clippy::integer_division,
    clippy::indexing_slicing,
    reason = "Image processing arithmetic: all coordinates are bounded by frame dimensions \
              (max 4096x4096). Products fit u32/usize. Float intermediates are pixel \
              coordinates and interpolation weights in [0, frame_dim] — no overflow or \
              precision concerns. Integer division computes UV subsampling (chroma is \
              half resolution in NV12). dst slice is from get_mut on a 3-byte sub-slice \
              so indices 0..2 are guaranteed valid."
)]
fn crop_and_resize_nv12_to_rgb(
    nv12_data: &[u8],
    frame_width: u32,
    frame_height: u32,
    crop: CropRegion,
) -> Vec<u8> {
    let out_w = INPUT_SIZE as usize;
    let out_h = INPUT_SIZE as usize;
    let fw = frame_width as usize;
    let fh = frame_height as usize;
    let y_plane_size = fw * fh;

    let mut rgb = vec![0_u8; out_h * out_w * 3];

    let crop_w = crop.w as f32;
    let crop_h = crop.h as f32;
    let crop_x = crop.x as f32;
    let crop_y = crop.y as f32;

    for out_y in 0..out_h {
        for out_x in 0..out_w {
            // Map output pixel to source coordinate via bilinear sampling.
            let (x0, y0, x1, y1, xfrac, yfrac) = bilinear_sample_coords(
                out_x,
                out_y,
                crop_x,
                crop_y,
                crop_w,
                crop_h,
                frame_width,
                frame_height,
            );

            // Sample Y values (one per pixel).
            let y00 = sample_y(nv12_data, fw, x0 as usize, y0 as usize);
            let y10 = sample_y(nv12_data, fw, x1 as usize, y0 as usize);
            let y01 = sample_y(nv12_data, fw, x0 as usize, y1 as usize);
            let y11 = sample_y(nv12_data, fw, x1 as usize, y1 as usize);
            let y_val = bilerp(y00, y10, y01, y11, xfrac, yfrac);

            // Sample UV values (subsampled 2x in each direction, interleaved).
            let (u00, v00) = sample_uv(nv12_data, fw, y_plane_size, x0 as usize, y0 as usize);
            let (u10, v10) = sample_uv(nv12_data, fw, y_plane_size, x1 as usize, y0 as usize);
            let (u01, v01) = sample_uv(nv12_data, fw, y_plane_size, x0 as usize, y1 as usize);
            let (u11, v11) = sample_uv(nv12_data, fw, y_plane_size, x1 as usize, y1 as usize);
            let u_val = bilerp(u00, u10, u01, u11, xfrac, yfrac);
            let v_val = bilerp(v00, v10, v01, v11, xfrac, yfrac);

            // YUV → RGB (BT.601 full range).
            let (red, green, blue) = yuv_to_rgb(y_val, u_val, v_val);

            let dst_idx = (out_y * out_w + out_x) * 3;
            // dst is a 3-byte slice from get_mut; indices 0..2 are guaranteed.
            if let Some(dst) = rgb.get_mut(dst_idx..dst_idx + 3) {
                dst[0] = red;
                dst[1] = green;
                dst[2] = blue;
            }
        }
    }

    rgb
}

/// Samples a Y-plane value, returning 0.0 for out-of-bounds access.
#[expect(
    clippy::as_conversions,
    clippy::arithmetic_side_effects,
    reason = "pixel indexing: x < frame_width and y < frame_height guaranteed by caller \
              clamping; product fits usize on 32-bit+"
)]
fn sample_y(nv12: &[u8], stride: usize, x: usize, y: usize) -> f32 {
    nv12.get(y * stride + x).map_or(0.0_f32, |&v| f32::from(v))
}

/// Samples interleaved UV values from the NV12 chroma plane.
///
/// NV12 UV plane starts at offset `y_plane_size`. Chroma is subsampled 2x
/// in both dimensions. Each UV pair is stored as `[U, V]` interleaved.
#[expect(
    clippy::as_conversions,
    clippy::arithmetic_side_effects,
    clippy::integer_division,
    reason = "UV subsampling: x/2 and y/2 are standard NV12 chroma indexing. \
              uv_row_offset + uv_x * 2 + 1 is bounded by frame dimensions."
)]
fn sample_uv(nv12: &[u8], stride: usize, y_plane_size: usize, x: usize, y: usize) -> (f32, f32) {
    let uv_y = y / 2;
    let uv_x = x / 2;
    let uv_offset = y_plane_size + uv_y * stride + uv_x * 2;
    let u = nv12.get(uv_offset).map_or(128.0_f32, |&v| f32::from(v));
    let v = nv12.get(uv_offset + 1).map_or(128.0_f32, |&v| f32::from(v));
    (u, v)
}

/// Bilinear interpolation of four corner samples.
#[expect(
    clippy::arithmetic_side_effects,
    reason = "interpolation weights in [0,1] and pixel values in [0,255]; \
              all intermediate results fit f32 without overflow"
)]
fn bilerp(v00: f32, v10: f32, v01: f32, v11: f32, xfrac: f32, yfrac: f32) -> f32 {
    let top = (v10 - v00).mul_add(xfrac, v00);
    let bot = (v11 - v01).mul_add(xfrac, v01);
    (bot - top).mul_add(yfrac, top)
}

/// Converts YUV (BT.601 full range) to RGB, clamped to [0, 255].
#[expect(
    clippy::as_conversions,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::arithmetic_side_effects,
    reason = "standard BT.601 YUV→RGB conversion; output clamped to [0,255] before u8 cast"
)]
fn yuv_to_rgb(luma: f32, chroma_blue: f32, chroma_red: f32) -> (u8, u8, u8) {
    // Shift chroma from [0, 255] to [-128, 127] range.
    let cb_offset = chroma_blue - 128.0_f32;
    let cr_offset = chroma_red - 128.0_f32;

    let red = (1.402_f32)
        .mul_add(cr_offset, luma)
        .clamp(0.0_f32, 255.0_f32) as u8;
    let green = (-0.714_136_f32)
        .mul_add(cr_offset, (-0.344_136_f32).mul_add(cb_offset, luma))
        .clamp(0.0_f32, 255.0_f32) as u8;
    let blue = (1.772_f32)
        .mul_add(cb_offset, luma)
        .clamp(0.0_f32, 255.0_f32) as u8;

    (red, green, blue)
}

// ---------------------------------------------------------------------------
// Embedding extraction
// ---------------------------------------------------------------------------

/// Extracts a 128-dim L2-normalized embedding from raw NPU output.
///
/// Handles both NC1HWC2 (native) and NCHW/NHWC output layouts, with
/// INT8 affine dequantization. The output vector is L2-normalized for
/// cosine similarity comparison.
fn extract_embedding(model: &Model) -> Result<[f32; EMBEDDING_DIM], EmbedError> {
    let output = model.output(0)?;
    let attr = output.attr();

    // Validate output produces exactly EMBEDDING_DIM elements.
    let n_elems = attr.n_elems();
    let expected = u32::try_from(EMBEDDING_DIM).unwrap_or(u32::MAX);
    if n_elems != expected {
        return Err(EmbedError::OutputMismatch {
            expected,
            actual: n_elems,
            format: attr.format(),
            data_type: attr.data_type(),
            qnt_type: attr.qnt_type(),
        });
    }

    let raw_data = output.data();

    // Reorder from NC1HWC2 to flat channel order if needed.
    let ordered = match attr.format() {
        TensorFormat::Nc1hwc2 => {
            // MobileNetV2 embedding output: [1, C1, 1, 1, C2] where C1*C2 >= 128.
            // With C2=16, C1=8 for 128 channels, H=W=1.
            let dims = attr.dims();
            let (h, w, c2) = match dims {
                [_, c1, h, w, c2, ..] if *c1 > 0 => (*h, *w, *c2),
                _ => (1_u32, 1_u32, C2_BLOCK),
            };
            nc1hwc2_to_nchw(raw_data, expected, h, w, c2)
        }
        // NCHW or NHWC with H=W=1 and C=128 — data is already in channel order.
        _ => raw_data.to_vec(),
    };

    // Dequantize INT8 → f32.
    let floats = match attr.qnt_type() {
        QuantType::AffineAsymmetric => dequantize_affine_buffer(&ordered, attr.zp(), attr.scale()),
        // Non-quantized model: reinterpret i8 as raw values.
        _ => ordered.iter().map(|&v| f32::from(v)).collect(),
    };

    // Build fixed-size array.
    let mut embedding = [0.0_f32; EMBEDDING_DIM];
    for (dst, src) in embedding.iter_mut().zip(floats.iter()) {
        *dst = *src;
    }

    // L2-normalize.
    l2_normalize(&mut embedding);

    Ok(embedding)
}

/// L2-normalizes a vector in place. If the norm is zero (degenerate
/// embedding), the vector is left as-is.
#[expect(
    clippy::arithmetic_side_effects,
    reason = "f32 multiply-accumulate for norm computation; division guarded by > epsilon check"
)]
fn l2_normalize(vec: &mut [f32; EMBEDDING_DIM]) {
    let norm_sq: f32 = vec.iter().map(|&v| v * v).sum();
    let norm = norm_sq.sqrt();

    if norm > f32::EPSILON {
        for v in vec.iter_mut() {
            *v /= norm;
        }
    }
}

// ---------------------------------------------------------------------------
// JPEG thumbnail encoding
// ---------------------------------------------------------------------------

/// Encode a packed RGB byte buffer as a baseline JPEG.
///
/// The buffer is the same NHWC RGB tensor the embedding model consumed,
/// so the resulting thumbnail is exactly what the model "saw" — handing
/// the user a thumbnail that does not match the embedding would be
/// confusing and undermine the new-cat naming UX.
///
/// Returns the JPEG byte payload on success. Errors carry the source
/// dimensions for diagnostic context; callers treat encode failures as
/// non-fatal and ship the embedding without a thumbnail (Python falls
/// back to a placeholder image in that case).
pub(crate) fn encode_thumbnail_jpeg(
    rgb: &[u8],
    width: u32,
    height: u32,
) -> Result<Vec<u8>, EmbedError> {
    // JPEG dimensions are 16-bit unsigned per the spec. Surface
    // out-of-range inputs as a structured ThumbnailEncode error
    // (carrying the offending dimensions) rather than a confusing
    // encoder-internal error after pixel data is consumed.
    let (Ok(w16), Ok(h16)) = (u16::try_from(width), u16::try_from(height)) else {
        return Err(EmbedError::ThumbnailEncode {
            width,
            height,
            source: JpegEncodingError::Write(
                "source dimensions exceed the JPEG maximum (65 535)".to_owned(),
            ),
        });
    };

    let mut out = Vec::with_capacity(THUMBNAIL_JPEG_CAPACITY);
    let encoder = JpegEncoder::new(&mut out, THUMBNAIL_JPEG_QUALITY);
    encoder
        .encode(rgb, w16, h16, ColorType::Rgb)
        .map_err(|source| EmbedError::ThumbnailEncode {
            width,
            height,
            source,
        })?;
    Ok(out)
}

// ---------------------------------------------------------------------------
// Pending embedding accumulator
// ---------------------------------------------------------------------------

/// Accumulates embeddings over multiple frames for a single track.
#[derive(Debug)]
struct PendingEmbedding {
    /// Accumulated sum of embedding vectors (element-wise).
    sum: [f32; EMBEDDING_DIM],
    /// Number of embeddings accumulated so far.
    count: u32,
    /// Target number of frames to average over.
    target: u32,
    /// Most recent RGB crop produced for this track (NHWC,
    /// `INPUT_SIZE × INPUT_SIZE × 3` bytes). Empty until the first
    /// inference for this pending entry runs. Encoded to JPEG when
    /// the entry finalises so the thumbnail and the embedding
    /// represent the same crop the model averaged into the vector.
    last_rgb: Vec<u8>,
}

impl PendingEmbedding {
    fn new(target: u32) -> Self {
        Self {
            sum: [0.0_f32; EMBEDDING_DIM],
            count: 0_u32,
            target,
            last_rgb: Vec::new(),
        }
    }

    /// Adds an embedding to the running sum.
    #[expect(
        clippy::arithmetic_side_effects,
        reason = "element-wise f32 addition of L2-normalized vectors (magnitude ~1.0); \
                  count saturating_add is bounded by target (max ~10)"
    )]
    fn accumulate(&mut self, embedding: &[f32; EMBEDDING_DIM]) {
        for (s, &e) in self.sum.iter_mut().zip(embedding.iter()) {
            *s += e;
        }
        self.count = self.count.saturating_add(1_u32);
    }

    /// Replace the retained RGB crop with the latest one.
    ///
    /// Reuses the existing allocation when the buffer is the same
    /// length, which is the steady-state case (every crop is
    /// `INPUT_SIZE × INPUT_SIZE × 3` bytes). On the first call the
    /// vector grows once; subsequent calls overwrite in place.
    fn record_crop(&mut self, rgb: &[u8]) {
        if self.last_rgb.len() == rgb.len() {
            self.last_rgb.copy_from_slice(rgb);
        } else {
            self.last_rgb.clear();
            self.last_rgb.extend_from_slice(rgb);
        }
    }

    /// Borrow the most recent RGB crop, if one has been recorded.
    fn last_crop(&self) -> Option<&[u8]> {
        if self.last_rgb.is_empty() {
            None
        } else {
            Some(&self.last_rgb)
        }
    }

    /// Returns `true` when enough frames have been accumulated.
    fn is_ready(&self) -> bool {
        self.count >= self.target
    }

    /// Computes the averaged, L2-normalized embedding.
    #[expect(
        clippy::arithmetic_side_effects,
        reason = "division by count (checked > 0 by caller via is_ready); \
                  f32 division and subsequent L2 normalization"
    )]
    fn finalize(&self) -> [f32; EMBEDDING_DIM] {
        let mut avg = [0.0_f32; EMBEDDING_DIM];
        let divisor = f32::from(u16::try_from(self.count).unwrap_or(u16::MAX));
        for (a, &s) in avg.iter_mut().zip(self.sum.iter()) {
            *a = s / divisor;
        }
        l2_normalize(&mut avg);
        avg
    }

    /// Computes a confidence score from the accumulated embeddings.
    ///
    /// Uses the L2 norm of the mean as a signal strength metric. More
    /// consistent embeddings across frames yield a higher pre-normalization
    /// norm. The result is clamped to `[0.0, 1.0]`.
    #[expect(
        clippy::arithmetic_side_effects,
        reason = "f32 multiply-accumulate for norm; division by count (> 0 via is_ready)"
    )]
    fn confidence(&self) -> f32 {
        let divisor = f32::from(u16::try_from(self.count).unwrap_or(u16::MAX));
        let mean_norm_sq: f32 = self
            .sum
            .iter()
            .map(|&v| {
                let mean = v / divisor;
                mean * mean
            })
            .sum();
        mean_norm_sq.sqrt().clamp(0.0_f32, 1.0_f32)
    }
}

// ---------------------------------------------------------------------------
// Completed embedding
// ---------------------------------------------------------------------------

/// A completed embedding ready for IPC transmission.
#[derive(Debug, Clone)]
pub(crate) struct CompletedEmbedding {
    /// Track ID this embedding belongs to.
    pub track_id: u32,
    /// L2-normalized 128-dim embedding vector.
    pub embedding: [f32; EMBEDDING_DIM],
    /// Model confidence (average of per-frame max output magnitudes).
    /// Higher values indicate more distinctive features in the crop.
    pub confidence: f32,
    /// JPEG-encoded thumbnail of the cat at the moment the embedding
    /// was finalised (`INPUT_SIZE × INPUT_SIZE` RGB → JPEG, ~3-5 KB).
    /// Empty when JPEG encoding failed — Python tolerates an empty
    /// thumbnail by skipping the `pending_cats` row and falling back
    /// to a placeholder image in the iOS naming sheet.
    pub thumbnail: Vec<u8>,
}

// ---------------------------------------------------------------------------
// Embed engine
// ---------------------------------------------------------------------------

/// `MobileNetV2` cat re-ID embedding engine.
///
/// Manages the NPU model, tracks which track IDs have pending or completed
/// embeddings, and accumulates multi-frame averages.
#[derive(Debug)]
pub(crate) struct EmbedEngine {
    model: Model,
    /// Track IDs currently accumulating embeddings.
    pending: HashMap<u32, PendingEmbedding>,
    /// Embeddings completed this frame, ready for IPC.
    completed: Vec<CompletedEmbedding>,
    /// Number of frames to average over.
    averaging_frames: u32,
    /// Reusable RGB buffer for `crop_and_resize` output.
    rgb_buffer: Vec<u8>,
}

impl EmbedEngine {
    /// Loads the `MobileNetV2` embedding model and initializes the engine.
    #[tracing::instrument(skip_all, fields(model = %config.model_path.display()))]
    pub(crate) fn load(config: &EmbedConfig) -> Result<Self, EmbedError> {
        let model_data =
            std::fs::read(&config.model_path).map_err(|source| EmbedError::ModelRead {
                path: config.model_path.clone(),
                source,
            })?;

        let model = Model::load(&config.npu, &model_data, ModelPriority::Low)?;

        tracing::info!(
            input_size = model.input_attr().size_with_stride(),
            output_count = model.output_count(),
            "re-ID embedding model loaded"
        );

        Ok(Self {
            model,
            pending: HashMap::new(),
            completed: Vec::new(),
            averaging_frames: config.averaging_frames,
            rgb_buffer: Vec::new(),
        })
    }

    /// Registers a track ID for embedding extraction.
    ///
    /// Called on `TrackUpdate::Confirmed` and `TrackUpdate::Reacquired`.
    /// Duplicate registrations for the same track are ignored.
    pub(crate) fn request_embedding(&mut self, track_id: u32) {
        if !self.pending.contains_key(&track_id) {
            self.pending
                .insert(track_id, PendingEmbedding::new(self.averaging_frames));
            tracing::debug!(track_id, "embedding requested");
        }
    }

    /// Returns `true` if any tracks are waiting for embedding extraction.
    pub(crate) fn has_pending(&self) -> bool {
        !self.pending.is_empty()
    }

    /// Returns the set of track IDs with pending embedding requests.
    pub(crate) fn pending_track_ids(&self) -> Vec<u32> {
        self.pending.keys().copied().collect()
    }

    /// Processes one frame of embedding extraction for all pending tracks.
    ///
    /// For each pending track ID, if the track still exists in the provided
    /// list, crops the bbox from the NV12 frame, runs NPU inference, and
    /// accumulates the result. When a track reaches the averaging target,
    /// the completed embedding is moved to the `completed` list.
    ///
    /// `active_tracks` is a list of `(track_id, normalized_bbox)` pairs for
    /// all currently active tracks that have pending embedding requests.
    pub(crate) fn process_frame(
        &mut self,
        nv12_data: &[u8],
        frame_width: u32,
        frame_height: u32,
        active_tracks: &[(u32, [f32; 4])],
    ) {
        // Process each active track that has a pending request.
        // Borrow self.pending and self.model as disjoint fields to avoid
        // conflicting mutable borrows.
        for &(track_id, bbox) in active_tracks {
            let Some(pending) = self.pending.get_mut(&track_id) else {
                continue;
            };

            // Crop and resize to model input.
            let crop = CropRegion::from_normalized_bbox(bbox, frame_width, frame_height);
            self.rgb_buffer =
                crop_and_resize_nv12_to_rgb(nv12_data, frame_width, frame_height, crop);

            // Run NPU inference using the model directly (not via self method)
            // to avoid conflicting mutable borrow with pending.
            match run_embedding_inference(&mut self.model, &self.rgb_buffer, track_id) {
                Ok(embedding) => {
                    pending.accumulate(&embedding);
                    // Retain the RGB crop for thumbnail encoding at
                    // finalise. Recorded only on successful inference
                    // so a malformed crop never produces a thumbnail
                    // for an embedding that failed to accumulate.
                    pending.record_crop(&self.rgb_buffer);
                }
                Err(err) => {
                    tracing::warn!(track_id, %err, "embedding inference failed, skipping frame");
                }
            }
        }

        // Collect completed embeddings.
        let mut done_ids = Vec::new();
        for (&track_id, pending) in &self.pending {
            if pending.is_ready() {
                let embedding = pending.finalize();
                let confidence = pending.confidence();
                let thumbnail = pending
                    .last_crop()
                    .and_then(
                        |rgb| match encode_thumbnail_jpeg(rgb, INPUT_SIZE, INPUT_SIZE) {
                            Ok(bytes) => Some(bytes),
                            Err(err) => {
                                // Non-fatal: ship the embedding without a
                                // thumbnail rather than dropping the
                                // identity. Python tolerates an empty
                                // thumbnail (skips the pending_cats row,
                                // still pushes the FCM notification).
                                tracing::warn!(
                                    track_id,
                                    %err,
                                    "thumbnail encode failed; identity will ship without preview"
                                );
                                None
                            }
                        },
                    )
                    .unwrap_or_default();

                self.completed.push(CompletedEmbedding {
                    track_id,
                    embedding,
                    confidence,
                    thumbnail,
                });
                done_ids.push(track_id);
            }
        }

        // Remove completed tracks from pending.
        for id in &done_ids {
            self.pending.remove(id);
        }

        for completed in &self.completed {
            tracing::info!(
                track_id = completed.track_id,
                confidence = format_args!("{:.3}", completed.confidence),
                thumbnail_bytes = completed.thumbnail.len(),
                "embedding completed"
            );
        }
    }

    /// Drains embeddings completed during the last [`process_frame`] call.
    ///
    /// Returns the completed embeddings and clears the internal list so
    /// they are only yielded once. This prevents duplicate
    /// [`IdentityRequest`](crate::proto::detection::IdentityRequest)
    /// sends on frames where [`process_frame`](Self::process_frame) is
    /// not called (no pending requests remain).
    pub(crate) fn take_completed(&mut self) -> Vec<CompletedEmbedding> {
        std::mem::take(&mut self.completed)
    }

    /// Cancels a pending embedding request (e.g., when a track dies).
    pub(crate) fn cancel(&mut self, track_id: u32) {
        if self.pending.remove(&track_id).is_some() {
            tracing::debug!(track_id, "embedding request cancelled");
        }
    }
}

/// Runs NPU inference on an RGB buffer and extracts the embedding.
///
/// Free function to allow borrowing `model` independently of
/// `EmbedEngine::pending` in `process_frame`.
fn run_embedding_inference(
    model: &mut Model,
    rgb_buffer: &[u8],
    track_id: u32,
) -> Result<[f32; EMBEDDING_DIM], EmbedError> {
    model.set_input(rgb_buffer)?;
    model.run()?;
    let embedding = extract_embedding(model)?;

    tracing::trace!(track_id, "frame embedding extracted");

    Ok(embedding)
}

// ---------------------------------------------------------------------------
// Embedding → protobuf bytes
// ---------------------------------------------------------------------------

/// Serializes a 128-dim f32 embedding into raw bytes (512 bytes, little-endian)
/// for the `IdentityRequest.embedding` proto field.
pub(crate) fn embedding_to_bytes(embedding: &[f32; EMBEDDING_DIM]) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(EMBEDDING_DIM.saturating_mul(4));
    for &v in embedding {
        bytes.extend_from_slice(&v.to_le_bytes());
    }
    bytes
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
#[expect(
    clippy::float_cmp,
    clippy::arithmetic_side_effects,
    clippy::as_conversions,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::integer_division,
    clippy::indexing_slicing,
    clippy::needless_range_loop,
    clippy::absurd_extreme_comparisons,
    clippy::expect_used,
    clippy::unwrap_used,
    clippy::panic,
    reason = "test code: exact float comparisons for known values, arithmetic for test \
              data construction, casts for pixel manipulation in test frames, \
              indexing on known-size test data, range loops for frame construction, \
              u8 <= 255 asserts document proptest invariants. expect/unwrap/panic are \
              the standard test-failure path and surface the failing expectation directly \
              in the test output without obscuring the assertion intent."
)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    // -----------------------------------------------------------------------
    // Test helpers
    // -----------------------------------------------------------------------

    /// Creates a synthetic NV12 frame with known Y/U/V values.
    ///
    /// Y plane: pixel value = `(x + y * width) % 256`.
    /// UV plane: U = 128, V = 128 (achromatic, so RGB = grayscale).
    fn make_nv12_frame(width: u32, height: u32) -> Vec<u8> {
        let w = width as usize;
        let h = height as usize;
        let y_size = w * h;
        let uv_size = w * (h / 2);
        let mut frame = vec![0_u8; y_size + uv_size];

        // Y plane.
        for y in 0..h {
            for x in 0..w {
                frame[y * w + x] = ((x + y * w) % 256) as u8;
            }
        }

        // UV plane: all neutral (128, 128).
        for i in y_size..(y_size + uv_size) {
            frame[i] = 128_u8;
        }

        frame
    }

    /// Creates an NV12 frame with uniform Y value and neutral UV.
    fn make_uniform_nv12(width: u32, height: u32, y_val: u8) -> Vec<u8> {
        let w = width as usize;
        let h = height as usize;
        let y_size = w * h;
        let uv_size = w * (h / 2);
        let mut frame = vec![0_u8; y_size + uv_size];

        for byte in frame.iter_mut().take(y_size) {
            *byte = y_val;
        }
        for byte in frame.iter_mut().skip(y_size) {
            *byte = 128_u8;
        }

        frame
    }

    // -----------------------------------------------------------------------
    // CropRegion tests
    // -----------------------------------------------------------------------

    #[test]
    fn test_crop_region_centered() {
        // Cat centered at (0.5, 0.5), size 0.2x0.2 in a 640x480 frame.
        let crop = CropRegion::from_normalized_bbox(
            [0.5_f32, 0.5_f32, 0.2_f32, 0.2_f32],
            640_u32,
            480_u32,
        );

        // 0.2 * 0.6 = 0.12 half-width/height factor applied to frame dims.
        // half_w = 0.12 * 640 = 76.8, half_h = 0.12 * 480 = 57.6
        // center = (320, 240)
        // x1 = 320 - 76.8 = 243.2 → 243, y1 = 240 - 57.6 = 182.4 → 182
        // x2 = 320 + 76.8 = 396.8 → 396, y2 = 240 + 57.6 = 297.6 → 297
        assert!(crop.w > 0, "crop width must be positive");
        assert!(crop.h > 0, "crop height must be positive");
        assert!(crop.x + crop.w <= 640, "crop must not exceed frame width");
        assert!(crop.y + crop.h <= 480, "crop must not exceed frame height");
    }

    #[test]
    fn test_crop_region_top_left_corner() {
        let crop = CropRegion::from_normalized_bbox(
            [0.0_f32, 0.0_f32, 0.1_f32, 0.1_f32],
            640_u32,
            480_u32,
        );
        assert_eq!(crop.x, 0_u32, "left edge must clamp to 0");
        assert_eq!(crop.y, 0_u32, "top edge must clamp to 0");
        assert!(crop.w >= 1, "width must be at least 1");
        assert!(crop.h >= 1, "height must be at least 1");
    }

    #[test]
    fn test_crop_region_bottom_right_corner() {
        let crop = CropRegion::from_normalized_bbox(
            [1.0_f32, 1.0_f32, 0.1_f32, 0.1_f32],
            640_u32,
            480_u32,
        );
        assert!(
            crop.x + crop.w <= 640,
            "crop must not exceed frame width at right edge"
        );
        assert!(
            crop.y + crop.h <= 480,
            "crop must not exceed frame height at bottom edge"
        );
    }

    #[test]
    fn test_crop_region_full_frame() {
        let crop = CropRegion::from_normalized_bbox(
            [0.5_f32, 0.5_f32, 1.0_f32, 1.0_f32],
            640_u32,
            480_u32,
        );
        // With 10% expansion, a full-frame bbox exceeds boundaries and gets clamped.
        assert_eq!(crop.x, 0_u32, "full-frame crop starts at x=0");
        assert_eq!(crop.y, 0_u32, "full-frame crop starts at y=0");
    }

    #[test]
    fn test_crop_region_tiny_bbox() {
        // Nearly zero-size bbox should produce at least 1x1 crop.
        let crop = CropRegion::from_normalized_bbox(
            [0.5_f32, 0.5_f32, 0.001_f32, 0.001_f32],
            640_u32,
            480_u32,
        );
        assert!(crop.w >= 1, "minimum crop width must be 1");
        assert!(crop.h >= 1, "minimum crop height must be 1");
    }

    // -----------------------------------------------------------------------
    // YUV → RGB conversion tests
    // -----------------------------------------------------------------------

    #[test]
    fn test_yuv_to_rgb_neutral() {
        // Y=128, U=128, V=128 → neutral gray.
        let (r, g, b) = yuv_to_rgb(128.0_f32, 128.0_f32, 128.0_f32);
        assert_eq!(r, 128_u8, "neutral gray R");
        assert_eq!(g, 128_u8, "neutral gray G");
        assert_eq!(b, 128_u8, "neutral gray B");
    }

    #[test]
    fn test_yuv_to_rgb_black() {
        let (r, g, b) = yuv_to_rgb(0.0_f32, 128.0_f32, 128.0_f32);
        assert_eq!(r, 0_u8, "black R");
        assert_eq!(g, 0_u8, "black G");
        assert_eq!(b, 0_u8, "black B");
    }

    #[test]
    fn test_yuv_to_rgb_white() {
        let (r, g, b) = yuv_to_rgb(255.0_f32, 128.0_f32, 128.0_f32);
        assert_eq!(r, 255_u8, "white R");
        assert_eq!(g, 255_u8, "white G");
        assert_eq!(b, 255_u8, "white B");
    }

    #[test]
    fn test_yuv_to_rgb_clamps_overflow() {
        // High V should push R high, clamped to 255.
        let (r, _g, _b) = yuv_to_rgb(255.0_f32, 128.0_f32, 255.0_f32);
        assert_eq!(r, 255_u8, "R must clamp at 255");
    }

    #[test]
    fn test_yuv_to_rgb_clamps_underflow() {
        // Low V should push R low, clamped to 0.
        let (r, _g, _b) = yuv_to_rgb(0.0_f32, 128.0_f32, 0.0_f32);
        assert_eq!(r, 0_u8, "R must clamp at 0");
    }

    // -----------------------------------------------------------------------
    // Bilinear interpolation tests
    // -----------------------------------------------------------------------

    #[test]
    fn test_bilerp_corners() {
        assert_eq!(
            bilerp(10.0_f32, 20.0_f32, 30.0_f32, 40.0_f32, 0.0_f32, 0.0_f32),
            10.0_f32,
            "top-left corner"
        );
        assert_eq!(
            bilerp(10.0_f32, 20.0_f32, 30.0_f32, 40.0_f32, 1.0_f32, 0.0_f32),
            20.0_f32,
            "top-right corner"
        );
        assert_eq!(
            bilerp(10.0_f32, 20.0_f32, 30.0_f32, 40.0_f32, 0.0_f32, 1.0_f32),
            30.0_f32,
            "bottom-left corner"
        );
        assert_eq!(
            bilerp(10.0_f32, 20.0_f32, 30.0_f32, 40.0_f32, 1.0_f32, 1.0_f32),
            40.0_f32,
            "bottom-right corner"
        );
    }

    #[test]
    fn test_bilerp_center() {
        let result = bilerp(0.0_f32, 100.0_f32, 100.0_f32, 200.0_f32, 0.5_f32, 0.5_f32);
        assert!(
            (result - 100.0_f32).abs() < 0.01_f32,
            "center of 0/100/100/200 grid must be ~100, got {result}"
        );
    }

    // -----------------------------------------------------------------------
    // crop_and_resize_nv12_to_rgb tests
    // -----------------------------------------------------------------------

    #[test]
    fn test_crop_resize_output_dimensions() {
        let frame = make_uniform_nv12(640_u32, 480_u32, 128_u8);
        let crop = CropRegion {
            x: 100_u32,
            y: 100_u32,
            w: 200_u32,
            h: 200_u32,
        };
        let rgb = crop_and_resize_nv12_to_rgb(&frame, 640_u32, 480_u32, crop);
        assert_eq!(
            rgb.len(),
            128 * 128 * 3,
            "output must be 128x128x3 = 49152 bytes"
        );
    }

    #[test]
    fn test_crop_resize_uniform_gray() {
        // Uniform Y=128, UV=128 → RGB should be (128, 128, 128) everywhere.
        let frame = make_uniform_nv12(640_u32, 480_u32, 128_u8);
        let crop = CropRegion {
            x: 0_u32,
            y: 0_u32,
            w: 640_u32,
            h: 480_u32,
        };
        let rgb = crop_and_resize_nv12_to_rgb(&frame, 640_u32, 480_u32, crop);

        // Check center pixel.
        let center = 64 * 128 * 3 + 64 * 3;
        let r = rgb.get(center).copied().unwrap_or(0);
        let g = rgb.get(center + 1).copied().unwrap_or(0);
        let b = rgb.get(center + 2).copied().unwrap_or(0);
        assert_eq!(r, 128_u8, "uniform gray R at center");
        assert_eq!(g, 128_u8, "uniform gray G at center");
        assert_eq!(b, 128_u8, "uniform gray B at center");
    }

    #[test]
    fn test_crop_resize_preserves_spatial_gradient() {
        // Frame with Y increasing left-to-right. Crop should preserve gradient.
        let width = 256_u32;
        let height = 256_u32;
        let mut frame = make_uniform_nv12(width, height, 0_u8);
        for y in 0..height as usize {
            for x in 0..width as usize {
                frame[y * width as usize + x] = x as u8;
            }
        }

        let crop = CropRegion {
            x: 0_u32,
            y: 0_u32,
            w: 256_u32,
            h: 256_u32,
        };
        let rgb = crop_and_resize_nv12_to_rgb(&frame, width, height, crop);

        // Left edge should be darker than right edge (R channel with neutral UV).
        let left_r = rgb.first().copied().unwrap_or(255);
        let right_r = rgb.get(127 * 3).copied().unwrap_or(0);
        assert!(
            right_r > left_r,
            "right edge ({right_r}) must be brighter than left edge ({left_r})"
        );
    }

    #[test]
    fn test_crop_resize_small_crop() {
        // 1x1 pixel crop should produce a valid 128x128 output.
        let frame = make_uniform_nv12(640_u32, 480_u32, 200_u8);
        let crop = CropRegion {
            x: 320_u32,
            y: 240_u32,
            w: 1_u32,
            h: 1_u32,
        };
        let rgb = crop_and_resize_nv12_to_rgb(&frame, 640_u32, 480_u32, crop);
        assert_eq!(
            rgb.len(),
            128 * 128 * 3,
            "1x1 crop must still produce 128x128 output"
        );
    }

    // -----------------------------------------------------------------------
    // L2 normalization tests
    // -----------------------------------------------------------------------

    #[test]
    fn test_l2_normalize_unit_vector() {
        let mut vec = [0.0_f32; EMBEDDING_DIM];
        vec[0] = 1.0_f32;
        l2_normalize(&mut vec);
        assert!(
            (vec[0] - 1.0_f32).abs() < 1e-6_f32,
            "unit vector along dim 0 should remain 1.0"
        );
    }

    #[test]
    fn test_l2_normalize_uniform() {
        let mut vec = [1.0_f32; EMBEDDING_DIM];
        l2_normalize(&mut vec);
        let norm_sq: f32 = vec.iter().map(|&v| v * v).sum();
        assert!(
            (norm_sq - 1.0_f32).abs() < 1e-5_f32,
            "L2 norm must be ~1.0 after normalization, got {norm_sq}"
        );
    }

    #[test]
    fn test_l2_normalize_zero_vector() {
        let mut vec = [0.0_f32; EMBEDDING_DIM];
        l2_normalize(&mut vec);
        assert_eq!(
            vec, [0.0_f32; EMBEDDING_DIM],
            "zero vector must remain zero after normalization"
        );
    }

    #[test]
    fn test_l2_normalize_negative_values() {
        let mut vec = [0.0_f32; EMBEDDING_DIM];
        vec[0] = -3.0_f32;
        vec[1] = 4.0_f32;
        l2_normalize(&mut vec);
        let norm_sq: f32 = vec.iter().map(|&v| v * v).sum();
        assert!(
            (norm_sq - 1.0_f32).abs() < 1e-5_f32,
            "norm must be 1.0 for [-3, 4, 0...], got {norm_sq}"
        );
        assert!(
            vec[0] < 0.0_f32,
            "sign must be preserved after normalization"
        );
    }

    // -----------------------------------------------------------------------
    // PendingEmbedding tests
    // -----------------------------------------------------------------------

    #[test]
    fn test_pending_embedding_not_ready_initially() {
        let pending = PendingEmbedding::new(5_u32);
        assert!(
            !pending.is_ready(),
            "pending embedding must not be ready before any accumulation"
        );
    }

    #[test]
    fn test_pending_embedding_ready_after_target() {
        let mut pending = PendingEmbedding::new(3_u32);
        let emb = [1.0_f32; EMBEDDING_DIM];
        pending.accumulate(&emb);
        assert!(!pending.is_ready(), "not ready after 1/3");
        pending.accumulate(&emb);
        assert!(!pending.is_ready(), "not ready after 2/3");
        pending.accumulate(&emb);
        assert!(pending.is_ready(), "must be ready after 3/3");
    }

    #[test]
    fn test_pending_embedding_finalize_averages() {
        let mut pending = PendingEmbedding::new(2_u32);

        let mut emb1 = [0.0_f32; EMBEDDING_DIM];
        emb1[0] = 1.0_f32;
        let mut emb2 = [0.0_f32; EMBEDDING_DIM];
        emb2[0] = 1.0_f32;
        emb2[1] = 1.0_f32;

        pending.accumulate(&emb1);
        pending.accumulate(&emb2);

        let result = pending.finalize();
        let norm_sq: f32 = result.iter().map(|&v| v * v).sum();
        assert!(
            (norm_sq - 1.0_f32).abs() < 1e-5_f32,
            "finalized embedding must be L2-normalized, got norm {norm_sq}"
        );

        // dim 0 should be larger than dim 1 (both embeddings contributed to dim 0,
        // only one contributed to dim 1).
        assert!(
            result[0] > result[1],
            "dim 0 ({}) should be larger than dim 1 ({})",
            result[0],
            result[1]
        );
    }

    #[test]
    fn test_pending_embedding_record_crop_grows_then_reuses_buffer() {
        let mut pending = PendingEmbedding::new(2_u32);
        assert!(
            pending.last_crop().is_none(),
            "no crop should be recorded before first inference",
        );

        let crop_a = vec![0xAA_u8; 128 * 128 * 3];
        pending.record_crop(&crop_a);
        let after_first = pending.last_crop().expect("crop must exist after record");
        assert_eq!(
            after_first.len(),
            crop_a.len(),
            "stored crop length must match"
        );
        assert_eq!(
            after_first.first(),
            Some(&0xAA_u8),
            "stored crop bytes must round-trip",
        );
        // Capture the underlying allocation pointer so we can prove
        // the second record_crop reuses it instead of reallocating —
        // matters because process_frame calls record_crop every
        // accumulating frame.
        let ptr_after_first = after_first.as_ptr();

        let crop_b = vec![0xBB_u8; 128 * 128 * 3];
        pending.record_crop(&crop_b);
        let after_second = pending.last_crop().expect("crop must persist");
        assert_eq!(
            after_second.first(),
            Some(&0xBB_u8),
            "stored crop must reflect the most recent recording",
        );
        assert_eq!(
            after_second.as_ptr(),
            ptr_after_first,
            "same-size crop must reuse the existing allocation",
        );
    }

    // -----------------------------------------------------------------------
    // JPEG thumbnail encoder tests
    // -----------------------------------------------------------------------

    /// Build a 128×128 NHWC RGB buffer filled with a deterministic
    /// gradient so a decode-side check can verify orientation.
    fn make_rgb_gradient(width: u32, height: u32) -> Vec<u8> {
        #[expect(
            clippy::as_conversions,
            clippy::cast_possible_truncation,
            clippy::arithmetic_side_effects,
            reason = "test fixture: bounded loop over small known dimensions"
        )]
        {
            let w = width as usize;
            let h = height as usize;
            let mut buf = vec![0_u8; w * h * 3];
            for y in 0..h {
                for x in 0..w {
                    let idx = (y * w + x) * 3;
                    buf[idx] = (x % 256) as u8;
                    buf[idx + 1] = (y % 256) as u8;
                    buf[idx + 2] = ((x + y) % 256) as u8;
                }
            }
            buf
        }
    }

    #[test]
    fn test_encode_thumbnail_jpeg_returns_valid_jpeg_marker() {
        let rgb = make_rgb_gradient(INPUT_SIZE, INPUT_SIZE);
        let jpeg = encode_thumbnail_jpeg(&rgb, INPUT_SIZE, INPUT_SIZE)
            .expect("128x128 RGB encode must succeed");
        assert!(
            jpeg.len() >= 4,
            "encoded JPEG must include at least the SOI/APP0 markers",
        );
        // SOI marker — every JPEG file starts with FF D8.
        assert_eq!(
            jpeg.first(),
            Some(&0xFF_u8),
            "JPEG must start with SOI byte 0xFF"
        );
        assert_eq!(
            jpeg.get(1),
            Some(&0xD8_u8),
            "JPEG must start with SOI byte 0xD8"
        );
        // EOI marker — every JPEG file ends with FF D9.
        let len = jpeg.len();
        assert_eq!(
            jpeg.get(len.wrapping_sub(2)),
            Some(&0xFF_u8),
            "JPEG must end with EOI byte 0xFF",
        );
        assert_eq!(
            jpeg.get(len.wrapping_sub(1)),
            Some(&0xD9_u8),
            "JPEG must end with EOI byte 0xD9",
        );
    }

    #[test]
    fn test_encode_thumbnail_jpeg_reasonable_size() {
        // Empirically a 128×128 RGB photo crop at quality 80 lands
        // in 1.5-6 KB. The thumbnail is shipped over a Unix-domain
        // IPC socket that does not enforce a hard ceiling, but the
        // downstream FCM payload limit (<4 KB) is the constraint
        // that motivated the quality choice — exceeding ~16 KB here
        // would suggest the encoder is producing something pathological.
        let rgb = make_rgb_gradient(INPUT_SIZE, INPUT_SIZE);
        let jpeg = encode_thumbnail_jpeg(&rgb, INPUT_SIZE, INPUT_SIZE).unwrap_or_default();
        assert!(
            !jpeg.is_empty(),
            "encoded JPEG must not be empty for a non-degenerate input",
        );
        assert!(
            jpeg.len() < 16 * 1024,
            "128x128 thumbnail must fit comfortably below 16 KB, got {} bytes",
            jpeg.len(),
        );
    }

    #[test]
    fn test_encode_thumbnail_jpeg_oversized_dimensions_rejected() {
        // JPEG dimensions are 16-bit unsigned. Anything past u16::MAX
        // must be rejected at the type-conversion boundary rather than
        // surfacing as a confusing encoder-internal error. The buffer
        // size is intentionally a stub — the dimension check fires
        // before the encoder reads any pixel data.
        let stub = vec![0_u8; 16];
        let too_wide = u32::from(u16::MAX) + 1;
        let err = encode_thumbnail_jpeg(&stub, too_wide, INPUT_SIZE)
            .expect_err("oversized width must error");
        match err {
            EmbedError::ThumbnailEncode { width, height, .. } => {
                assert_eq!(width, too_wide, "error must carry the offending width");
                assert_eq!(height, INPUT_SIZE, "error must carry the source height");
            }
            other => panic!("expected ThumbnailEncode, got {other:?}"),
        }
    }

    // -----------------------------------------------------------------------
    // embedding_to_bytes tests
    // -----------------------------------------------------------------------

    #[test]
    fn test_embedding_to_bytes_length() {
        let emb = [0.0_f32; EMBEDDING_DIM];
        let bytes = embedding_to_bytes(&emb);
        assert_eq!(bytes.len(), 512, "128 f32 values must produce 512 bytes");
    }

    #[test]
    fn test_embedding_to_bytes_round_trip() {
        let mut emb = [0.0_f32; EMBEDDING_DIM];
        emb[0] = 1.0_f32;
        emb[42] = -0.5_f32;
        emb[127] = 0.123_456_f32;

        let bytes = embedding_to_bytes(&emb);
        let mut recovered = [0.0_f32; EMBEDDING_DIM];
        for (i, chunk) in bytes.chunks_exact(4).enumerate() {
            let arr: [u8; 4] = [chunk[0], chunk[1], chunk[2], chunk[3]];
            recovered[i] = f32::from_le_bytes(arr);
        }

        assert_eq!(
            emb, recovered,
            "embedding must round-trip through bytes exactly"
        );
    }

    // -----------------------------------------------------------------------
    // Proptest
    // -----------------------------------------------------------------------

    proptest! {
        #[test]
        fn test_crop_region_always_valid(
            cx in 0.0_f32..=1.0_f32,
            cy in 0.0_f32..=1.0_f32,
            w in 0.001_f32..=1.0_f32,
            h in 0.001_f32..=1.0_f32,
            fw in 2_u32..=2048_u32,
            fh in 2_u32..=2048_u32,
        ) {
            let crop = CropRegion::from_normalized_bbox([cx, cy, w, h], fw, fh);
            prop_assert!(crop.w >= 1, "crop width must be >= 1");
            prop_assert!(crop.h >= 1, "crop height must be >= 1");
            prop_assert!(crop.x + crop.w <= fw, "crop must fit in frame width");
            prop_assert!(crop.y + crop.h <= fh, "crop must fit in frame height");
        }

        #[test]
        fn test_l2_normalize_produces_unit_vector(
            values in proptest::collection::vec(-10.0_f32..10.0_f32, EMBEDDING_DIM..=EMBEDDING_DIM),
        ) {
            let mut vec = [0.0_f32; EMBEDDING_DIM];
            for (dst, src) in vec.iter_mut().zip(values.iter()) {
                *dst = *src;
            }

            let is_zero = vec.iter().all(|&v| v.abs() < f32::EPSILON);
            l2_normalize(&mut vec);

            if !is_zero {
                let norm_sq: f32 = vec.iter().map(|&v| v * v).sum();
                prop_assert!(
                    (norm_sq - 1.0_f32).abs() < 1e-4_f32,
                    "L2 norm must be ~1.0, got {norm_sq}"
                );
            }
        }

        #[test]
        fn test_yuv_to_rgb_always_in_range(
            y in 0.0_f32..=255.0_f32,
            u in 0.0_f32..=255.0_f32,
            v in 0.0_f32..=255.0_f32,
        ) {
            let (r, g, b) = yuv_to_rgb(y, u, v);
            prop_assert!(r <= 255_u8, "R must be <= 255");
            prop_assert!(g <= 255_u8, "G must be <= 255");
            prop_assert!(b <= 255_u8, "B must be <= 255");
        }
    }
}
