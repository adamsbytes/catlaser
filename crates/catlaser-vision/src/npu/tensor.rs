//! Tensor metadata, layout conversion, and INT8 dequantization.
//!
//! Pure safe Rust utilities for working with RKNN NPU tensor outputs.
//! The NC1HWC2 layout conversion and affine dequantization are the
//! critical correctness pieces for post-processing INT8 model outputs.

// ---------------------------------------------------------------------------
// Tensor format / type / quantization enums
// ---------------------------------------------------------------------------

/// Tensor data layout format.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TensorFormat {
    /// Standard channel-first: `[N, C, H, W]`.
    Nchw,
    /// Channel-last: `[N, H, W, C]`. NPU native input format in zero-copy mode.
    Nhwc,
    /// Packed channel blocks: `[N, C1, H, W, C2]` where `C1 * C2 >= C`.
    /// RV1106 native output format with `C2 = 16` for INT8 tensors.
    Nc1hwc2,
    /// Format not specified by the runtime.
    Undefined,
}

impl TensorFormat {
    /// Converts from the RKNN C API tensor format value.
    pub(super) fn from_raw(value: u32) -> Self {
        match value {
            0 => Self::Nchw,
            1 => Self::Nhwc,
            2 => Self::Nc1hwc2,
            _ => Self::Undefined,
        }
    }
}

/// Tensor element data type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TensorType {
    /// 32-bit IEEE 754 float.
    Float32,
    /// 16-bit IEEE 754 float.
    Float16,
    /// Signed 8-bit integer (quantized models on RV1106).
    Int8,
    /// Unsigned 8-bit integer.
    Uint8,
    /// Signed 16-bit integer.
    Int16,
    /// Unsigned 16-bit integer.
    Uint16,
    /// Signed 32-bit integer.
    Int32,
    /// Unsigned 32-bit integer.
    Uint32,
    /// Signed 64-bit integer.
    Int64,
    /// Unsigned 64-bit integer.
    Uint64,
    /// Boolean.
    Bool,
    /// Type not recognized by this wrapper.
    Unknown(u32),
}

impl TensorType {
    /// Converts from the RKNN C API tensor type value.
    pub(super) fn from_raw(value: u32) -> Self {
        match value {
            0 => Self::Float32,
            1 => Self::Float16,
            2 => Self::Int8,
            3 => Self::Uint8,
            5 => Self::Int16,
            6 => Self::Uint16,
            7 => Self::Int32,
            8 => Self::Uint32,
            9 => Self::Int64,
            10 => Self::Uint64,
            11 => Self::Bool,
            other => Self::Unknown(other),
        }
    }
}

/// Quantization method applied to a tensor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum QuantType {
    /// No quantization (float tensors).
    None,
    /// Dynamic fixed point.
    Dfp,
    /// Affine asymmetric: `float = (int8 - zp) * scale`.
    /// Standard for INT8 models on RV1106.
    AffineAsymmetric,
    /// Quantization type not recognized by this wrapper.
    Unknown(u32),
}

impl QuantType {
    /// Converts from the RKNN C API quantization type value.
    pub(super) fn from_raw(value: u32) -> Self {
        match value {
            0 => Self::None,
            1 => Self::Dfp,
            2 => Self::AffineAsymmetric,
            other => Self::Unknown(other),
        }
    }
}

// ---------------------------------------------------------------------------
// Tensor attribute metadata
// ---------------------------------------------------------------------------

/// Maximum number of tensor dimensions (matches `RKNN_MAX_DIMS` from `rknn_api.h`).
const MAX_DIMS: usize = 16;

/// Parsed tensor metadata from an RKNN native tensor attribute query.
///
/// Contains the tensor's shape, data type, quantization parameters, and
/// stride information. Constructed from the raw `RknnTensorAttr` C struct
/// during model loading.
#[derive(Debug, Clone)]
pub(crate) struct TensorAttr {
    /// Tensor index (0-based within inputs or outputs).
    pub(crate) index: u32,
    /// Number of valid dimensions in `dims`.
    pub(crate) n_dims: u32,
    /// Dimension values. Only the first `n_dims` entries are meaningful.
    pub(crate) dims: [u32; MAX_DIMS],
    /// Total number of elements in the tensor.
    pub(crate) n_elems: u32,
    /// Byte size of the tensor data (without stride padding).
    pub(crate) size: u32,
    /// Data layout format (NCHW, NHWC, NC1HWC2).
    pub(crate) format: TensorFormat,
    /// Element data type (Float32, Int8, etc.).
    pub(crate) data_type: TensorType,
    /// Quantization method.
    pub(crate) qnt_type: QuantType,
    /// Zero point for affine asymmetric quantization.
    pub(crate) zp: i32,
    /// Scale factor for affine asymmetric quantization.
    pub(crate) scale: f32,
    /// Width stride in elements (0 means contiguous, same as width).
    pub(crate) w_stride: u32,
    /// Byte size including stride padding (use for memory allocation).
    pub(crate) size_with_stride: u32,
    /// Height stride in elements.
    pub(crate) h_stride: u32,
}

impl TensorAttr {
    /// Creates an empty attr for pre-initialization of Model fields.
    pub(super) const fn empty() -> Self {
        Self {
            index: 0,
            n_dims: 0,
            dims: [0_u32; MAX_DIMS],
            n_elems: 0,
            size: 0,
            format: TensorFormat::Undefined,
            data_type: TensorType::Float32,
            qnt_type: QuantType::None,
            zp: 0,
            scale: 0.0_f32,
            w_stride: 0,
            size_with_stride: 0,
            h_stride: 0,
        }
    }

    /// Tensor index (0-based within inputs or outputs).
    pub(crate) const fn index(&self) -> u32 {
        self.index
    }

    /// Number of valid dimensions.
    pub(crate) const fn n_dims(&self) -> u32 {
        self.n_dims
    }

    /// Valid dimension values as a slice.
    pub(crate) fn dims(&self) -> &[u32] {
        let n = usize::try_from(self.n_dims).unwrap_or(0).min(MAX_DIMS);
        self.dims.get(..n).unwrap_or(&[])
    }

    /// Total element count.
    pub(crate) const fn n_elems(&self) -> u32 {
        self.n_elems
    }

    /// Byte size without stride padding.
    pub(crate) const fn size(&self) -> u32 {
        self.size
    }

    /// Data layout format.
    pub(crate) const fn format(&self) -> TensorFormat {
        self.format
    }

    /// Element data type.
    pub(crate) const fn data_type(&self) -> TensorType {
        self.data_type
    }

    /// Quantization method.
    pub(crate) const fn qnt_type(&self) -> QuantType {
        self.qnt_type
    }

    /// Zero point for affine asymmetric dequantization.
    pub(crate) const fn zp(&self) -> i32 {
        self.zp
    }

    /// Scale factor for affine asymmetric dequantization.
    pub(crate) const fn scale(&self) -> f32 {
        self.scale
    }

    /// Width stride (0 = contiguous).
    pub(crate) const fn w_stride(&self) -> u32 {
        self.w_stride
    }

    /// Byte size including stride padding. Use for memory allocation.
    pub(crate) const fn size_with_stride(&self) -> u32 {
        self.size_with_stride
    }

    /// Height stride.
    pub(crate) const fn h_stride(&self) -> u32 {
        self.h_stride
    }
}

// ---------------------------------------------------------------------------
// Output tensor view
// ---------------------------------------------------------------------------

/// A reference to NPU output tensor data with its metadata.
///
/// Borrows from the [`Model`](super::Model) that produced it, ensuring the
/// underlying DMA buffer remains valid. The data is raw INT8 values in the
/// NPU's native layout (typically NC1HWC2). Use [`dequantize_affine`] and
/// [`nc1hwc2_to_nchw`] for post-processing.
#[derive(Debug)]
pub(crate) struct OutputTensor<'a> {
    data: &'a [i8],
    attr: &'a TensorAttr,
}

impl<'a> OutputTensor<'a> {
    /// Creates a new output tensor view.
    pub(super) const fn new(data: &'a [i8], attr: &'a TensorAttr) -> Self {
        Self { data, attr }
    }

    /// Raw INT8 tensor data in the NPU's native layout.
    pub(crate) const fn data(&self) -> &[i8] {
        self.data
    }

    /// Tensor metadata (shape, quantization parameters, format).
    pub(crate) const fn attr(&self) -> &TensorAttr {
        self.attr
    }
}

// ---------------------------------------------------------------------------
// INT8 affine dequantization
// ---------------------------------------------------------------------------

/// Dequantizes a single INT8 value using affine asymmetric quantization.
///
/// Formula: `float_value = (int8_value - zp) * scale`
///
/// The zero point (`zp`) and scale come from the tensor's
/// [`TensorAttr`]. Each output tensor has its own `zp`/`scale` pair.
#[expect(
    clippy::as_conversions,
    clippy::cast_precision_loss,
    clippy::arithmetic_side_effects,
    reason = "INT8 affine dequantization: i32::from(i8) is lossless, \
              i32 subtraction of i8-range values cannot overflow, \
              i32->f32 cast: shifted value range [-255,255] is exact in f32, \
              f32 multiplication produces the dequantized result"
)]
pub(crate) fn dequantize_affine(value: i8, zp: i32, scale: f32) -> f32 {
    (i32::from(value) - zp) as f32 * scale
}

/// Dequantizes a buffer of INT8 values to f32 using affine asymmetric quantization.
pub(crate) fn dequantize_affine_buffer(data: &[i8], zp: i32, scale: f32) -> Vec<f32> {
    data.iter()
        .map(|&v| dequantize_affine(v, zp, scale))
        .collect()
}

// ---------------------------------------------------------------------------
// NC1HWC2 -> NCHW layout conversion
// ---------------------------------------------------------------------------

/// Converts tensor data from NC1HWC2 (NPU native) to NCHW (standard) layout.
///
/// On the RV1106, NPU output tensors use the packed NC1HWC2 format where
/// channels are grouped into blocks of `c2` (typically 16 for INT8). This
/// function unpacks to standard NCHW for post-processing.
///
/// # Layout
///
/// NC1HWC2 element at logical channel `c`, spatial position `(h, w)`:
/// ```text
/// c1 = c / c2
/// c2_idx = c % c2
/// offset = ((c1 * H + h) * W + w) * c2 + c2_idx
/// ```
///
/// # Arguments
///
/// * `data` - Source data in NC1HWC2 layout (from NPU output buffer).
/// * `total_channels` - Logical channel count (e.g. 64 for box tensor, 80 for class tensor).
/// * `height` - Spatial height.
/// * `width` - Spatial width.
/// * `c2` - Channel block size (16 on RV1106 for INT8).
///
/// Returns a `Vec<i8>` in NCHW order: `total_channels * height * width` elements.
/// Out-of-bounds source reads produce zero (defensive against malformed tensor data).
#[expect(
    clippy::as_conversions,
    clippy::arithmetic_side_effects,
    clippy::integer_division,
    reason = "NC1HWC2-to-NCHW index arithmetic. All values are small tensor dimensions \
              (max ~640*480*80 = 24M elements). Products and sums cannot overflow usize \
              on any supported platform (32-bit minimum). Integer division computes \
              channel block indices (c / c2, c % c2)."
)]
pub(crate) fn nc1hwc2_to_nchw(
    data: &[i8],
    total_channels: u32,
    height: u32,
    width: u32,
    c2: u32,
) -> Vec<i8> {
    let tc = total_channels as usize;
    let h = height as usize;
    let w = width as usize;
    let c2s = c2 as usize;

    if c2s == 0 || h == 0 || w == 0 || tc == 0 {
        return Vec::new();
    }

    let out_size = tc * h * w;
    let mut dst = vec![0_i8; out_size];

    for c in 0..tc {
        let c1_idx = c / c2s;
        let c2_idx = c % c2s;

        for row in 0..h {
            for col in 0..w {
                let src_offset = ((c1_idx * h + row) * w + col) * c2s + c2_idx;
                let dst_offset = (c * h + row) * w + col;

                if let (Some(&val), Some(slot)) = (data.get(src_offset), dst.get_mut(dst_offset)) {
                    *slot = val;
                }
            }
        }
    }

    dst
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // --- TensorFormat ---

    #[test]
    fn test_tensor_format_from_raw_known_values() {
        assert_eq!(TensorFormat::from_raw(0), TensorFormat::Nchw, "NCHW = 0");
        assert_eq!(TensorFormat::from_raw(1), TensorFormat::Nhwc, "NHWC = 1");
        assert_eq!(
            TensorFormat::from_raw(2),
            TensorFormat::Nc1hwc2,
            "NC1HWC2 = 2"
        );
        assert_eq!(
            TensorFormat::from_raw(3),
            TensorFormat::Undefined,
            "UNDEFINED = 3"
        );
    }

    #[test]
    fn test_tensor_format_from_raw_unknown_maps_to_undefined() {
        assert_eq!(
            TensorFormat::from_raw(99),
            TensorFormat::Undefined,
            "unknown values map to Undefined"
        );
    }

    // --- TensorType ---

    #[test]
    fn test_tensor_type_from_raw_known_values() {
        assert_eq!(TensorType::from_raw(0), TensorType::Float32, "Float32 = 0");
        assert_eq!(TensorType::from_raw(1), TensorType::Float16, "Float16 = 1");
        assert_eq!(TensorType::from_raw(2), TensorType::Int8, "Int8 = 2");
        assert_eq!(TensorType::from_raw(3), TensorType::Uint8, "Uint8 = 3");
        assert_eq!(TensorType::from_raw(5), TensorType::Int16, "Int16 = 5");
        assert_eq!(TensorType::from_raw(6), TensorType::Uint16, "Uint16 = 6");
        assert_eq!(TensorType::from_raw(7), TensorType::Int32, "Int32 = 7");
        assert_eq!(TensorType::from_raw(8), TensorType::Uint32, "Uint32 = 8");
        assert_eq!(TensorType::from_raw(9), TensorType::Int64, "Int64 = 9");
        assert_eq!(TensorType::from_raw(10), TensorType::Uint64, "Uint64 = 10");
        assert_eq!(TensorType::from_raw(11), TensorType::Bool, "Bool = 11");
    }

    #[test]
    fn test_tensor_type_from_raw_unknown_preserves_value() {
        assert_eq!(
            TensorType::from_raw(42),
            TensorType::Unknown(42),
            "unknown values preserved"
        );
        assert_eq!(
            TensorType::from_raw(4),
            TensorType::Unknown(4),
            "gap value 4 is unknown"
        );
    }

    // --- QuantType ---

    #[test]
    fn test_quant_type_from_raw_known_values() {
        assert_eq!(QuantType::from_raw(0), QuantType::None, "None = 0");
        assert_eq!(QuantType::from_raw(1), QuantType::Dfp, "DFP = 1");
        assert_eq!(
            QuantType::from_raw(2),
            QuantType::AffineAsymmetric,
            "AffineAsymmetric = 2"
        );
    }

    #[test]
    fn test_quant_type_from_raw_unknown_preserves_value() {
        assert_eq!(
            QuantType::from_raw(7),
            QuantType::Unknown(7),
            "unknown values preserved"
        );
    }

    // --- TensorAttr ---

    #[test]
    fn test_tensor_attr_empty() {
        let attr = TensorAttr::empty();
        assert_eq!(attr.index(), 0, "empty index");
        assert_eq!(attr.n_dims(), 0, "empty n_dims");
        assert!(attr.dims().is_empty(), "empty dims");
        assert_eq!(attr.n_elems(), 0, "empty n_elems");
        assert_eq!(attr.size(), 0, "empty size");
        assert_eq!(attr.format(), TensorFormat::Undefined, "empty format");
        assert_eq!(attr.data_type(), TensorType::Float32, "empty data_type");
        assert_eq!(attr.qnt_type(), QuantType::None, "empty qnt_type");
        assert_eq!(attr.zp(), 0_i32, "empty zp");
        assert_eq!(attr.w_stride(), 0, "empty w_stride");
        assert_eq!(attr.size_with_stride(), 0, "empty size_with_stride");
        assert_eq!(attr.h_stride(), 0, "empty h_stride");
    }

    #[test]
    fn test_tensor_attr_dims_slice() {
        let mut attr = TensorAttr::empty();
        attr.n_dims = 4;
        attr.dims[0] = 1;
        attr.dims[1] = 80;
        attr.dims[2] = 80;
        attr.dims[3] = 16;
        assert_eq!(attr.dims(), &[1, 80, 80, 16], "dims slice matches n_dims");
    }

    #[test]
    fn test_tensor_attr_dims_clamps_to_max() {
        let mut attr = TensorAttr::empty();
        attr.n_dims = 100;
        assert_eq!(
            attr.dims().len(),
            MAX_DIMS,
            "dims length clamped to MAX_DIMS"
        );
    }

    // --- OutputTensor ---

    #[test]
    fn test_output_tensor_accessors() {
        let data = [1_i8, 2_i8, 3_i8];
        let attr = TensorAttr::empty();
        let tensor = OutputTensor::new(&data, &attr);
        assert_eq!(tensor.data().len(), 3, "output tensor data length");
        assert_eq!(tensor.attr().index(), 0, "output tensor attr");
    }

    // --- Dequantization ---

    #[test]
    fn test_dequantize_affine_zero() {
        let result = dequantize_affine(0, 0, 1.0_f32);
        assert!(
            result.abs() < f32::EPSILON,
            "dequantize(0, 0, 1.0) should be 0.0, got {result}"
        );
    }

    #[test]
    fn test_dequantize_affine_positive_scale() {
        // (127 - 0) * 0.1 = 12.7
        let result = dequantize_affine(127, 0, 0.1_f32);
        assert!(
            (result - 12.7_f32).abs() < 0.001_f32,
            "dequantize(127, 0, 0.1) should be ~12.7, got {result}"
        );
    }

    #[test]
    fn test_dequantize_affine_with_zero_point() {
        // Typical RKNN values: zp=-128, scale=0.003452
        // (10 - (-128)) * 0.003452 = 138 * 0.003452 = 0.476376
        let result = dequantize_affine(10, -128_i32, 0.003_452_f32);
        assert!(
            (result - 0.476_376_f32).abs() < 0.001_f32,
            "dequantize with zp=-128 got {result}"
        );
    }

    #[test]
    fn test_dequantize_affine_i8_min() {
        // (-128 - (-128)) * 0.003 = 0 * 0.003 = 0.0
        let result = dequantize_affine(i8::MIN, -128_i32, 0.003_f32);
        assert!(
            result.abs() < f32::EPSILON,
            "dequantize(i8::MIN, -128, 0.003) should be 0.0, got {result}"
        );
    }

    #[test]
    fn test_dequantize_affine_i8_max() {
        // (127 - (-128)) * 0.003 = 255 * 0.003 = 0.765
        let result = dequantize_affine(i8::MAX, -128_i32, 0.003_f32);
        assert!(
            (result - 0.765_f32).abs() < 0.001_f32,
            "dequantize(i8::MAX, -128, 0.003) should be ~0.765, got {result}"
        );
    }

    #[test]
    fn test_dequantize_affine_negative_scale() {
        // (50 - 0) * -0.5 = -25.0
        let result = dequantize_affine(50, 0, -0.5_f32);
        assert!(
            (result - (-25.0_f32)).abs() < f32::EPSILON,
            "negative scale should produce negative result, got {result}"
        );
    }

    #[test]
    fn test_dequantize_affine_buffer_empty() {
        let result = dequantize_affine_buffer(&[], 0, 1.0_f32);
        assert!(result.is_empty(), "empty input produces empty output");
    }

    #[test]
    fn test_dequantize_affine_buffer_multiple() {
        let data = [0_i8, 10_i8, -10_i8];
        let result = dequantize_affine_buffer(&data, 0, 0.5_f32);
        assert_eq!(result.len(), 3, "output length matches input");

        let v0 = result.first().copied().unwrap_or(f32::NAN);
        let v1 = result.get(1).copied().unwrap_or(f32::NAN);
        let v2 = result.get(2).copied().unwrap_or(f32::NAN);

        assert!(v0.abs() < f32::EPSILON, "first element should be 0.0");
        assert!(
            (v1 - 5.0_f32).abs() < f32::EPSILON,
            "second element should be 5.0"
        );
        assert!(
            (v2 - (-5.0_f32)).abs() < f32::EPSILON,
            "third element should be -5.0"
        );
    }

    // --- NC1HWC2 to NCHW conversion ---

    #[test]
    fn test_nc1hwc2_to_nchw_empty_inputs() {
        assert!(nc1hwc2_to_nchw(&[], 0, 0, 0, 16).is_empty(), "all zeros");
        assert!(nc1hwc2_to_nchw(&[], 4, 2, 2, 0).is_empty(), "c2=0");
        assert!(nc1hwc2_to_nchw(&[], 4, 0, 2, 16).is_empty(), "height=0");
    }

    /// 4 channels, 2x2 spatial, c2=4. One block, no padding.
    ///
    /// NC1HWC2 shape: [1, 1, 2, 2, 4] = 16 elements.
    /// For c1=0, the data is laid out as:
    ///   (h=0,w=0): [c0, c1, c2, c3]
    ///   (h=0,w=1): [c0, c1, c2, c3]
    ///   (h=1,w=0): [c0, c1, c2, c3]
    ///   (h=1,w=1): [c0, c1, c2, c3]
    #[test]
    fn test_nc1hwc2_to_nchw_4ch_2x2_c2_4() {
        // Label each element by its logical (channel, row, col).
        // NC1HWC2 order: iterate c1, then h, then w, then c2.
        // c1=0, h=0, w=0: channels [0,1,2,3] = [10, 20, 30, 40]
        // c1=0, h=0, w=1: channels [0,1,2,3] = [11, 21, 31, 41]
        // c1=0, h=1, w=0: channels [0,1,2,3] = [12, 22, 32, 42]
        // c1=0, h=1, w=1: channels [0,1,2,3] = [13, 23, 33, 43]
        let nc1hwc2_data: Vec<i8> = vec![
            10, 20, 30, 40, // (h=0, w=0)
            11, 21, 31, 41, // (h=0, w=1)
            12, 22, 32, 42, // (h=1, w=0)
            13, 23, 33, 43, // (h=1, w=1)
        ];

        let nchw = nc1hwc2_to_nchw(&nc1hwc2_data, 4, 2, 2, 4);

        // NCHW: channel 0 = [10, 11, 12, 13]
        //        channel 1 = [20, 21, 22, 23]
        //        channel 2 = [30, 31, 32, 33]
        //        channel 3 = [40, 41, 42, 43]
        assert_eq!(
            nchw,
            vec![
                10, 11, 12, 13, 20, 21, 22, 23, 30, 31, 32, 33, 40, 41, 42, 43
            ],
            "4ch 2x2 c2=4"
        );
    }

    /// 3 channels, 2x2 spatial, c2=4. Last channel block has 1 padding slot.
    ///
    /// NC1HWC2 shape: [1, 1, 2, 2, 4] = 16 elements (4th channel is padding).
    #[test]
    fn test_nc1hwc2_to_nchw_3ch_2x2_c2_4_with_padding() {
        // 3 real channels + 1 padding channel in each c2 block.
        // c1=0, h=0, w=0: [c0=10, c1=20, c2=30, pad=0]
        // c1=0, h=0, w=1: [c0=11, c1=21, c2=31, pad=0]
        // c1=0, h=1, w=0: [c0=12, c1=22, c2=32, pad=0]
        // c1=0, h=1, w=1: [c0=13, c1=23, c2=33, pad=0]
        let nc1hwc2_data: Vec<i8> = vec![
            10, 20, 30, 0, // (h=0, w=0) — last is padding
            11, 21, 31, 0, // (h=0, w=1)
            12, 22, 32, 0, // (h=1, w=0)
            13, 23, 33, 0, // (h=1, w=1)
        ];

        let nchw = nc1hwc2_to_nchw(&nc1hwc2_data, 3, 2, 2, 4);

        // Only 3 channels in output (3 * 2 * 2 = 12 elements).
        assert_eq!(
            nchw,
            vec![10, 11, 12, 13, 20, 21, 22, 23, 30, 31, 32, 33],
            "3ch 2x2 c2=4 with padding"
        );
    }

    /// 32 channels, 1x1 spatial, c2=16. Two full blocks.
    #[test]
    fn test_nc1hwc2_to_nchw_32ch_1x1_c2_16() {
        // c1=0, h=0, w=0: channels 0..15
        // c1=1, h=0, w=0: channels 16..31
        let mut nc1hwc2_data = Vec::with_capacity(32);
        for i in 0..32_i8 {
            nc1hwc2_data.push(i);
        }

        let nchw = nc1hwc2_to_nchw(&nc1hwc2_data, 32, 1, 1, 16);

        // NCHW with 1x1 spatial is just [0, 1, 2, ..., 31].
        let expected: Vec<i8> = (0..32_i8).collect();
        assert_eq!(nchw, expected, "32ch 1x1 c2=16");
    }

    /// 80 channels, 2x2 spatial, c2=16. Five blocks (no padding).
    /// Validates the full conversion at `YOLOv8` class tensor scale.
    #[expect(
        clippy::as_conversions,
        clippy::cast_possible_truncation,
        clippy::integer_division,
        reason = "test with known small values: 80 channels, 2x2 spatial, c2=16"
    )]
    #[test]
    fn test_nc1hwc2_to_nchw_80ch_2x2_c2_16() {
        let tc: usize = 80;
        let h: usize = 2;
        let w: usize = 2;
        let c2: usize = 16;
        let c1: usize = 5;

        // Build NC1HWC2 data where each element = channel index.
        let src_size = c1 * h * w * c2;
        let mut src = vec![0_i8; src_size];

        for c in 0..tc {
            for row in 0..h {
                for col in 0..w {
                    let c1_idx = c / c2;
                    let c2_idx = c % c2;
                    let offset = ((c1_idx * h + row) * w + col) * c2 + c2_idx;
                    if let Some(slot) = src.get_mut(offset) {
                        *slot = c as i8;
                    }
                }
            }
        }

        let nchw = nc1hwc2_to_nchw(&src, 80, 2, 2, 16);
        assert_eq!(nchw.len(), 80 * 2 * 2, "output size = 80*2*2");

        // Verify: in NCHW, channel c has all spatial positions set to c.
        for c in 0..tc {
            for row in 0..h {
                for col in 0..w {
                    let idx = (c * h + row) * w + col;
                    let val = nchw.get(idx).copied().unwrap_or(i8::MIN);
                    assert_eq!(val, c as i8, "channel {c} at ({row},{col})");
                }
            }
        }
    }

    #[test]
    fn test_nc1hwc2_to_nchw_output_length() {
        let data = vec![0_i8; 64];
        let result = nc1hwc2_to_nchw(&data, 3, 2, 2, 16);
        assert_eq!(result.len(), 12, "output = channels * height * width");
    }

    #[test]
    fn test_nc1hwc2_to_nchw_short_input_fills_zeros() {
        // Input too short — missing data should produce zeros in output.
        let data = vec![1_i8; 4];
        let result = nc1hwc2_to_nchw(&data, 4, 2, 2, 4);
        // Some elements will be filled, others stay at 0 due to short input.
        assert_eq!(result.len(), 16, "output size still correct");
    }

    // --- proptest ---

    #[expect(
        clippy::arithmetic_side_effects,
        clippy::as_conversions,
        clippy::cast_possible_truncation,
        clippy::integer_division,
        reason = "proptest module: all values are small tensor dimensions (max 80*20*20). \
                  Arithmetic cannot overflow. as-casts between usize/u32/i8 are intentional \
                  for test data construction. Integer division computes channel block indices."
    )]
    mod proptests {
        use proptest::prelude::*;

        use super::*;

        proptest! {
            #[test]
            fn dequantize_affine_no_panic(
                value in i8::MIN..=i8::MAX,
                zp in -128_i32..=127_i32,
                scale in -100.0_f32..100.0_f32,
            ) {
                let result = dequantize_affine(value, zp, scale);
                prop_assert!(result.is_finite() || scale.abs() > 50.0_f32,
                    "result should be finite for reasonable scale, got {result}");
            }

            #[test]
            fn nc1hwc2_to_nchw_output_length(
                total_channels in 1_u32..=80,
                height in 1_u32..=20,
                width in 1_u32..=20,
                c2 in 1_u32..=16,
            ) {
                let c1 = total_channels.div_ceil(c2);
                let src_size = (c1 as usize) * (height as usize) * (width as usize) * (c2 as usize);
                let data = vec![0_i8; src_size];
                let result = nc1hwc2_to_nchw(&data, total_channels, height, width, c2);
                let expected_len = (total_channels as usize) * (height as usize) * (width as usize);
                prop_assert_eq!(result.len(), expected_len);
            }

            /// Round-trip: place known values in NC1HWC2 layout,
            /// convert to NCHW, verify each element is at the correct position.
            #[test]
            fn nc1hwc2_to_nchw_round_trip(
                total_channels in 1_u32..=32,
                height in 1_u32..=8,
                width in 1_u32..=8,
                c2 in 1_u32..=16,
            ) {
                let tc = total_channels as usize;
                let h = height as usize;
                let w = width as usize;
                let c2s = c2 as usize;
                let c1 = tc.div_ceil(c2s);
                let src_size = c1 * h * w * c2s;
                let mut src = vec![0_i8; src_size];

                for c in 0..tc {
                    for row in 0..h {
                        for col in 0..w {
                            let c1_idx = c / c2s;
                            let c2_idx = c % c2s;
                            let offset = ((c1_idx * h + row) * w + col) * c2s + c2_idx;
                            let val = ((c * h * w + row * w + col) % 256) as i8;
                            if let Some(slot) = src.get_mut(offset) {
                                *slot = val;
                            }
                        }
                    }
                }

                let nchw = nc1hwc2_to_nchw(&src, total_channels, height, width, c2);
                prop_assert_eq!(nchw.len(), tc * h * w);

                for c in 0..tc {
                    for row in 0..h {
                        for col in 0..w {
                            let idx = (c * h + row) * w + col;
                            let expected = ((c * h * w + row * w + col) % 256) as i8;
                            let actual = nchw.get(idx).copied().unwrap_or(i8::MIN);
                            prop_assert_eq!(actual, expected,
                                "mismatch at c={}, row={}, col={}", c, row, col);
                        }
                    }
                }
            }
        }
    }
}
