# YOLOv8n Anchor-Free Detection Head: RKNN INT8 Post-Processing on RV1106

## Output Tensor Structure

The RKNN Model Zoo's optimized YOLOv8n export splits the original single `[1, 84, 8400]` output (for 80-class COCO) into **9 tensors** — three groups of three, one group per FPN stride (8, 16, 32). Each group contains:

| Tensor | Logical Shape (NCHW) | Content | Purpose |
|--------|----------------------|---------|---------|
| Box    | `[1, 64, H, W]`     | Raw DFL logits (4 offsets × 16 bins) | Bounding box regression |
| Class  | `[1, 80, H, W]`     | Per-class logits (pre-sigmoid) | Class scores |
| Score  | `[1, 1, H, W]`      | ReduceSum+Clip of class scores | Fast confidence pre-filter |

Grid dimensions per stride: 80×80 (stride 8, 6400 cells), 40×40 (stride 16, 1600 cells), 20×20 (stride 32, 400 cells). Total: 8400 candidate locations.

The "score" tensor is an optimization added by Rockchip's ONNX surgery. It sums class confidences per cell and clips the result, enabling a cheap threshold check before the expensive per-class decode. This tensor is absent from the vanilla Ultralytics ONNX export — it is added by the `rknn_model_zoo` conversion scripts, which remove the DFL/decode subgraph and instead expose the two raw convolution outputs plus this helper branch.

Each tensor has its own INT8 affine quantization parameters (`zp`, `scale`), reported by `rknn_query(RKNN_QUERY_NATIVE_OUTPUT_ATTR)`. The quantization type is `AFFINE` (asymmetric).

## NC1HWC2 Tensor Layout on RV1106

On the RV1106 (RKNPU2 with a single-core NPU), the runtime uses the **native output format** `NC1HWC2` rather than standard NCHW. The `C2` value is platform-dependent:

- **RV1106/RV1103**: `C2 = 16` for INT8 tensors.

A logical tensor of shape `[1, C, H, W]` in NCHW becomes `[1, C1, H, W, C2]` where `C1 = ceil(C / C2)`. Channels are packed into blocks of 16, with padding zeros filling any remainder in the last block.

To convert from NC1HWC2 back to NCHW for post-processing:

```
// For each channel c in 0..total_channels:
let c1_idx = c / C2;
let c2_idx = c % C2;
// Element at (n, c, h, w) is stored at:
//   src[n][c1_idx][h][w][c2_idx]
// Linear offset: ((c1_idx * H + h) * W + w) * C2 + c2_idx
```

Querying native output attributes (via `RKNN_QUERY_NATIVE_OUTPUT_ATTR`) returns the NC1HWC2 shape, zero-point, and scale for each tensor.

## INT8 Affine Asymmetric Dequantization

Every output tensor stores signed INT8 values. To recover floating-point values:

```
f32_value = (i8_value - zp) * scale
```

Where `zp` (zero point) is an `i32` and `scale` is an `f32`, both per-tensor. Each of the 9 output tensors has its own unique `zp` and `scale`. As observed in the RKNN Model Zoo examples, typical values look like:

- Box tensor (stride 8): `zp=-56, scale=0.110522`
- Class tensor (stride 8): `zp=-128, scale=0.003452`
- Score tensor (stride 8): `zp=-128, scale=0.003482`

Dequantization must occur **before** any mathematical operations (softmax, sigmoid) that assume floating-point range.

## Post-Processing Pipeline

### Step 1: Quick Confidence Filter (Score Tensor)

For each grid cell at each stride, read the score tensor value, dequantize it, and compare against a threshold (e.g., 0.25). This rejects ~95% of cells cheaply before touching the larger box and class tensors. Note: because this is a summed/clipped aggregate, it is used only for filtering — not as the final confidence.

### Step 2: DFL Box Decoding

YOLOv8 uses **Distribution Focal Loss** for box regression. Instead of directly predicting 4 coordinates, the head predicts a discrete probability distribution over `reg_max=16` bins for each of the 4 offsets (left, top, right, bottom distances from the cell center to box edges).

The 64-channel box tensor encodes `4 offsets × 16 bins`. For each cell that passes the score filter:

1. **Extract and dequantize** the 64 values from the box tensor for that (h, w) location.
2. **Reshape** into `[4, 16]` — four groups of 16 logits.
3. **Softmax** each group of 16 independently to get a probability distribution.
4. **Dot product** each distribution with `[0, 1, 2, ..., 15]` to compute the expected offset value. This converts the distribution into a single continuous offset per edge.

```
// For one offset direction (e.g., "left"):
let logits: [f32; 16] = dequantize(raw_box[0..16], zp, scale);
let probs = softmax(logits);   // sum to 1.0
let offset = sum(probs[i] * i for i in 0..16);  // weighted sum
```

This yields 4 offsets: `(dist_left, dist_top, dist_right, dist_bottom)` in grid-cell units.

5. **Convert to pixel coordinates** using the anchor point (cell center) and stride:

```
let cx = (w as f32 + 0.5) * stride;  // cell center x
let cy = (h as f32 + 0.5) * stride;  // cell center y

let x1 = cx - dist_left * stride;
let y1 = cy - dist_top * stride;
let x2 = cx + dist_right * stride;
let y2 = cy + dist_bottom * stride;
```

This is the anchor-free decode: each cell center acts as its own implicit anchor point, with DFL offsets extending in all four directions.

### Step 3: Class Score Extraction

For cells passing the pre-filter, extract and dequantize the 80 class logits from the class tensor. Apply **sigmoid** to each to get per-class probabilities:

```
class_prob[i] = 1.0 / (1.0 + exp(-dequantized_logit[i]))
```

YOLOv8 has no separate "objectness" score — the class probability directly serves as confidence. The final detection confidence for a given class is simply `sigmoid(class_logit)`. The maximum across classes determines the detection's class label and score.

### Step 4: Non-Maximum Suppression (NMS)

Collect all decoded boxes with `max_class_score > conf_threshold` (typically 0.25–0.5; use **≥0.51** with INT8 to avoid sigmoid(0)≈0.502 noise). Then apply standard greedy NMS:

1. Sort detections by confidence (descending).
2. Take the highest-scoring detection, add it to the output list.
3. Remove all remaining detections with IoU > `nms_threshold` (typically 0.45) against the selected detection.
4. Repeat until no candidates remain.

For single-class use (cat detection), class-agnostic NMS suffices. For multi-class, either run NMS per class or offset boxes by class ID before global NMS.

## INT8 Implementation Considerations

- **Dequantize early**: Softmax and sigmoid are nonlinear — applying them to raw INT8 values produces incorrect results. Always dequantize to f32 first.
- **NC1HWC2 stride math**: When iterating grid cells, the inner memory access pattern is `[c1][h][w][c2]`. For the 64-channel box tensor, `C1 = 64/16 = 4` blocks. For the 80-class tensor, `C1 = ceil(80/16) = 5` blocks (last block has 16 slots but only the first 0 channels beyond 80 are padding).
- **Sigmoid threshold in INT8**: The dequantized value 0.0 maps to sigmoid output 0.5. After quantization round-tripping, this settles at approximately 0.502. A confidence threshold of exactly 0.5 will admit large numbers of zero-signal detections.
- **Coordinate scaling**: If the input image was letterboxed/padded to 640×640, detected box coordinates are in the 640×640 space and must be mapped back to the original image dimensions, accounting for padding offsets and scale factors.

## References

- [airockchip/rknn_model_zoo — YOLOv8 example](https://github.com/airockchip/rknn_model_zoo/tree/main/examples/yolov8): Optimized ONNX structure, C++ postprocess reference, and model conversion scripts.
- [Rockchip RKNPU User Guide (RKNN SDK V2.0)](https://www.scribd.com/document/774992182/02-Rockchip-RKNPU-User-Guide-RKNN-SDK-V2-0-0beta0-EN): NC1HWC2 format specification and platform-specific C2 values.
- [airockchip/rknn-toolkit2 — RV1106 MobileNet demo](https://github.com/airockchip/rknn-toolkit2/blob/master/rknpu2/examples/RV1106_RV1103/rknn_mobilenet_demo/src/main.cc): Reference `NC1HWC2_int8_to_NCHW_float` implementation with `(src[offset] - zp) * scale` dequantization.
- [LdDl/rknn-runtime (Rust, RV1106)](https://github.com/LdDl/rknn-runtime): Rust bindings confirming NC1HWC2 with C2=16 on RV1106, with `nc1hwc2_to_flat()` and `dequantize_affine()` utilities.
- [Ultralytics YOLOv8 DFL implementation](https://docs.ultralytics.com/reference/utils/loss/): `bbox_decode` showing `softmax(3).matmul(proj)` pattern for distribution-to-offset conversion.
- [Generalized Focal Loss (Li et al., 2020)](https://ieeexplore.ieee.org/document/9792391): Original DFL paper describing distribution-based bounding box regression.
