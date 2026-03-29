//! `YOLOv8` detection post-processing for RKNN INT8 NPU output.
//!
//! Decodes the 9 raw output tensors from the RKNN Model Zoo's optimized
//! `YOLOv8n` export (3 strides x 3 tensors: box, class, score) into a list
//! of [`Detection`]s with pixel-space bounding boxes, class IDs, and
//! confidence scores.
//!
//! Processing pipeline per frame:
//! 1. Score tensor pre-filter (rejects ~95% of cells cheaply)
//! 2. DFL box decoding (softmax over 4x16 bins → pixel bbox)
//! 3. Class score extraction (sigmoid → best class)
//! 4. Greedy NMS (`IoU`-based suppression)
//!
//! All tensor reads happen directly in NC1HWC2 layout to avoid per-frame
//! allocation. Internal buffers are pre-allocated and reused across frames.

use crate::npu::Model;
use crate::npu::error::NpuError;
use crate::npu::tensor::{QuantType, TensorAttr, TensorFormat, TensorType, dequantize_affine};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Number of DFL bins per offset direction.
const DFL_REG_MAX: usize = 16;

/// Number of box offset channels (4 directions x 16 bins).
const BOX_CHANNELS: u32 = 64;

/// Number of COCO classes.
const NUM_CLASSES: usize = 80;

/// Number of COCO class channels.
const NUM_CLASS_CHANNELS: u32 = 80;

/// Number of score channels (summed confidence helper tensor).
const SCORE_CHANNELS: u32 = 1;

/// C2 block size on RV1106 for INT8 tensors.
const C2: usize = 16;

/// Number of stride levels in `YOLOv8` FPN.
const NUM_STRIDES: usize = 3;

/// Expected number of output tensors (3 roles x 3 strides).
const EXPECTED_OUTPUTS: u32 = 9;

// ---------------------------------------------------------------------------
// Detection output types
// ---------------------------------------------------------------------------

/// A single detected object with pixel-space bounding box.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Detection {
    /// Bounding box in model input pixel coordinates.
    pub bbox: BoundingBox,
    /// COCO class ID (0-79).
    pub class_id: u16,
    /// Detection confidence (sigmoid of best class logit), range (0, 1).
    pub confidence: f32,
}

/// Axis-aligned bounding box in pixel coordinates.
///
/// Coordinates are in the model's input space (e.g. 640x480).
/// `x1 <= x2` and `y1 <= y2` after construction.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct BoundingBox {
    /// Left edge (pixels).
    pub x1: f32,
    /// Top edge (pixels).
    pub y1: f32,
    /// Right edge (pixels).
    pub x2: f32,
    /// Bottom edge (pixels).
    pub y2: f32,
}

impl BoundingBox {
    /// Creates a bounding box, ensuring x1 <= x2 and y1 <= y2.
    fn new(x1: f32, y1: f32, x2: f32, y2: f32) -> Self {
        Self {
            x1: x1.min(x2),
            y1: y1.min(y2),
            x2: x1.max(x2),
            y2: y1.max(y2),
        }
    }

    /// Area of the bounding box. Returns 0.0 for degenerate boxes.
    fn area(&self) -> f32 {
        let w = self.x2 - self.x1;
        let h = self.y2 - self.y1;
        if w <= 0.0_f32 || h <= 0.0_f32 {
            return 0.0_f32;
        }
        w * h
    }

    /// Clamps the bounding box to the given image dimensions.
    fn clamp(&self, width: f32, height: f32) -> Self {
        Self {
            x1: self.x1.max(0.0_f32).min(width),
            y1: self.y1.max(0.0_f32).min(height),
            x2: self.x2.max(0.0_f32).min(width),
            y2: self.y2.max(0.0_f32).min(height),
        }
    }
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Detection post-processing configuration.
#[derive(Debug, Clone)]
pub(crate) struct DetectionConfig {
    /// Pre-filter threshold on the score tensor (summed class scores).
    /// Cells below this are skipped before touching box/class tensors.
    pub score_threshold: f32,
    /// Confidence threshold on sigmoid class scores.
    /// Detections below this are discarded.
    /// Set above 0.5 to reject INT8 sigmoid(0) noise (~0.502).
    pub confidence_threshold: f32,
    /// `IoU` threshold for NMS. Overlapping detections above this are suppressed.
    pub nms_iou_threshold: f32,
    /// Maximum number of detections to return per frame.
    pub max_detections: u32,
}

impl Default for DetectionConfig {
    fn default() -> Self {
        Self {
            score_threshold: 0.25_f32,
            confidence_threshold: 0.51_f32,
            nms_iou_threshold: 0.45_f32,
            max_detections: 20,
        }
    }
}

// ---------------------------------------------------------------------------
// Error types
// ---------------------------------------------------------------------------

/// Errors from detection post-processing.
#[derive(Debug, thiserror::Error)]
pub(crate) enum DetectError {
    /// Model does not have the expected number of output tensors.
    #[error("expected {EXPECTED_OUTPUTS} output tensors, model has {actual}")]
    OutputCount {
        /// Actual number of outputs.
        actual: u32,
    },

    /// An output tensor is not in the expected NC1HWC2 format.
    #[error("output tensor {index} is not NC1HWC2 format (got {format:?})")]
    WrongFormat {
        /// Tensor index.
        index: u32,
        /// Actual format.
        format: TensorFormat,
    },

    /// An output tensor is not INT8 type.
    #[error("output tensor {index} is not INT8 type (got {data_type:?})")]
    WrongDataType {
        /// Tensor index.
        index: u32,
        /// Actual data type.
        data_type: TensorType,
    },

    /// An output tensor does not use affine asymmetric quantization.
    #[error("output tensor {index} is not affine asymmetric quantized (got {qnt_type:?})")]
    WrongQuantType {
        /// Tensor index.
        index: u32,
        /// Actual quantization type.
        qnt_type: QuantType,
    },

    /// An output tensor has an unexpected number of dimensions.
    #[error("output tensor {index} has {n_dims} dimensions, expected 5 for NC1HWC2")]
    WrongDimCount {
        /// Tensor index.
        index: u32,
        /// Actual dimension count.
        n_dims: u32,
    },

    /// Could not identify the role of an output tensor by its channel count.
    #[error(
        "cannot identify role of output tensor {index}: \
         C1={c1}, C2={c2} ({channels} logical channels), {height}x{width} spatial"
    )]
    UnrecognizedTensor {
        /// Tensor index.
        index: u32,
        /// C1 dimension (channel blocks).
        c1: u32,
        /// C2 dimension (block size).
        c2: u32,
        /// Computed logical channel count.
        channels: u32,
        /// Spatial height.
        height: u32,
        /// Spatial width.
        width: u32,
    },

    /// A stride level is missing one of its three required tensor roles.
    #[error("stride level with grid {grid_h}x{grid_w}: missing {role} tensor")]
    MissingTensor {
        /// Expected tensor role.
        role: &'static str,
        /// Grid height of the stride level.
        grid_h: u32,
        /// Grid width of the stride level.
        grid_w: u32,
    },

    /// Computed stride is not consistent between width and height.
    #[error(
        "stride mismatch for grid {grid_h}x{grid_w}: \
         horizontal stride {stride_x}, vertical stride {stride_y}"
    )]
    StrideMismatch {
        /// Horizontal stride (`model_width` / `grid_w`).
        stride_x: u32,
        /// Vertical stride (`model_height` / `grid_h`).
        stride_y: u32,
        /// Grid width.
        grid_w: u32,
        /// Grid height.
        grid_h: u32,
    },

    /// The model input dimensions are not evenly divisible by a grid dimension.
    #[error("model input {model_dim}px is not evenly divisible by grid dimension {grid_dim}")]
    IndivisibleGrid {
        /// Model input dimension (width or height).
        model_dim: u32,
        /// Grid dimension that does not divide evenly.
        grid_dim: u32,
    },

    /// Did not find exactly 3 stride levels from the output tensors.
    #[error("expected {NUM_STRIDES} stride levels, found {actual}")]
    StrideLevelCount {
        /// Actual number of stride levels found.
        actual: usize,
    },

    /// Failed to read an output tensor from the NPU model.
    #[error("NPU output read failed: {0}")]
    NpuOutput(#[from] NpuError),
}

// ---------------------------------------------------------------------------
// Internal: stride level metadata
// ---------------------------------------------------------------------------

/// Per-stride-level cached metadata for fast per-frame processing.
#[derive(Debug, Clone)]
struct StrideLevel {
    /// Stride in pixels (e.g. 8, 16, 32).
    stride: u32,
    /// Grid height (`model_height` / stride).
    grid_h: u32,
    /// Grid width (`model_width` / stride).
    grid_w: u32,
    /// Output tensor index for the box tensor (64 channels, DFL).
    box_idx: u32,
    /// Output tensor index for the class tensor (80 channels).
    class_idx: u32,
    /// Output tensor index for the score tensor (1 channel).
    score_idx: u32,
    /// Box tensor quantization zero point.
    box_zp: i32,
    /// Box tensor quantization scale.
    box_scale: f32,
    /// Class tensor quantization zero point.
    class_zp: i32,
    /// Class tensor quantization scale.
    class_scale: f32,
    /// Score tensor quantization zero point.
    score_zp: i32,
    /// Score tensor quantization scale.
    score_scale: f32,
    /// Pre-computed INT8 threshold for the score pre-filter. Raw score
    /// tensor values below this are skipped without dequantization.
    score_threshold_i8: i8,
}

/// Pre-NMS detection candidate.
#[derive(Debug, Clone, Copy)]
struct Candidate {
    bbox: BoundingBox,
    class_id: u16,
    confidence: f32,
}

// ---------------------------------------------------------------------------
// Math helpers
// ---------------------------------------------------------------------------

/// Sigmoid activation: 1 / (1 + exp(-x)).
#[expect(
    clippy::arithmetic_side_effects,
    reason = "f32 arithmetic: exp() and division produce finite results for finite \
              inputs. The clamp guards against overflow in exp() for large negative x."
)]
fn sigmoid(x: f32) -> f32 {
    // Clamp to avoid overflow in exp() for very negative values.
    // sigmoid(-20) ~= 2e-9, sigmoid(20) ~= 1-2e-9 — sufficient precision.
    let clamped = x.clamp(-20.0_f32, 20.0_f32);
    1.0_f32 / (1.0_f32 + (-clamped).exp())
}

/// Softmax over exactly 16 values (one DFL bin group).
///
/// Computes numerically stable softmax by subtracting the max before
/// exponentiating to prevent overflow.
#[expect(
    clippy::arithmetic_side_effects,
    reason = "f32 arithmetic in softmax: subtraction for numerical stability, \
              exp() of bounded range, sum of positive values, division by positive sum. \
              All produce finite results for finite inputs."
)]
fn softmax_16(logits: &[f32; DFL_REG_MAX]) -> [f32; DFL_REG_MAX] {
    // Find max for numerical stability.
    let max_val = logits.iter().copied().reduce(f32::max).unwrap_or(0.0_f32);

    // Exponentiate and sum.
    let mut exps = [0.0_f32; DFL_REG_MAX];
    let mut sum = 0.0_f32;
    for (exp_slot, &logit) in exps.iter_mut().zip(logits.iter()) {
        *exp_slot = (logit - max_val).exp();
        sum += *exp_slot;
    }

    // Normalize. Guard against zero sum (all -inf inputs, shouldn't happen
    // with real tensor data but produces uniform output rather than NaN).
    if sum > 0.0_f32 {
        for exp_slot in &mut exps {
            *exp_slot /= sum;
        }
    }

    exps
}

/// Intersection over Union between two bounding boxes.
#[expect(
    clippy::arithmetic_side_effects,
    reason = "f32 arithmetic for IoU: min/max for intersection, area subtraction, \
              division by union area. All values are non-negative pixel coordinates."
)]
fn iou(a: &BoundingBox, b: &BoundingBox) -> f32 {
    let left = a.x1.max(b.x1);
    let top = a.y1.max(b.y1);
    let right = a.x2.min(b.x2);
    let bottom = a.y2.min(b.y2);

    let inter_w = (right - left).max(0.0_f32);
    let inter_h = (bottom - top).max(0.0_f32);
    let inter_area = inter_w * inter_h;

    let union_area = a.area() + b.area() - inter_area;

    if union_area <= 0.0_f32 {
        return 0.0_f32;
    }

    inter_area / union_area
}

/// Computes the minimum raw INT8 score tensor value that could meet
/// the float score threshold after dequantization.
///
/// Conservative: may admit cells whose dequantized score falls just
/// below the float threshold (caught by the confidence check downstream).
#[expect(
    clippy::as_conversions,
    clippy::cast_precision_loss,
    clippy::cast_possible_truncation,
    clippy::arithmetic_side_effects,
    reason = "INT8 threshold precomputation: zp (i8-range i32) → f32 is lossless \
              in practice. f32 division/addition for the threshold mapping. \
              floor().clamp(-128, 127) guarantees the f32 → i8 cast is in range."
)]
fn compute_score_threshold_i8(score_threshold: f32, zp: i32, scale: f32) -> i8 {
    if scale.partial_cmp(&0.0_f32) != Some(std::cmp::Ordering::Greater) {
        // Scale must be positive for RKNN affine asymmetric. If it
        // isn't (zero, negative, or NaN), disable the optimization
        // by admitting all cells.
        return i8::MIN;
    }
    // float_value = (raw - zp) * scale  →  raw = float_value / scale + zp
    // floor() ensures we never reject a cell that would pass the float check.
    let raw = (score_threshold / scale) + zp as f32;
    let clamped = raw.floor().clamp(f32::from(i8::MIN), f32::from(i8::MAX));
    clamped as i8
}

/// Reads a single element from NC1HWC2 tensor data.
///
/// Returns `None` if the computed offset is out of bounds.
#[expect(
    clippy::arithmetic_side_effects,
    clippy::integer_division,
    reason = "NC1HWC2 index arithmetic with small tensor dimensions. \
              Products of channel/spatial dims cannot overflow usize. \
              Integer division computes channel block indices."
)]
fn read_nc1hwc2(
    data: &[i8],
    c: usize,
    h: usize,
    w: usize,
    grid_h: usize,
    grid_w: usize,
) -> Option<i8> {
    let c1_idx = c / C2;
    let c2_idx = c % C2;
    let offset = ((c1_idx * grid_h + h) * grid_w + w) * C2 + c2_idx;
    data.get(offset).copied()
}

/// Reads and dequantizes a single element from NC1HWC2 tensor data.
#[expect(
    clippy::too_many_arguments,
    reason = "flat parameter list is clearer than a wrapper struct for an internal \
              hot-path function called per grid cell per channel"
)]
fn read_dequant(
    data: &[i8],
    c: usize,
    h: usize,
    w: usize,
    grid_h: usize,
    grid_w: usize,
    zp: i32,
    scale: f32,
) -> f32 {
    let raw = read_nc1hwc2(data, c, h, w, grid_h, grid_w).unwrap_or(0_i8);
    dequantize_affine(raw, zp, scale)
}

// ---------------------------------------------------------------------------
// Tensor role identification
// ---------------------------------------------------------------------------

/// Role of an output tensor within a stride group.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TensorRole {
    /// Box regression tensor (64 channels: 4 offsets x 16 DFL bins).
    Box,
    /// Class logits tensor (80 channels).
    Class,
    /// Score pre-filter tensor (1 channel).
    Score,
}

/// Parsed identity of an output tensor.
#[derive(Debug)]
struct TensorIdentity {
    index: u32,
    role: TensorRole,
    grid_h: u32,
    grid_w: u32,
    zp: i32,
    scale: f32,
}

/// Identifies the role and spatial dimensions of an output tensor from its attributes.
fn identify_tensor(attr: &TensorAttr) -> Result<TensorIdentity, DetectError> {
    let index = attr.index();

    // Validate format, type, quantization.
    if attr.format() != TensorFormat::Nc1hwc2 {
        return Err(DetectError::WrongFormat {
            index,
            format: attr.format(),
        });
    }
    if attr.data_type() != TensorType::Int8 {
        return Err(DetectError::WrongDataType {
            index,
            data_type: attr.data_type(),
        });
    }
    if attr.qnt_type() != QuantType::AffineAsymmetric {
        return Err(DetectError::WrongQuantType {
            index,
            qnt_type: attr.qnt_type(),
        });
    }

    // NC1HWC2 should have 5 dimensions: [N, C1, H, W, C2].
    if attr.n_dims() != 5 {
        return Err(DetectError::WrongDimCount {
            index,
            n_dims: attr.n_dims(),
        });
    }

    let dims = attr.dims();
    // dims[0] = N, dims[1] = C1, dims[2] = H, dims[3] = W, dims[4] = C2
    let c1 = dims.get(1).copied().unwrap_or(0);
    let grid_h = dims.get(2).copied().unwrap_or(0);
    let grid_w = dims.get(3).copied().unwrap_or(0);
    let c2_dim = dims.get(4).copied().unwrap_or(0);

    #[expect(
        clippy::as_conversions,
        clippy::cast_possible_truncation,
        reason = "C2 is 16, trivially fits u32. Used only for comparison."
    )]
    let c2_u32 = C2 as u32;

    // Identify role by C1 (channel block count). C2 is always 16 on RV1106.
    // Box: C1=4 (64 channels / 16), Class: C1=5 (ceil(80/16)), Score: C1=1 (ceil(1/16))
    let role = if c2_dim == c2_u32 && c1.checked_mul(c2_dim) == Some(BOX_CHANNELS) {
        TensorRole::Box
    } else if c2_dim == c2_u32 && c1 == NUM_CLASS_CHANNELS.div_ceil(c2_u32) {
        TensorRole::Class
    } else if c2_dim == c2_u32 && c1 == SCORE_CHANNELS.div_ceil(c2_u32) {
        TensorRole::Score
    } else {
        #[expect(
            clippy::arithmetic_side_effects,
            reason = "c1 * c2_dim: both are small tensor dimensions (max 5 * 16 = 80), \
                      cannot overflow u32"
        )]
        let channels = c1 * c2_dim;
        return Err(DetectError::UnrecognizedTensor {
            index,
            c1,
            c2: c2_dim,
            channels,
            height: grid_h,
            width: grid_w,
        });
    };

    Ok(TensorIdentity {
        index,
        role,
        grid_h,
        grid_w,
        zp: attr.zp(),
        scale: attr.scale(),
    })
}

// ---------------------------------------------------------------------------
// Detector
// ---------------------------------------------------------------------------

/// `YOLOv8` detection post-processor.
///
/// Constructed from a loaded [`Model`]'s output tensor attributes. Validates
/// the 9-tensor topology at construction time and caches per-stride metadata
/// for fast per-frame processing.
///
/// Internal buffers are pre-allocated and reused across frames — no heap
/// allocation occurs on the hot path after the first frame.
///
/// # Usage
///
/// ```text
/// let detector = Detector::new(config, &model)?;
/// loop {
///     model.set_input(frame_data)?;
///     model.run()?;
///     let detections = detector.detect(&model)?;
///     // process detections...
/// }
/// ```
#[derive(Debug)]
pub(crate) struct Detector {
    config: DetectionConfig,
    strides: [StrideLevel; NUM_STRIDES],
    model_width: f32,
    model_height: f32,
    candidates: Vec<Candidate>,
    suppressed: Vec<bool>,
    detections: Vec<Detection>,
}

impl Detector {
    /// Creates a detector by validating and parsing the model's output tensor topology.
    ///
    /// Examines all 9 output tensors to identify their roles (box/class/score)
    /// and stride levels, caching quantization parameters and grid dimensions
    /// for fast per-frame processing.
    pub(crate) fn new(config: DetectionConfig, model: &Model) -> Result<Self, DetectError> {
        let n_outputs = model.output_count();
        if n_outputs != EXPECTED_OUTPUTS {
            return Err(DetectError::OutputCount { actual: n_outputs });
        }

        // Identify all 9 tensors.
        let mut identities = Vec::with_capacity(usize::try_from(EXPECTED_OUTPUTS).unwrap_or(9));
        for i in 0..EXPECTED_OUTPUTS {
            let attr = model.output_attr(i)?;
            identities.push(identify_tensor(attr)?);
        }

        // Get model input dimensions for stride computation.
        let input_attr = model.input_attr();
        let input_dims = input_attr.dims();
        // NHWC input: [N, H, W, C] — but native format might vary.
        // For NHWC: dims[1]=H, dims[2]=W. For NCHW: dims[2]=H, dims[3]=W.
        // The input format on RV1106 in zero-copy mode is NHWC.
        let (model_h, model_w) = match input_attr.format() {
            // NHWC: [N, H, W, C]. Undefined: assume same layout.
            TensorFormat::Nhwc | TensorFormat::Undefined => {
                let h = input_dims.get(1).copied().unwrap_or(0);
                let w = input_dims.get(2).copied().unwrap_or(0);
                (h, w)
            }
            // NCHW: [N, C, H, W]. NC1HWC2: [N, C1, H, W, C2]. H/W at same indices.
            TensorFormat::Nchw | TensorFormat::Nc1hwc2 => {
                let h = input_dims.get(2).copied().unwrap_or(0);
                let w = input_dims.get(3).copied().unwrap_or(0);
                (h, w)
            }
        };

        // Group tensors by spatial dimensions to find stride levels.
        let strides = build_stride_levels(&identities, model_w, model_h, config.score_threshold)?;

        #[expect(
            clippy::as_conversions,
            clippy::cast_precision_loss,
            reason = "model dimensions (640, 480) fit exactly in f32"
        )]
        let (model_width, model_height) = (model_w as f32, model_h as f32);

        Ok(Self {
            config,
            strides,
            model_width,
            model_height,
            candidates: Vec::new(),
            suppressed: Vec::new(),
            detections: Vec::new(),
        })
    }

    /// Processes raw NPU output tensors into detections.
    ///
    /// The model must have been run ([`Model::set_input`] + [`Model::run`])
    /// before calling this. Returns a slice of detections valid until the
    /// next call to `detect`.
    pub(crate) fn detect(&mut self, model: &Model) -> Result<&[Detection], DetectError> {
        self.candidates.clear();

        for stride in &self.strides {
            let box_tensor = model.output(stride.box_idx)?;
            let class_tensor = model.output(stride.class_idx)?;
            let score_tensor = model.output(stride.score_idx)?;

            process_stride(
                &self.config,
                stride,
                self.model_width,
                self.model_height,
                box_tensor.data(),
                class_tensor.data(),
                score_tensor.data(),
                &mut self.candidates,
            );
        }

        self.nms();

        Ok(&self.detections)
    }

    /// Greedy Non-Maximum Suppression.
    ///
    /// Sorts candidates by confidence descending, then iteratively selects
    /// the highest-scoring candidate and suppresses all remaining candidates
    /// with `IoU` above the threshold.
    fn nms(&mut self) {
        // Sort by confidence descending.
        self.candidates
            .sort_unstable_by(|a, b| b.confidence.total_cmp(&a.confidence));

        let len = self.candidates.len();
        self.suppressed.clear();
        self.suppressed.resize(len, false);
        self.detections.clear();

        let max = usize::try_from(self.config.max_detections).unwrap_or(usize::MAX);

        for i in 0..len {
            if self.suppressed.get(i).copied().unwrap_or(true) {
                continue;
            }

            let Some(candidate) = self.candidates.get(i) else {
                continue;
            };

            self.detections.push(Detection {
                bbox: candidate.bbox,
                class_id: candidate.class_id,
                confidence: candidate.confidence,
            });

            if self.detections.len() >= max {
                break;
            }

            // Suppress overlapping lower-confidence candidates of the
            // same class. Per-class NMS ensures that overlapping detections
            // of different classes (e.g. a cat in front of a person) both
            // survive — critical for safety ceiling computation.
            #[expect(
                clippy::arithmetic_side_effects,
                reason = "i + 1 cannot overflow: i < len, len is a Vec length (< usize::MAX)"
            )]
            let start = i + 1;
            for j in start..len {
                if self.suppressed.get(j).copied().unwrap_or(true) {
                    continue;
                }
                if let Some(other) = self.candidates.get(j)
                    && other.class_id == candidate.class_id
                    && iou(&candidate.bbox, &other.bbox) > self.config.nms_iou_threshold
                    && let Some(flag) = self.suppressed.get_mut(j)
                {
                    *flag = true;
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Stride level construction
// ---------------------------------------------------------------------------

/// Builds the 3 stride levels from the identified output tensors.
///
/// Groups tensors by spatial dimensions (`grid_h`, `grid_w`), validates that each
/// group has exactly one box, class, and score tensor, and computes the stride
/// from model dimensions.
fn build_stride_levels(
    identities: &[TensorIdentity],
    model_w: u32,
    model_h: u32,
    score_threshold: f32,
) -> Result<[StrideLevel; NUM_STRIDES], DetectError> {
    // Collect unique spatial dimensions.
    let mut grid_sizes: Vec<(u32, u32)> = Vec::with_capacity(NUM_STRIDES);
    for id in identities {
        let key = (id.grid_h, id.grid_w);
        if !grid_sizes.contains(&key) {
            grid_sizes.push(key);
        }
    }

    if grid_sizes.len() != NUM_STRIDES {
        return Err(DetectError::StrideLevelCount {
            actual: grid_sizes.len(),
        });
    }

    // Sort by grid area descending (largest grid = smallest stride first).
    grid_sizes.sort_unstable_by(|a, b| {
        let area_a = u64::from(a.0).saturating_mul(u64::from(a.1));
        let area_b = u64::from(b.0).saturating_mul(u64::from(b.1));
        area_b.cmp(&area_a)
    });

    let mut levels = Vec::with_capacity(NUM_STRIDES);

    for &(grid_h, grid_w) in &grid_sizes {
        levels.push(build_single_stride(
            identities,
            grid_h,
            grid_w,
            model_w,
            model_h,
            score_threshold,
        )?);
    }

    // Convert Vec to fixed-size array.
    let result: [StrideLevel; NUM_STRIDES] = levels
        .try_into()
        .map_err(|v: Vec<StrideLevel>| DetectError::StrideLevelCount { actual: v.len() })?;

    Ok(result)
}

/// Validates and constructs a single [`StrideLevel`] from tensors matching
/// the given grid dimensions.
fn build_single_stride(
    identities: &[TensorIdentity],
    grid_h: u32,
    grid_w: u32,
    model_w: u32,
    model_h: u32,
    score_threshold: f32,
) -> Result<StrideLevel, DetectError> {
    let mut box_tensor: Option<&TensorIdentity> = None;
    let mut class_tensor: Option<&TensorIdentity> = None;
    let mut score_tensor: Option<&TensorIdentity> = None;

    for id in identities {
        if id.grid_h == grid_h && id.grid_w == grid_w {
            match id.role {
                TensorRole::Box => box_tensor = Some(id),
                TensorRole::Class => class_tensor = Some(id),
                TensorRole::Score => score_tensor = Some(id),
            }
        }
    }

    let box_t = box_tensor.ok_or(DetectError::MissingTensor {
        role: "box",
        grid_h,
        grid_w,
    })?;
    let class_t = class_tensor.ok_or(DetectError::MissingTensor {
        role: "class",
        grid_h,
        grid_w,
    })?;
    let score_t = score_tensor.ok_or(DetectError::MissingTensor {
        role: "score",
        grid_h,
        grid_w,
    })?;

    // Compute stride and validate consistency.
    #[expect(
        clippy::arithmetic_side_effects,
        reason = "grid_w/grid_h == 0 checked first, modulo of non-zero cannot panic"
    )]
    if grid_w == 0 || !model_w.is_multiple_of(grid_w) {
        return Err(DetectError::IndivisibleGrid {
            model_dim: model_w,
            grid_dim: grid_w,
        });
    }
    #[expect(
        clippy::arithmetic_side_effects,
        reason = "grid_h == 0 checked first, modulo of non-zero cannot panic"
    )]
    if grid_h == 0 || !model_h.is_multiple_of(grid_h) {
        return Err(DetectError::IndivisibleGrid {
            model_dim: model_h,
            grid_dim: grid_h,
        });
    }

    #[expect(
        clippy::integer_division,
        clippy::arithmetic_side_effects,
        reason = "stride computation: divisibility verified above, division is exact"
    )]
    let (stride_x, stride_y) = (model_w / grid_w, model_h / grid_h);

    if stride_x != stride_y {
        return Err(DetectError::StrideMismatch {
            stride_x,
            stride_y,
            grid_w,
            grid_h,
        });
    }

    Ok(StrideLevel {
        stride: stride_x,
        grid_h,
        grid_w,
        box_idx: box_t.index,
        class_idx: class_t.index,
        score_idx: score_t.index,
        box_zp: box_t.zp,
        box_scale: box_t.scale,
        class_zp: class_t.zp,
        class_scale: class_t.scale,
        score_zp: score_t.zp,
        score_scale: score_t.scale,
        score_threshold_i8: compute_score_threshold_i8(score_threshold, score_t.zp, score_t.scale),
    })
}

// ---------------------------------------------------------------------------
// Per-stride grid cell processing (free functions for borrow-checker clarity)
// ---------------------------------------------------------------------------

/// Processes all grid cells for a single stride level, appending candidates
/// to the output buffer.
#[expect(
    clippy::as_conversions,
    clippy::cast_precision_loss,
    clippy::arithmetic_side_effects,
    clippy::too_many_arguments,
    clippy::suboptimal_flops,
    reason = "Grid cell iteration and coordinate computation. \
              h/w are small grid indices (max 80), stride is 8/16/32. \
              Products fit in f32 exactly. usize→f32 casts are lossless \
              for values under 2^24. Arithmetic is on f32 pixel coordinates. \
              Flat parameter list preferred over wrapper struct for clarity. \
              mul_add not used: explicit arithmetic matches the spec formula."
)]
fn process_stride(
    config: &DetectionConfig,
    stride: &StrideLevel,
    model_width: f32,
    model_height: f32,
    box_data: &[i8],
    class_data: &[i8],
    score_data: &[i8],
    candidates: &mut Vec<Candidate>,
) {
    let gh = stride.grid_h as usize;
    let gw = stride.grid_w as usize;
    let stride_f = stride.stride as f32;

    for h in 0..gh {
        for w in 0..gw {
            // Step 1: Quick pre-filter via raw INT8 score comparison.
            // The threshold was pre-computed at construction time from
            // the float score_threshold and this stride's quantization
            // parameters, avoiding per-cell dequantization.
            let raw_score = read_nc1hwc2(score_data, 0, h, w, gh, gw).unwrap_or(i8::MIN);
            if raw_score < stride.score_threshold_i8 {
                continue;
            }

            // Step 2: Find best class via sigmoid of class logits.
            let (class_id, confidence) = find_best_class(class_data, h, w, gh, gw, stride);
            if confidence < config.confidence_threshold {
                continue;
            }

            // Step 3: DFL box decode.
            let [dist_left, dist_top, dist_right, dist_bottom] =
                decode_dfl(box_data, h, w, gh, gw, stride);

            // Step 4: Convert offsets to pixel coordinates.
            let cx = (w as f32 + 0.5_f32) * stride_f;
            let cy = (h as f32 + 0.5_f32) * stride_f;

            let bbox = BoundingBox::new(
                cx - dist_left * stride_f,
                cy - dist_top * stride_f,
                cx + dist_right * stride_f,
                cy + dist_bottom * stride_f,
            )
            .clamp(model_width, model_height);

            candidates.push(Candidate {
                bbox,
                class_id,
                confidence,
            });
        }
    }
}

/// Finds the class with the highest sigmoid score for a grid cell.
///
/// All class channels share the same zp/scale per tensor, and affine
/// dequantization (`scale` is positive) and sigmoid are both
/// monotonically increasing. The max raw INT8 value therefore maps to
/// the highest sigmoid score. Scanning raw bytes avoids 79 redundant
/// dequantizations and sigmoid calls on the A7 hot path.
#[expect(
    clippy::as_conversions,
    clippy::cast_possible_truncation,
    reason = "Class index c is in 0..80, fits u16. \
              usize→u16 cast is safe for values < 80."
)]
fn find_best_class(
    class_data: &[i8],
    h: usize,
    w: usize,
    grid_h: usize,
    grid_w: usize,
    stride: &StrideLevel,
) -> (u16, f32) {
    let mut best_class = 0_u16;
    let mut best_raw = read_nc1hwc2(class_data, 0, h, w, grid_h, grid_w).unwrap_or(0_i8);

    for c in 1..NUM_CLASSES {
        let raw = read_nc1hwc2(class_data, c, h, w, grid_h, grid_w).unwrap_or(0_i8);
        if raw > best_raw {
            best_raw = raw;
            best_class = c as u16;
        }
    }

    let logit = dequantize_affine(best_raw, stride.class_zp, stride.class_scale);
    (best_class, sigmoid(logit))
}

/// Decodes DFL offsets (left, top, right, bottom) for a grid cell.
///
/// For each of 4 offset directions, applies softmax over 16 DFL bins
/// and computes the expected value (weighted sum with bin indices).
#[expect(
    clippy::as_conversions,
    clippy::cast_precision_loss,
    clippy::arithmetic_side_effects,
    clippy::suboptimal_flops,
    reason = "DFL decode: dir*16+bin is max 3*16+15=63, fits usize. \
              bin index i (0..15) → f32 is exact. Weighted sum of \
              probabilities * small integers cannot overflow f32. \
              Explicit multiply-add matches the spec formula."
)]
fn decode_dfl(
    box_data: &[i8],
    h: usize,
    w: usize,
    grid_h: usize,
    grid_w: usize,
    stride: &StrideLevel,
) -> [f32; 4] {
    let mut offsets = [0.0_f32; 4];

    for (dir, offset_slot) in offsets.iter_mut().enumerate() {
        let mut logits = [0.0_f32; DFL_REG_MAX];
        for (bin, logit_slot) in logits.iter_mut().enumerate() {
            let c = dir * DFL_REG_MAX + bin;
            *logit_slot = read_dequant(
                box_data,
                c,
                h,
                w,
                grid_h,
                grid_w,
                stride.box_zp,
                stride.box_scale,
            );
        }
        let probs = softmax_16(&logits);
        let mut weighted_sum = 0.0_f32;
        for (i, &p) in probs.iter().enumerate() {
            weighted_sum += p * i as f32;
        }
        *offset_slot = weighted_sum;
    }

    offsets
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
    clippy::cast_precision_loss,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::arithmetic_side_effects,
    clippy::integer_division,
    clippy::suboptimal_flops,
    reason = "test code: indexing on known-size arrays, expect/unwrap for test assertions, \
              arithmetic and casts on small known values"
)]
mod tests {
    use super::*;

    // -----------------------------------------------------------------------
    // sigmoid
    // -----------------------------------------------------------------------

    #[test]
    fn test_sigmoid_zero() {
        let result = sigmoid(0.0_f32);
        assert!(
            (result - 0.5_f32).abs() < 1e-6_f32,
            "sigmoid(0) should be 0.5, got {result}"
        );
    }

    #[test]
    fn test_sigmoid_large_positive() {
        let result = sigmoid(20.0_f32);
        assert!(
            result > 0.999_f32,
            "sigmoid(20) should be near 1.0, got {result}"
        );
    }

    #[test]
    fn test_sigmoid_large_negative() {
        let result = sigmoid(-20.0_f32);
        assert!(
            result < 0.001_f32,
            "sigmoid(-20) should be near 0.0, got {result}"
        );
    }

    #[test]
    fn test_sigmoid_one() {
        let result = sigmoid(1.0_f32);
        // sigmoid(1) = 1/(1+e^-1) ≈ 0.7310586
        assert!(
            (result - 0.731_058_6_f32).abs() < 1e-5_f32,
            "sigmoid(1) should be ~0.7311, got {result}"
        );
    }

    #[test]
    fn test_sigmoid_negative_one() {
        let result = sigmoid(-1.0_f32);
        // sigmoid(-1) = 1/(1+e^1) ≈ 0.2689414
        assert!(
            (result - 0.268_941_4_f32).abs() < 1e-5_f32,
            "sigmoid(-1) should be ~0.2689, got {result}"
        );
    }

    #[test]
    fn test_sigmoid_extreme_positive_clamps() {
        let result = sigmoid(100.0_f32);
        assert!(
            result > 0.999_f32 && result <= 1.0_f32,
            "sigmoid(100) should saturate near 1.0, got {result}"
        );
    }

    #[test]
    fn test_sigmoid_extreme_negative_clamps() {
        let result = sigmoid(-100.0_f32);
        assert!(
            (0.0_f32..0.001_f32).contains(&result),
            "sigmoid(-100) should saturate near 0.0, got {result}"
        );
    }

    // -----------------------------------------------------------------------
    // softmax_16
    // -----------------------------------------------------------------------

    #[test]
    fn test_softmax_uniform_input() {
        let logits = [1.0_f32; DFL_REG_MAX];
        let probs = softmax_16(&logits);
        let expected = 1.0_f32 / DFL_REG_MAX as f32;
        for (i, &p) in probs.iter().enumerate() {
            assert!(
                (p - expected).abs() < 1e-5_f32,
                "uniform softmax[{i}] should be {expected}, got {p}"
            );
        }
    }

    #[test]
    fn test_softmax_dominant_value() {
        let mut logits = [0.0_f32; DFL_REG_MAX];
        logits[7] = 100.0_f32;
        let probs = softmax_16(&logits);
        assert!(
            probs[7] > 0.999_f32,
            "dominant logit should have prob ~1.0, got {}",
            probs[7]
        );
        #[expect(
            clippy::indexing_slicing,
            reason = "test with known index 0, DFL_REG_MAX >= 1"
        )]
        {
            assert!(
                probs[0] < 0.001_f32,
                "non-dominant logit should have prob ~0.0, got {}",
                probs[0]
            );
        }
    }

    #[test]
    fn test_softmax_sums_to_one() {
        let logits = [
            0.1_f32, -0.5_f32, 1.2_f32, -2.0_f32, 0.0_f32, 3.0_f32, -1.0_f32, 0.5_f32, 2.0_f32,
            -0.3_f32, 1.0_f32, -1.5_f32, 0.8_f32, -0.7_f32, 1.5_f32, -0.2_f32,
        ];
        let probs = softmax_16(&logits);
        let sum: f32 = probs.iter().sum();
        assert!(
            (sum - 1.0_f32).abs() < 1e-5_f32,
            "softmax sum should be 1.0, got {sum}"
        );
    }

    #[test]
    fn test_softmax_all_zeros() {
        let logits = [0.0_f32; DFL_REG_MAX];
        let probs = softmax_16(&logits);
        let expected = 1.0_f32 / DFL_REG_MAX as f32;
        for (i, &p) in probs.iter().enumerate() {
            assert!(
                (p - expected).abs() < 1e-5_f32,
                "all-zeros softmax[{i}] should be uniform, got {p}"
            );
        }
    }

    #[test]
    fn test_softmax_negative_values() {
        let mut logits = [-10.0_f32; DFL_REG_MAX];
        logits[3] = -1.0_f32;
        let probs = softmax_16(&logits);
        assert!(
            probs[3] > 0.99_f32,
            "least negative logit should dominate, got {}",
            probs[3]
        );
    }

    // -----------------------------------------------------------------------
    // BoundingBox
    // -----------------------------------------------------------------------

    #[test]
    fn test_bbox_new_orders_coordinates() {
        let bbox = BoundingBox::new(100.0_f32, 200.0_f32, 50.0_f32, 150.0_f32);
        assert!(
            (bbox.x1 - 50.0_f32).abs() < f32::EPSILON,
            "x1 should be min, got {}",
            bbox.x1
        );
        assert!(
            (bbox.x2 - 100.0_f32).abs() < f32::EPSILON,
            "x2 should be max, got {}",
            bbox.x2
        );
        assert!(
            (bbox.y1 - 150.0_f32).abs() < f32::EPSILON,
            "y1 should be min, got {}",
            bbox.y1
        );
        assert!(
            (bbox.y2 - 200.0_f32).abs() < f32::EPSILON,
            "y2 should be max, got {}",
            bbox.y2
        );
    }

    #[test]
    fn test_bbox_area() {
        let bbox = BoundingBox::new(10.0_f32, 20.0_f32, 110.0_f32, 70.0_f32);
        let area = bbox.area();
        assert!(
            (area - 5000.0_f32).abs() < f32::EPSILON,
            "area should be 100*50=5000, got {area}"
        );
    }

    #[test]
    fn test_bbox_area_degenerate() {
        let bbox = BoundingBox::new(10.0_f32, 20.0_f32, 10.0_f32, 20.0_f32);
        assert!(
            bbox.area().abs() < f32::EPSILON,
            "degenerate bbox should have zero area"
        );
    }

    #[test]
    fn test_bbox_area_line() {
        let bbox = BoundingBox::new(0.0_f32, 0.0_f32, 100.0_f32, 0.0_f32);
        assert!(
            bbox.area().abs() < f32::EPSILON,
            "line bbox should have zero area"
        );
    }

    #[test]
    fn test_bbox_clamp() {
        let bbox = BoundingBox::new(-10.0_f32, -5.0_f32, 700.0_f32, 500.0_f32);
        let clamped = bbox.clamp(640.0_f32, 480.0_f32);
        assert!(
            clamped.x1.abs() < f32::EPSILON,
            "clamped x1 should be 0, got {}",
            clamped.x1
        );
        assert!(
            clamped.y1.abs() < f32::EPSILON,
            "clamped y1 should be 0, got {}",
            clamped.y1
        );
        assert!(
            (clamped.x2 - 640.0_f32).abs() < f32::EPSILON,
            "clamped x2 should be 640, got {}",
            clamped.x2
        );
        assert!(
            (clamped.y2 - 480.0_f32).abs() < f32::EPSILON,
            "clamped y2 should be 480, got {}",
            clamped.y2
        );
    }

    #[test]
    fn test_bbox_clamp_already_inside() {
        let bbox = BoundingBox::new(10.0_f32, 10.0_f32, 100.0_f32, 100.0_f32);
        let clamped = bbox.clamp(640.0_f32, 480.0_f32);
        assert!(
            (clamped.x1 - bbox.x1).abs() < f32::EPSILON
                && (clamped.y1 - bbox.y1).abs() < f32::EPSILON
                && (clamped.x2 - bbox.x2).abs() < f32::EPSILON
                && (clamped.y2 - bbox.y2).abs() < f32::EPSILON,
            "already-inside bbox should be unchanged"
        );
    }

    // -----------------------------------------------------------------------
    // IoU
    // -----------------------------------------------------------------------

    #[test]
    fn test_iou_perfect_overlap() {
        let a = BoundingBox::new(0.0_f32, 0.0_f32, 100.0_f32, 100.0_f32);
        let result = iou(&a, &a);
        assert!(
            (result - 1.0_f32).abs() < 1e-5_f32,
            "IoU of identical boxes should be 1.0, got {result}"
        );
    }

    #[test]
    fn test_iou_no_overlap() {
        let a = BoundingBox::new(0.0_f32, 0.0_f32, 50.0_f32, 50.0_f32);
        let b = BoundingBox::new(100.0_f32, 100.0_f32, 200.0_f32, 200.0_f32);
        let result = iou(&a, &b);
        assert!(
            result.abs() < f32::EPSILON,
            "IoU of non-overlapping boxes should be 0.0, got {result}"
        );
    }

    #[test]
    fn test_iou_partial_overlap() {
        // a: 0,0 → 100,100 (area=10000)
        // b: 50,50 → 150,150 (area=10000)
        // intersection: 50,50 → 100,100 (area=2500)
        // union: 10000 + 10000 - 2500 = 17500
        // IoU: 2500/17500 ≈ 0.14286
        let a = BoundingBox::new(0.0_f32, 0.0_f32, 100.0_f32, 100.0_f32);
        let b = BoundingBox::new(50.0_f32, 50.0_f32, 150.0_f32, 150.0_f32);
        let result = iou(&a, &b);
        assert!(
            (result - 0.142_857_f32).abs() < 0.001_f32,
            "IoU should be ~0.1429, got {result}"
        );
    }

    #[test]
    fn test_iou_contained() {
        // b is fully inside a.
        // a: 0,0 → 100,100 (area=10000)
        // b: 25,25 → 75,75 (area=2500)
        // intersection: 2500
        // union: 10000
        // IoU: 0.25
        let a = BoundingBox::new(0.0_f32, 0.0_f32, 100.0_f32, 100.0_f32);
        let b = BoundingBox::new(25.0_f32, 25.0_f32, 75.0_f32, 75.0_f32);
        let result = iou(&a, &b);
        assert!(
            (result - 0.25_f32).abs() < 1e-5_f32,
            "IoU of contained box should be 0.25, got {result}"
        );
    }

    #[test]
    fn test_iou_symmetric() {
        let a = BoundingBox::new(10.0_f32, 20.0_f32, 80.0_f32, 90.0_f32);
        let b = BoundingBox::new(30.0_f32, 40.0_f32, 120.0_f32, 130.0_f32);
        let ab = iou(&a, &b);
        let ba = iou(&b, &a);
        assert!(
            (ab - ba).abs() < 1e-6_f32,
            "IoU should be symmetric: iou(a,b)={ab}, iou(b,a)={ba}"
        );
    }

    #[test]
    fn test_iou_degenerate_boxes() {
        let a = BoundingBox::new(0.0_f32, 0.0_f32, 0.0_f32, 0.0_f32);
        let b = BoundingBox::new(0.0_f32, 0.0_f32, 100.0_f32, 100.0_f32);
        let result = iou(&a, &b);
        assert!(
            result.abs() < f32::EPSILON,
            "IoU with degenerate box should be 0.0, got {result}"
        );
    }

    #[test]
    fn test_iou_touching_edges() {
        let a = BoundingBox::new(0.0_f32, 0.0_f32, 50.0_f32, 50.0_f32);
        let b = BoundingBox::new(50.0_f32, 0.0_f32, 100.0_f32, 50.0_f32);
        let result = iou(&a, &b);
        assert!(
            result.abs() < f32::EPSILON,
            "IoU of edge-touching boxes should be 0.0, got {result}"
        );
    }

    // -----------------------------------------------------------------------
    // NC1HWC2 inline read
    // -----------------------------------------------------------------------

    #[test]
    fn test_read_nc1hwc2_single_channel() {
        // 1 channel, 2x2 spatial, C2=16. Data: [1, 1, 2, 2, 16].
        // Only channel 0 has data, channels 1-15 are padding.
        let mut data = vec![0_i8; 64]; // 1 * 2 * 2 * 16
        // (c=0, h=0, w=0): c1=0, c2=0, offset = ((0*2+0)*2+0)*16+0 = 0
        data[0] = 10_i8;
        // (c=0, h=0, w=1): offset = ((0*2+0)*2+1)*16+0 = 16
        data[16] = 20_i8;
        // (c=0, h=1, w=0): offset = ((0*2+1)*2+0)*16+0 = 32
        data[32] = 30_i8;
        // (c=0, h=1, w=1): offset = ((0*2+1)*2+1)*16+0 = 48
        data[48] = 40_i8;

        assert_eq!(
            read_nc1hwc2(&data, 0, 0, 0, 2, 2),
            Some(10_i8),
            "channel 0, h=0, w=0"
        );
        assert_eq!(
            read_nc1hwc2(&data, 0, 0, 1, 2, 2),
            Some(20_i8),
            "channel 0, h=0, w=1"
        );
        assert_eq!(
            read_nc1hwc2(&data, 0, 1, 0, 2, 2),
            Some(30_i8),
            "channel 0, h=1, w=0"
        );
        assert_eq!(
            read_nc1hwc2(&data, 0, 1, 1, 2, 2),
            Some(40_i8),
            "channel 0, h=1, w=1"
        );
    }

    #[test]
    fn test_read_nc1hwc2_multi_channel() {
        // 4 channels, 1x1 spatial, C2=16. Data: [1, 1, 1, 1, 16].
        let mut data = vec![0_i8; 16];
        data[0] = 10_i8; // channel 0
        data[1] = 20_i8; // channel 1
        data[2] = 30_i8; // channel 2
        data[3] = 40_i8; // channel 3

        assert_eq!(read_nc1hwc2(&data, 0, 0, 0, 1, 1), Some(10_i8), "channel 0");
        assert_eq!(read_nc1hwc2(&data, 1, 0, 0, 1, 1), Some(20_i8), "channel 1");
        assert_eq!(read_nc1hwc2(&data, 2, 0, 0, 1, 1), Some(30_i8), "channel 2");
        assert_eq!(read_nc1hwc2(&data, 3, 0, 0, 1, 1), Some(40_i8), "channel 3");
    }

    #[test]
    fn test_read_nc1hwc2_cross_block() {
        // 20 channels, 1x1 spatial, C2=16.
        // Channels 0-15 in block 0, channels 16-19 in block 1.
        let mut data = vec![0_i8; 32]; // 2 blocks * 1 * 1 * 16
        data[0] = 1_i8; // channel 0, block 0
        data[15] = 2_i8; // channel 15, block 0
        data[16] = 3_i8; // channel 16, block 1, c2_idx=0
        data[19] = 4_i8; // channel 19, block 1, c2_idx=3

        assert_eq!(read_nc1hwc2(&data, 0, 0, 0, 1, 1), Some(1_i8), "channel 0");
        assert_eq!(
            read_nc1hwc2(&data, 15, 0, 0, 1, 1),
            Some(2_i8),
            "channel 15"
        );
        assert_eq!(
            read_nc1hwc2(&data, 16, 0, 0, 1, 1),
            Some(3_i8),
            "channel 16"
        );
        assert_eq!(
            read_nc1hwc2(&data, 19, 0, 0, 1, 1),
            Some(4_i8),
            "channel 19"
        );
    }

    #[test]
    fn test_read_nc1hwc2_out_of_bounds() {
        let data = vec![0_i8; 16];
        assert_eq!(
            read_nc1hwc2(&data, 0, 0, 0, 1, 1),
            Some(0_i8),
            "in-bounds read"
        );
        assert_eq!(
            read_nc1hwc2(&data, 16, 0, 0, 1, 1),
            None,
            "out-of-bounds channel"
        );
        assert_eq!(
            read_nc1hwc2(&data, 0, 1, 0, 1, 1),
            None,
            "out-of-bounds height"
        );
    }

    // -----------------------------------------------------------------------
    // DFL decode
    // -----------------------------------------------------------------------

    #[test]
    fn test_dfl_uniform_distribution() {
        // Uniform softmax over [0..15] gives expected value 7.5.
        let logits = [0.0_f32; DFL_REG_MAX];
        let probs = softmax_16(&logits);
        let mut expected_val = 0.0_f32;
        #[expect(
            clippy::as_conversions,
            clippy::cast_precision_loss,
            clippy::arithmetic_side_effects,
            reason = "test: i (0..15) → f32 is exact, sum of small products"
        )]
        for (i, &p) in probs.iter().enumerate() {
            expected_val += p * i as f32;
        }
        assert!(
            (expected_val - 7.5_f32).abs() < 0.01_f32,
            "uniform DFL offset should be 7.5, got {expected_val}"
        );
    }

    #[test]
    fn test_dfl_one_hot_bin_zero() {
        let mut logits = [-100.0_f32; DFL_REG_MAX];
        logits[0] = 100.0_f32;
        let probs = softmax_16(&logits);
        let mut offset = 0.0_f32;
        #[expect(
            clippy::as_conversions,
            clippy::cast_precision_loss,
            clippy::arithmetic_side_effects,
            reason = "test: computing DFL weighted sum"
        )]
        for (i, &p) in probs.iter().enumerate() {
            offset += p * i as f32;
        }
        assert!(
            offset.abs() < 0.01_f32,
            "one-hot bin 0 offset should be ~0.0, got {offset}"
        );
    }

    #[test]
    fn test_dfl_one_hot_bin_fifteen() {
        let mut logits = [-100.0_f32; DFL_REG_MAX];
        logits[15] = 100.0_f32;
        let probs = softmax_16(&logits);
        let mut offset = 0.0_f32;
        #[expect(
            clippy::as_conversions,
            clippy::cast_precision_loss,
            clippy::arithmetic_side_effects,
            reason = "test: computing DFL weighted sum"
        )]
        for (i, &p) in probs.iter().enumerate() {
            offset += p * i as f32;
        }
        assert!(
            (offset - 15.0_f32).abs() < 0.01_f32,
            "one-hot bin 15 offset should be ~15.0, got {offset}"
        );
    }

    // -----------------------------------------------------------------------
    // NMS
    // -----------------------------------------------------------------------

    #[test]
    fn test_nms_single_detection() {
        let mut detector = make_test_detector();
        detector.candidates.push(Candidate {
            bbox: BoundingBox::new(10.0_f32, 10.0_f32, 50.0_f32, 50.0_f32),
            class_id: 15,
            confidence: 0.9_f32,
        });
        detector.nms();
        assert_eq!(detector.detections.len(), 1, "single detection passes NMS");
        assert_eq!(
            detector.detections.first().map(|d| d.class_id),
            Some(15),
            "class_id preserved"
        );
    }

    #[test]
    fn test_nms_suppresses_overlap() {
        let mut detector = make_test_detector();
        detector.candidates.push(Candidate {
            bbox: BoundingBox::new(0.0_f32, 0.0_f32, 100.0_f32, 100.0_f32),
            class_id: 15,
            confidence: 0.9_f32,
        });
        detector.candidates.push(Candidate {
            bbox: BoundingBox::new(10.0_f32, 10.0_f32, 110.0_f32, 110.0_f32),
            class_id: 15,
            confidence: 0.7_f32,
        });
        detector.nms();
        assert_eq!(
            detector.detections.len(),
            1,
            "overlapping detection should be suppressed"
        );
        assert!(
            detector
                .detections
                .first()
                .is_some_and(|d| (d.confidence - 0.9_f32).abs() < f32::EPSILON),
            "higher confidence detection should survive"
        );
    }

    #[test]
    fn test_nms_preserves_cross_class_overlap() {
        let mut detector = make_test_detector();
        detector.candidates.push(Candidate {
            bbox: BoundingBox::new(0.0_f32, 0.0_f32, 100.0_f32, 100.0_f32),
            class_id: 15, // cat
            confidence: 0.9_f32,
        });
        detector.candidates.push(Candidate {
            bbox: BoundingBox::new(10.0_f32, 10.0_f32, 110.0_f32, 110.0_f32),
            class_id: 0, // person
            confidence: 0.7_f32,
        });
        detector.nms();
        assert_eq!(
            detector.detections.len(),
            2,
            "overlapping detections of different classes must both survive NMS"
        );
    }

    #[test]
    fn test_nms_preserves_non_overlapping() {
        let mut detector = make_test_detector();
        detector.candidates.push(Candidate {
            bbox: BoundingBox::new(0.0_f32, 0.0_f32, 50.0_f32, 50.0_f32),
            class_id: 15,
            confidence: 0.9_f32,
        });
        detector.candidates.push(Candidate {
            bbox: BoundingBox::new(200.0_f32, 200.0_f32, 300.0_f32, 300.0_f32),
            class_id: 0,
            confidence: 0.8_f32,
        });
        detector.nms();
        assert_eq!(
            detector.detections.len(),
            2,
            "non-overlapping detections both survive"
        );
    }

    #[test]
    fn test_nms_respects_max_detections() {
        let mut detector = make_test_detector();
        detector.config.max_detections = 2;
        for i in 0..5_u16 {
            #[expect(
                clippy::as_conversions,
                clippy::arithmetic_side_effects,
                reason = "test: small loop counter arithmetic"
            )]
            let offset = f32::from(i) * 200.0_f32;
            detector.candidates.push(Candidate {
                bbox: BoundingBox::new(offset, 0.0_f32, offset + 50.0_f32, 50.0_f32),
                class_id: i,
                confidence: 0.9_f32 - f32::from(i) * 0.1_f32,
            });
        }
        detector.nms();
        assert_eq!(detector.detections.len(), 2, "should cap at max_detections");
    }

    #[test]
    fn test_nms_empty_input() {
        let mut detector = make_test_detector();
        detector.nms();
        assert!(
            detector.detections.is_empty(),
            "NMS on empty candidates should produce empty output"
        );
    }

    #[test]
    fn test_nms_sorted_by_confidence() {
        let mut detector = make_test_detector();
        detector.config.max_detections = 100;
        for i in 0..5_u16 {
            #[expect(
                clippy::as_conversions,
                clippy::arithmetic_side_effects,
                reason = "test: small loop counter arithmetic"
            )]
            let offset = f32::from(i) * 200.0_f32;
            detector.candidates.push(Candidate {
                bbox: BoundingBox::new(offset, 0.0_f32, offset + 50.0_f32, 50.0_f32),
                class_id: i,
                confidence: 0.5_f32 + f32::from(i) * 0.05_f32,
            });
        }
        detector.nms();

        for pair in detector.detections.windows(2) {
            let (a, b) = (pair.first(), pair.get(1));
            if let (Some(a), Some(b)) = (a, b) {
                assert!(
                    a.confidence >= b.confidence,
                    "NMS output should be sorted descending: {} < {}",
                    a.confidence,
                    b.confidence
                );
            }
        }
    }

    // -----------------------------------------------------------------------
    // Tensor role identification
    // -----------------------------------------------------------------------

    #[test]
    fn test_identify_box_tensor() {
        let attr = make_nc1hwc2_attr(0, 4, 80, 60, 16);
        let id = identify_tensor(&attr).expect("box tensor should be identified");
        assert_eq!(id.role, TensorRole::Box, "64 channels = box tensor");
        assert_eq!(id.grid_h, 80, "grid height");
        assert_eq!(id.grid_w, 60, "grid width");
    }

    #[test]
    fn test_identify_class_tensor() {
        let attr = make_nc1hwc2_attr(1, 5, 80, 60, 16);
        let id = identify_tensor(&attr).expect("class tensor should be identified");
        assert_eq!(id.role, TensorRole::Class, "80 channels = class tensor");
    }

    #[test]
    fn test_identify_score_tensor() {
        let attr = make_nc1hwc2_attr(2, 1, 80, 60, 16);
        let id = identify_tensor(&attr).expect("score tensor should be identified");
        assert_eq!(id.role, TensorRole::Score, "1 channel = score tensor");
    }

    #[test]
    fn test_identify_wrong_format() {
        let mut attr = make_nc1hwc2_attr(0, 4, 80, 60, 16);
        attr.format = TensorFormat::Nchw;
        let err = identify_tensor(&attr).unwrap_err();
        assert!(
            matches!(err, DetectError::WrongFormat { index: 0, .. }),
            "wrong format: {err}"
        );
    }

    #[test]
    fn test_identify_wrong_data_type() {
        let mut attr = make_nc1hwc2_attr(0, 4, 80, 60, 16);
        attr.data_type = TensorType::Float32;
        let err = identify_tensor(&attr).unwrap_err();
        assert!(
            matches!(err, DetectError::WrongDataType { index: 0, .. }),
            "wrong data type: {err}"
        );
    }

    #[test]
    fn test_identify_wrong_quant_type() {
        let mut attr = make_nc1hwc2_attr(0, 4, 80, 60, 16);
        attr.qnt_type = QuantType::None;
        let err = identify_tensor(&attr).unwrap_err();
        assert!(
            matches!(err, DetectError::WrongQuantType { index: 0, .. }),
            "wrong quant type: {err}"
        );
    }

    #[test]
    fn test_identify_wrong_dim_count() {
        let mut attr = make_nc1hwc2_attr(0, 4, 80, 60, 16);
        attr.n_dims = 4;
        let err = identify_tensor(&attr).unwrap_err();
        assert!(
            matches!(
                err,
                DetectError::WrongDimCount {
                    index: 0,
                    n_dims: 4
                }
            ),
            "wrong dim count: {err}"
        );
    }

    #[test]
    fn test_identify_unrecognized_channels() {
        // C1=3 × C2=16 = 48 channels — not a known role.
        let attr = make_nc1hwc2_attr(5, 3, 40, 30, 16);
        let err = identify_tensor(&attr).unwrap_err();
        assert!(
            matches!(
                err,
                DetectError::UnrecognizedTensor {
                    index: 5,
                    channels: 48,
                    ..
                }
            ),
            "unrecognized tensor: {err}"
        );
    }

    // -----------------------------------------------------------------------
    // Stride level construction
    // -----------------------------------------------------------------------

    #[test]
    fn test_build_stride_levels_valid() {
        let identities = make_standard_identities(640, 480);
        let levels = build_stride_levels(&identities, 640, 480, 0.25_f32)
            .expect("valid identities should produce stride levels");

        // Sorted by grid area descending (largest grid first = smallest stride).
        assert_eq!(levels[0].stride, 8, "first stride level");
        assert_eq!(levels[1].stride, 16, "second stride level");
        assert_eq!(levels[2].stride, 32, "third stride level");

        assert_eq!(levels[0].grid_h, 60, "stride 8 grid height");
        assert_eq!(levels[0].grid_w, 80, "stride 8 grid width");
        assert_eq!(levels[1].grid_h, 30, "stride 16 grid height");
        assert_eq!(levels[1].grid_w, 40, "stride 16 grid width");
        assert_eq!(levels[2].grid_h, 15, "stride 32 grid height");
        assert_eq!(levels[2].grid_w, 20, "stride 32 grid width");
    }

    #[test]
    fn test_build_stride_levels_640x640() {
        let identities = make_standard_identities(640, 640);
        let levels = build_stride_levels(&identities, 640, 640, 0.25_f32)
            .expect("640x640 model should work");

        assert_eq!(levels[0].grid_h, 80, "stride 8 grid 80x80");
        assert_eq!(levels[0].grid_w, 80, "stride 8 grid 80x80");
        assert_eq!(levels[1].grid_h, 40, "stride 16 grid 40x40");
        assert_eq!(levels[2].grid_h, 20, "stride 32 grid 20x20");
    }

    #[test]
    fn test_build_stride_levels_missing_tensor() {
        // Remove the box tensor for stride 8.
        let mut identities = make_standard_identities(640, 480);
        identities.retain(|id| !(id.role == TensorRole::Box && id.grid_h == 60));
        let err = build_stride_levels(&identities, 640, 480, 0.25_f32).unwrap_err();
        assert!(
            matches!(
                err,
                DetectError::StrideLevelCount { .. } | DetectError::MissingTensor { .. }
            ),
            "missing tensor should fail: {err}"
        );
    }

    // -----------------------------------------------------------------------
    // Integration: synthetic tensor end-to-end
    // -----------------------------------------------------------------------

    #[test]
    fn test_process_stride_with_synthetic_data() {
        // Place a strong cat detection at grid cell (2, 3) in a 4x5 grid
        // (stride 8, model 40x32).
        let grid_h: usize = 4;
        let grid_w: usize = 5;

        let score_data = build_score_tensor(grid_h, grid_w, 2, 3, 100_i8);
        let class_data = build_class_tensor(grid_h, grid_w, 2, 3, 15, 100_i8);
        let box_data = build_box_tensor(grid_h, grid_w, 2, 3, [3.0_f32, 2.0_f32, 4.0_f32, 5.0_f32]);

        let score_threshold = 0.1_f32;
        let stride = StrideLevel {
            stride: 8,
            grid_h: 4,
            grid_w: 5,
            box_idx: 0,
            class_idx: 1,
            score_idx: 2,
            box_zp: 0,
            box_scale: 1.0_f32,
            class_zp: -128_i32,
            class_scale: 0.1_f32,
            score_zp: -128_i32,
            score_scale: 0.1_f32,
            score_threshold_i8: compute_score_threshold_i8(score_threshold, -128_i32, 0.1_f32),
        };

        let mut detector = Detector {
            config: DetectionConfig {
                score_threshold,
                confidence_threshold: 0.51_f32,
                nms_iou_threshold: 0.45_f32,
                max_detections: 20,
            },
            strides: [stride.clone(), stride.clone(), stride.clone()],
            model_width: 40.0_f32,
            model_height: 32.0_f32,
            candidates: Vec::new(),
            suppressed: Vec::new(),
            detections: Vec::new(),
        };

        process_stride(
            &detector.config,
            &stride,
            detector.model_width,
            detector.model_height,
            &box_data,
            &class_data,
            &score_data,
            &mut detector.candidates,
        );

        assert!(
            !detector.candidates.is_empty(),
            "should produce at least one candidate"
        );

        // The detection at cell (h=2, w=3) should be a cat (class 15).
        let cat_candidates: Vec<&Candidate> = detector
            .candidates
            .iter()
            .filter(|c| c.class_id == 15)
            .collect();

        assert!(!cat_candidates.is_empty(), "should detect a cat at (2,3)");

        let best = cat_candidates
            .iter()
            .max_by(|a, b| a.confidence.total_cmp(&b.confidence));

        if let Some(det) = best {
            // Cell center: cx = (3 + 0.5) * 8 = 28.0, cy = (2 + 0.5) * 8 = 20.0
            // Offsets: left=3, top=2, right=4, bottom=5
            // x1 = 28 - 3*8 = 4, y1 = 20 - 2*8 = 4
            // x2 = 28 + 4*8 = 60 → clamped to 40, y2 = 20 + 5*8 = 60 → clamped to 32
            assert!(
                det.bbox.x1 < 10.0_f32,
                "x1 should be near 4.0, got {}",
                det.bbox.x1
            );
            assert!(
                det.bbox.y1 < 10.0_f32,
                "y1 should be near 4.0, got {}",
                det.bbox.y1
            );
            assert!(
                det.confidence > 0.51_f32,
                "confidence should exceed threshold, got {}",
                det.confidence
            );
        }
    }

    #[test]
    fn test_process_stride_filters_low_score() {
        let grid_h: usize = 2;
        let grid_w: usize = 2;

        // All score tensor values are low (raw = -128, dequant = 0.0 with zp=-128).
        let score_data = vec![0_i8; grid_h * grid_w * C2];
        let class_data = vec![0_i8; 5 * grid_h * grid_w * C2]; // 80ch, C1=5
        let box_data = vec![0_i8; 4 * grid_h * grid_w * C2]; // 64ch, C1=4

        let mut detector = make_test_detector();
        let stride = StrideLevel {
            stride: 8,
            grid_h: 2,
            grid_w: 2,
            box_idx: 0,
            class_idx: 1,
            score_idx: 2,
            box_zp: 0,
            box_scale: 1.0_f32,
            class_zp: 0,
            class_scale: 1.0_f32,
            score_zp: 0,
            score_scale: 0.001_f32,
            score_threshold_i8: compute_score_threshold_i8(
                detector.config.score_threshold,
                0,
                0.001_f32,
            ),
        };
        process_stride(
            &detector.config,
            &stride,
            detector.model_width,
            detector.model_height,
            &box_data,
            &class_data,
            &score_data,
            &mut detector.candidates,
        );

        assert!(
            detector.candidates.is_empty(),
            "all cells should be filtered by low score"
        );
    }

    // -----------------------------------------------------------------------
    // Error display snapshots
    // -----------------------------------------------------------------------

    #[test]
    fn test_error_display_output_count() {
        let err = DetectError::OutputCount { actual: 6 };
        insta::assert_snapshot!(err.to_string(), @"expected 9 output tensors, model has 6");
    }

    #[test]
    fn test_error_display_wrong_format() {
        let err = DetectError::WrongFormat {
            index: 3,
            format: TensorFormat::Nchw,
        };
        insta::assert_snapshot!(err.to_string(), @"output tensor 3 is not NC1HWC2 format (got Nchw)");
    }

    #[test]
    fn test_error_display_wrong_data_type() {
        let err = DetectError::WrongDataType {
            index: 0,
            data_type: TensorType::Float32,
        };
        insta::assert_snapshot!(err.to_string(), @"output tensor 0 is not INT8 type (got Float32)");
    }

    #[test]
    fn test_error_display_wrong_quant_type() {
        let err = DetectError::WrongQuantType {
            index: 1,
            qnt_type: QuantType::None,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"output tensor 1 is not affine asymmetric quantized (got None)"
        );
    }

    #[test]
    fn test_error_display_wrong_dim_count() {
        let err = DetectError::WrongDimCount {
            index: 2,
            n_dims: 4,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"output tensor 2 has 4 dimensions, expected 5 for NC1HWC2"
        );
    }

    #[test]
    fn test_error_display_unrecognized_tensor() {
        let err = DetectError::UnrecognizedTensor {
            index: 5,
            c1: 3,
            c2: 16,
            channels: 48,
            height: 40,
            width: 30,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"cannot identify role of output tensor 5: C1=3, C2=16 (48 logical channels), 40x30 spatial"
        );
    }

    #[test]
    fn test_error_display_missing_tensor() {
        let err = DetectError::MissingTensor {
            role: "box",
            grid_h: 80,
            grid_w: 60,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"stride level with grid 80x60: missing box tensor"
        );
    }

    #[test]
    fn test_error_display_stride_mismatch() {
        let err = DetectError::StrideMismatch {
            stride_x: 8,
            stride_y: 10,
            grid_w: 80,
            grid_h: 48,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"stride mismatch for grid 48x80: horizontal stride 8, vertical stride 10"
        );
    }

    #[test]
    fn test_error_display_indivisible_grid() {
        let err = DetectError::IndivisibleGrid {
            model_dim: 640,
            grid_dim: 47,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"model input 640px is not evenly divisible by grid dimension 47"
        );
    }

    #[test]
    fn test_error_display_stride_level_count() {
        let err = DetectError::StrideLevelCount { actual: 2 };
        insta::assert_snapshot!(err.to_string(), @"expected 3 stride levels, found 2");
    }

    // -----------------------------------------------------------------------
    // DetectionConfig
    // -----------------------------------------------------------------------

    #[test]
    fn test_detection_config_default() {
        let config = DetectionConfig::default();
        assert!(
            (config.score_threshold - 0.25_f32).abs() < f32::EPSILON,
            "default score_threshold"
        );
        assert!(
            (config.confidence_threshold - 0.51_f32).abs() < f32::EPSILON,
            "default confidence_threshold"
        );
        assert!(
            (config.nms_iou_threshold - 0.45_f32).abs() < f32::EPSILON,
            "default nms_iou_threshold"
        );
        assert_eq!(config.max_detections, 20, "default max_detections");
    }

    // -----------------------------------------------------------------------
    // proptest
    // -----------------------------------------------------------------------

    #[expect(
        clippy::arithmetic_side_effects,
        clippy::as_conversions,
        clippy::cast_precision_loss,
        reason = "proptest module: arithmetic on small test values, intentional f32 casts"
    )]
    mod proptests {
        use proptest::prelude::*;

        use super::*;

        proptest! {
            #[test]
            fn sigmoid_always_in_unit_interval(x in -1000.0_f32..1000.0_f32) {
                let result = sigmoid(x);
                prop_assert!(
                    (0.0_f32..=1.0_f32).contains(&result),
                    "sigmoid({x}) = {result}, expected [0, 1]"
                );
            }

            #[test]
            fn sigmoid_monotonically_increasing(
                x in -50.0_f32..50.0_f32,
                delta in 0.001_f32..10.0_f32,
            ) {
                let y1 = sigmoid(x);
                let y2 = sigmoid(x + delta);
                prop_assert!(
                    y2 >= y1,
                    "sigmoid should be monotonic: sigmoid({}) = {} > sigmoid({}) = {}",
                    x + delta, y2, x, y1
                );
            }

            #[test]
            fn softmax_sums_to_one(
                v0 in -10.0_f32..10.0_f32,
                v1 in -10.0_f32..10.0_f32,
                v2 in -10.0_f32..10.0_f32,
                v3 in -10.0_f32..10.0_f32,
                v4 in -10.0_f32..10.0_f32,
                v5 in -10.0_f32..10.0_f32,
                v6 in -10.0_f32..10.0_f32,
                v7 in -10.0_f32..10.0_f32,
                v8 in -10.0_f32..10.0_f32,
                v9 in -10.0_f32..10.0_f32,
                v10 in -10.0_f32..10.0_f32,
                v11 in -10.0_f32..10.0_f32,
                v12 in -10.0_f32..10.0_f32,
                v13 in -10.0_f32..10.0_f32,
                v14 in -10.0_f32..10.0_f32,
                v15 in -10.0_f32..10.0_f32,
            ) {
                let logits = [v0, v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15];
                let probs = softmax_16(&logits);
                let sum: f32 = probs.iter().sum();
                prop_assert!(
                    (sum - 1.0_f32).abs() < 1e-4_f32,
                    "softmax sum should be ~1.0, got {sum}"
                );
                for (i, &p) in probs.iter().enumerate() {
                    prop_assert!(
                        p >= 0.0_f32,
                        "softmax[{i}] should be non-negative, got {p}"
                    );
                }
            }

            #[test]
            fn iou_is_symmetric(
                x1 in 0.0_f32..500.0_f32,
                y1 in 0.0_f32..500.0_f32,
                w1 in 1.0_f32..200.0_f32,
                h1 in 1.0_f32..200.0_f32,
                x2 in 0.0_f32..500.0_f32,
                y2 in 0.0_f32..500.0_f32,
                w2 in 1.0_f32..200.0_f32,
                h2 in 1.0_f32..200.0_f32,
            ) {
                let a = BoundingBox::new(x1, y1, x1 + w1, y1 + h1);
                let b = BoundingBox::new(x2, y2, x2 + w2, y2 + h2);
                let ab = iou(&a, &b);
                let ba = iou(&b, &a);
                prop_assert!(
                    (ab - ba).abs() < 1e-5_f32,
                    "IoU not symmetric: iou(a,b)={ab}, iou(b,a)={ba}"
                );
            }

            #[test]
            fn iou_self_is_one(
                x in 0.0_f32..500.0_f32,
                y in 0.0_f32..500.0_f32,
                w in 1.0_f32..200.0_f32,
                h in 1.0_f32..200.0_f32,
            ) {
                let a = BoundingBox::new(x, y, x + w, y + h);
                let result = iou(&a, &a);
                prop_assert!(
                    (result - 1.0_f32).abs() < 1e-5_f32,
                    "IoU(self) should be 1.0, got {result}"
                );
            }

            #[test]
            fn iou_in_unit_interval(
                x1 in 0.0_f32..500.0_f32,
                y1 in 0.0_f32..500.0_f32,
                w1 in 1.0_f32..200.0_f32,
                h1 in 1.0_f32..200.0_f32,
                x2 in 0.0_f32..500.0_f32,
                y2 in 0.0_f32..500.0_f32,
                w2 in 1.0_f32..200.0_f32,
                h2 in 1.0_f32..200.0_f32,
            ) {
                let a = BoundingBox::new(x1, y1, x1 + w1, y1 + h1);
                let b = BoundingBox::new(x2, y2, x2 + w2, y2 + h2);
                let result = iou(&a, &b);
                prop_assert!(
                    (0.0_f32..=1.0_f32).contains(&result),
                    "IoU should be in [0, 1], got {result}"
                );
            }

            #[test]
            fn nms_output_is_subset_sorted_no_high_iou(
                n in 2_usize..20,
                seed in 0_u64..10000,
            ) {
                use std::collections::HashSet;

                let mut detector = make_test_detector();
                detector.config.max_detections = 100;
                detector.config.nms_iou_threshold = 0.45_f32;

                // Generate non-overlapping candidates with deterministic positions.
                let mut rng_state = seed;
                for i in 0..n {
                    // Simple LCG for deterministic pseudo-random in proptest.
                    rng_state = rng_state.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1);
                    let x = (rng_state % 500) as f32;
                    rng_state = rng_state.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1);
                    let y = (rng_state % 500) as f32;
                    rng_state = rng_state.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1);
                    let conf = 0.5_f32 + (rng_state % 50) as f32 * 0.01_f32;

                    detector.candidates.push(Candidate {
                        bbox: BoundingBox::new(x, y, x + 30.0_f32, y + 30.0_f32),
                        class_id: i as u16,
                        confidence: conf,
                    });
                }

                let input_confs: HashSet<u32> = detector
                    .candidates
                    .iter()
                    .map(|c| c.confidence.to_bits())
                    .collect();

                detector.nms();

                // Output is a subset of input.
                for det in &detector.detections {
                    prop_assert!(
                        input_confs.contains(&det.confidence.to_bits()),
                        "output detection not found in input"
                    );
                }

                // Output is sorted by confidence descending.
                for pair in detector.detections.windows(2) {
                    if let (Some(a), Some(b)) = (pair.first(), pair.get(1)) {
                        prop_assert!(
                            a.confidence >= b.confidence,
                            "not sorted: {} < {}", a.confidence, b.confidence
                        );
                    }
                }

                // No same-class pair in output has IoU > threshold.
                // Per-class NMS allows cross-class overlap (e.g. cat + person).
                for i in 0..detector.detections.len() {
                    for j in (i + 1)..detector.detections.len() {
                        if let (Some(a), Some(b)) = (
                            detector.detections.get(i),
                            detector.detections.get(j),
                        ) && a.class_id == b.class_id {
                            let overlap = iou(&a.bbox, &b.bbox);
                            prop_assert!(
                                overlap <= detector.config.nms_iou_threshold,
                                "NMS output same-class pair ({i},{j}) has IoU {overlap} > threshold"
                            );
                        }
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Test helpers
    // -----------------------------------------------------------------------

    /// Creates a `Detector` with default config and dummy stride levels for NMS tests.
    fn make_test_detector() -> Detector {
        let config = DetectionConfig::default();
        let dummy_stride = StrideLevel {
            stride: 8,
            grid_h: 1,
            grid_w: 1,
            box_idx: 0,
            class_idx: 1,
            score_idx: 2,
            box_zp: 0,
            box_scale: 1.0_f32,
            class_zp: 0,
            class_scale: 1.0_f32,
            score_zp: 0,
            score_scale: 1.0_f32,
            score_threshold_i8: compute_score_threshold_i8(config.score_threshold, 0, 1.0_f32),
        };
        Detector {
            config,
            strides: [dummy_stride.clone(), dummy_stride.clone(), dummy_stride],
            model_width: 640.0_f32,
            model_height: 480.0_f32,
            candidates: Vec::new(),
            suppressed: Vec::new(),
            detections: Vec::new(),
        }
    }

    /// Creates a `TensorAttr` with NC1HWC2 format for testing tensor identification.
    fn make_nc1hwc2_attr(index: u32, c1: u32, grid_h: u32, grid_w: u32, c2: u32) -> TensorAttr {
        let mut dims = [0_u32; 16];
        dims[0] = 1;
        dims[1] = c1;
        dims[2] = grid_h;
        dims[3] = grid_w;
        dims[4] = c2;

        TensorAttr {
            index,
            n_dims: 5,
            dims,
            n_elems: c1
                .saturating_mul(grid_h)
                .saturating_mul(grid_w)
                .saturating_mul(c2),
            size: c1
                .saturating_mul(grid_h)
                .saturating_mul(grid_w)
                .saturating_mul(c2),
            format: TensorFormat::Nc1hwc2,
            data_type: TensorType::Int8,
            qnt_type: QuantType::AffineAsymmetric,
            zp: -128_i32,
            scale: 0.003_452_f32,
            w_stride: 0,
            size_with_stride: c1
                .saturating_mul(grid_h)
                .saturating_mul(grid_w)
                .saturating_mul(c2),
            h_stride: 0,
        }
    }

    /// Creates the standard 9 tensor identities for a given model size.
    ///
    /// Produces 3 stride levels (8, 16, 32) with box/class/score tensors each.
    #[expect(
        clippy::integer_division,
        reason = "test helper: model dims are exact multiples of strides"
    )]
    fn make_standard_identities(model_w: u32, model_h: u32) -> Vec<TensorIdentity> {
        let strides = [8_u32, 16, 32];
        let mut identities = Vec::with_capacity(9);
        let mut idx = 0_u32;

        for &s in &strides {
            let gh = model_h / s;
            let gw = model_w / s;

            identities.push(TensorIdentity {
                index: idx,
                role: TensorRole::Box,
                grid_h: gh,
                grid_w: gw,
                zp: -56_i32,
                scale: 0.110_522_f32,
            });
            idx = idx.saturating_add(1);

            identities.push(TensorIdentity {
                index: idx,
                role: TensorRole::Class,
                grid_h: gh,
                grid_w: gw,
                zp: -128_i32,
                scale: 0.003_452_f32,
            });
            idx = idx.saturating_add(1);

            identities.push(TensorIdentity {
                index: idx,
                role: TensorRole::Score,
                grid_h: gh,
                grid_w: gw,
                zp: -128_i32,
                scale: 0.003_482_f32,
            });
            idx = idx.saturating_add(1);
        }

        identities
    }

    /// Builds a score tensor (1 channel, NC1HWC2) with one hot cell.
    ///
    /// All cells default to zero (dequantized = 0 with zp=0). The cell at
    /// `(hot_h, hot_w)` is set to `hot_value`.
    fn build_score_tensor(
        grid_h: usize,
        grid_w: usize,
        hot_h: usize,
        hot_w: usize,
        hot_value: i8,
    ) -> Vec<i8> {
        // Score: 1 channel, C1=1. NC1HWC2 size = 1 * grid_h * grid_w * C2.
        #[expect(
            clippy::arithmetic_side_effects,
            reason = "test helper: small grid dims, product cannot overflow"
        )]
        let size = grid_h * grid_w * C2;
        let mut data = vec![0_i8; size];

        // Channel 0 at (hot_h, hot_w): offset = ((0*grid_h + hot_h) * grid_w + hot_w) * C2 + 0
        #[expect(
            clippy::arithmetic_side_effects,
            reason = "test helper: hot_h < grid_h, hot_w < grid_w, product fits usize"
        )]
        let offset = (hot_h * grid_w + hot_w) * C2;
        if let Some(slot) = data.get_mut(offset) {
            *slot = hot_value;
        }

        data
    }

    /// Builds a class tensor (80 channels, NC1HWC2) with one hot cell and class.
    ///
    /// All cells default to -128 (dequantized ≈ 0 with typical zp=-128).
    /// The cell at `(hot_h, hot_w)` has `hot_class` set to `hot_value`
    /// (other classes at that cell remain at -128).
    fn build_class_tensor(
        grid_h: usize,
        grid_w: usize,
        hot_h: usize,
        hot_w: usize,
        hot_class: usize,
        hot_value: i8,
    ) -> Vec<i8> {
        // Class: 80 channels, C1=5. NC1HWC2 size = 5 * grid_h * grid_w * C2.
        let c1: usize = 5;
        #[expect(
            clippy::arithmetic_side_effects,
            reason = "test helper: small tensor dims"
        )]
        let size = c1 * grid_h * grid_w * C2;
        let mut data = vec![-128_i8; size];

        // Set the hot class at the target cell.
        #[expect(
            clippy::arithmetic_side_effects,
            clippy::integer_division,
            reason = "test helper: NC1HWC2 index math with known small values"
        )]
        {
            let c1_idx = hot_class / C2;
            let c2_idx = hot_class % C2;
            let offset = ((c1_idx * grid_h + hot_h) * grid_w + hot_w) * C2 + c2_idx;
            if let Some(slot) = data.get_mut(offset) {
                *slot = hot_value;
            }
        }

        data
    }

    /// Builds a box tensor (64 channels, NC1HWC2) that produces specific DFL
    /// offsets at one grid cell.
    ///
    /// Sets up the DFL bins so that each offset direction has a near-one-hot
    /// distribution at the bin closest to the target offset value. The tensor
    /// uses `zp=0, scale=1.0` for simple dequantization in tests.
    fn build_box_tensor(
        grid_h: usize,
        grid_w: usize,
        hot_h: usize,
        hot_w: usize,
        target_offsets: [f32; 4],
    ) -> Vec<i8> {
        let c1: usize = 4; // 64 / 16
        #[expect(
            clippy::arithmetic_side_effects,
            reason = "test helper: small tensor dims"
        )]
        let size = c1 * grid_h * grid_w * C2;
        let mut data = vec![0_i8; size];

        for (dir, &target) in target_offsets.iter().enumerate() {
            // Place a strong logit at the bin nearest to target_offset.
            // With zp=0, scale=1.0, raw i8 value = logit directly.
            let target_bin = (target.round() as usize).min(DFL_REG_MAX.saturating_sub(1));

            for bin in 0..DFL_REG_MAX {
                #[expect(
                    clippy::arithmetic_side_effects,
                    clippy::integer_division,
                    reason = "test helper: DFL index math with known values. \
                              dir (0..3) * 16 + bin (0..15) = max 63."
                )]
                {
                    let c = dir * DFL_REG_MAX + bin;
                    let c1_idx = c / C2;
                    let c2_idx = c % C2;
                    let offset = ((c1_idx * grid_h + hot_h) * grid_w + hot_w) * C2 + c2_idx;
                    if let Some(slot) = data.get_mut(offset) {
                        // Strong logit at target bin, weak elsewhere.
                        *slot = if bin == target_bin { 50_i8 } else { -50_i8 };
                    }
                }
            }
        }

        data
    }
}
