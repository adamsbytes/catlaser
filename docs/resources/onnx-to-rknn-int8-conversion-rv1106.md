# ONNX-to-RKNN INT8 Model Conversion for RV1106

Reference for converting YOLOv8n and MobileNetV2 ONNX models to `.rknn` INT8 format
targeting the RV1106 NPU using rknn-toolkit2.

---

## Toolchain Overview

**rknn-toolkit2** (latest: v2.3.2, April 2025) is the PC-side Python SDK for converting
trained models into `.rknn` format. It runs on x86_64 or aarch64 Linux and supports
Python 3.6–3.12. The canonical repository is
[airockchip/rknn-toolkit2](https://github.com/airockchip/rknn-toolkit2). The on-device
runtime is **RKNN Runtime** (C API via `librknnmrt.so`); there is no Python runtime for
RV1103/RV1106 boards.

## Conversion Pipeline (Python API)

The conversion follows five steps: create, configure, load, build, export.

```python
from rknn.api import RKNN

rknn = RKNN(verbose=True)

# 1. Configure
rknn.config(
    mean_values=[[0, 0, 0]],
    std_values=[[255, 255, 255]],
    target_platform='rv1106',
)

# 2. Load ONNX
rknn.load_onnx(model='yolov8n.onnx')

# 3. Build (quantize)
rknn.build(do_quantization=True, dataset='./calibration.txt')

# 4. Export
rknn.export_rknn('./yolov8n_rv1106.rknn')

rknn.release()
```

The same flow applies to MobileNetV2; adjust `mean_values` / `std_values` to match
training normalization (e.g., `[[123.675, 116.28, 103.53]]` / `[[58.395, 57.12, 57.375]]`
for ImageNet).

## Platform Target Strings

The `target_platform` parameter in `rknn.config()` accepts the following strings relevant
to this project:

| String     | Covers                 |
|------------|------------------------|
| `rv1106`   | RV1106 (and RV1106G3)  |
| `rv1103`   | RV1103                 |
| `rk3588`   | RK3588 / RK3588S       |
| `rk3566`   | RK3566                 |
| `rk3568`   | RK3568                 |
| `rk3562`   | RK3562                 |
| `rk3576`   | RK3576                 |

If omitted, the toolkit defaults to `rk3566` and emits a warning. The target string is
baked into the `.rknn` file; a model compiled for `rk3588` will not run on `rv1106`.

## Critical RV1106 Constraint: INT8-Only

The RV1106 NPU **requires** `do_quantization=True`. Attempting `do_quantization=False`
produces the error:

```
E build: Current target_platform(rv1106) not support do_quantization = False!
```

This means every model deployed on RV1106 must be INT8-quantized. There is no FP16
fallback path as exists on RK3588. The NPU also only produces INT8 outputs; the toolkit
warns that output dtypes are changed from `float32` to `int8`.

## `rknn.config()` Parameters

Key parameters that affect conversion output:

| Parameter              | Description                                                                                  |
|------------------------|----------------------------------------------------------------------------------------------|
| `mean_values`          | Per-input list of per-channel means. Fused into the model graph as preprocessing.            |
| `std_values`           | Per-input list of per-channel standard deviations. Fused into the model graph.               |
| `target_platform`      | Target SoC string (see table above). **Required** for correct compilation.                   |
| `quantized_dtype`      | Quantization type string. Default: `'asymmetric_quantized-u8'`. Also accepts `'asymmetric_quantized-i8'`. For RV1106, INT16 variants (`w16a16i_dfp`, `w16a16i`) may convert but produce incorrect results. |
| `quantized_algorithm`  | `'normal'` (default, fast, min/max), `'mmse'` (slower, better for uneven distributions), or `'kl_divergence'`. |
| `optimization_level`   | Integer, default 3. Controls graph optimization aggressiveness.                              |
| `quantize_weight`      | Bool, default False. Reduces model size by quantizing weights even when `do_quantization=False`. Only valid for RK3588/RK3576 (irrelevant on RV1106). |

When `mean_values` and `std_values` are set, the toolkit fuses normalization into the
first layer. The runtime then expects raw `uint8` pixel values (0–255) as input, not
pre-normalized floats. This is the recommended approach for RV1106 since it avoids
CPU-side float preprocessing.

## Quantization Calibration Dataset

The `dataset` parameter of `rknn.build()` is a **text file** where each line is an
absolute or relative path to a calibration image:

```text
./images/frame_001.jpg
./images/frame_002.jpg
./images/frame_003.jpg
...
```

**Requirements and best practices:**

- **Minimum**: The toolkit requires at least 1 image, but accuracy degrades severely
  with too few. Rockchip examples typically use 20–100 images (e.g., `coco_subset_20.txt`
  in the model zoo).
- **Recommended**: 50–200 representative images from the target domain. For the cat
  laser project, use frames captured from the actual SC3336 camera in the deployment
  environment.
- **Format**: Standard image formats (JPEG, PNG). The toolkit auto-resizes images to
  match the model input dimensions, but providing correctly-sized images avoids
  interpolation artifacts that can affect calibration quality.
- **Representativeness**: Calibration images should cover the range of scenes the model
  will encounter (varying lighting, distances, cat poses). Quantization accuracy is
  highly sensitive to dataset representativeness, especially for small-object detection.
- **Non-image models**: For non-image inputs, provide `.npy` files with the correct
  tensor shape.

## Output Tensor Layout: NHWC vs NC1HWC2

This is the single most critical post-conversion detail for the C/Rust runtime
implementation.

### The NC1HWC2 Native Format

The RV1106 NPU's **native output layout** is `NC1HWC2`, not standard `NCHW` or `NHWC`.
The `C2` dimension is determined by the platform and data type:

| Platform Family           | INT8 C2 | FP16 C2 |
|---------------------------|---------|---------|
| RK3566 / RK3568           | 8       | 8       |
| RK3588                    | 16      | 16      |
| RV1103 / RV1106           | 16      | 16      |

`C1 = ceil(C / C2)`. Channels are zero-padded to align to `C2` boundaries. For example,
a YOLOv5 output of shape `[1, 255, 80, 80]` on RV1106 becomes
`NC1HWC2 = [1, 16, 80, 80, 16]` with the last C2 block partially valid.

### Querying Tensor Layout at Runtime

The C API provides two query modes:

- `RKNN_QUERY_OUTPUT_ATTR`: Returns the **logical** shape (e.g., `[1, 80, 80, 255]` in
  NHWC). The runtime performs an internal layout conversion which adds latency.
- `RKNN_QUERY_NATIVE_OUTPUT_ATTR` (or the older `RKNN_QUERY_NATIVE_NC1HWC2_OUTPUT_ATTR`):
  Returns the **physical** NC1HWC2 shape. Using this with zero-copy memory
  (`rknn_create_mem` / `rknn_set_io_mem`) avoids the format conversion overhead and is
  the recommended path for performance-critical inference.

The official `rknn_mobilenet_demo` for RV1106 demonstrates the NC1HWC2-to-NCHW
conversion function that must be implemented client-side:

```c
// Pseudocode: NC1HWC2 int8 -> NCHW float
dst[c * H * W + h * w + w_idx] =
    (src[c1 * H * W * C2 + h * W * C2 + w_idx * C2 + c2] - zp) * scale;
```

### Input Layout

Inputs are expected in **NHWC** format with INT8 type (after quantization). The model's
input attributes report `fmt=NHWC, type=INT8, qnt_type=AFFINE` with a zero-point
(typically -128 for 0–255 uint8 mapping) and scale. Raw RGB bytes in NHWC order can be
passed directly without normalization when `mean_values`/`std_values` are configured.

## Supported ONNX Operator Set

The RKNN compiler supports ONNX opset versions up to approximately **opset 19**, though
opset 12 is the most widely tested and recommended. The toolkit emits a warning for opset
14+ that it is not fully supported.

Commonly supported operators relevant to YOLOv8n and MobileNetV2 include: Conv,
ConvTranspose, BatchNormalization, Relu, Relu6, Sigmoid, Swish/SiLU (via Conv fusion),
MaxPool, AveragePool, GlobalAveragePool, Add, Mul, Concat, Reshape, Transpose, Resize
(nearest/bilinear), Softmax, Pad, Split, Slice, and ReduceMean.

The full supported operator list is published as
`doc/05_RKNN_Compiler_Support_Operator_List_v*.pdf` in the rknn-toolkit2 repository.

## Known Operator Limitations: RV1103/RV1106 vs RK3588

| Feature / Operator         | RK3588                 | RV1103 / RV1106                          |
|----------------------------|------------------------|------------------------------------------|
| FP16 inference             | Supported              | **Not supported** (INT8 only)            |
| `do_quantization=False`   | Supported (yields FP16)| **Not supported** (errors at build)      |
| MatMul API (`rknn_matmul`) | Supported              | **Not supported**                        |
| Multi-core NPU             | 3 cores                | 1 core                                   |
| LayerNormalization         | Supported (NPU)        | **Not supported on NPU** (falls to CPU)  |
| ReduceL2                   | Supported              | **Not supported on NPU** (falls to CPU)  |
| NonMaxSuppression          | Not supported (graph must exclude NMS; run on CPU) | Same                 |
| SRAM weight storage        | Supported              | Not available                            |
| Weight compression         | Supported              | Supported                                |
| Dynamic shapes             | Supported              | Limited                                  |
| Max input resolution       | Up to 8192             | Lower (hardware-dependent)               |

### Practical Implications for This Project

- **YOLOv8n**: Export the ONNX model **without** the NMS/DFL decode head—use the
  Ultralytics `export(format='onnx')` which produces raw feature maps. Post-processing
  (anchor decoding, NMS) must run on the Cortex-A7 CPU. The `airockchip/rknn_model_zoo`
  provides reference post-processing for YOLO models. Splitting the detection head into
  separate box and score output tensors can help avoid INT8 quantization issues where
  different value ranges share a single scale/zero-point.
- **MobileNetV2 (re-ID embeddings)**: The standard MobileNetV2 architecture uses only
  Conv, BN, ReLU6, and GlobalAveragePool—all well-supported. However, if the re-ID head
  includes L2 normalization (ReduceL2), this operator is **not** supported on RV1106 NPU
  and will either fall back to CPU or cause conversion failure. **Remove L2 normalization
  from the ONNX graph** before conversion and perform it in the Rust post-processing code.

## Model Zoo Cross-Compilation

The `rknn_model_zoo` build system expects the RV1106 uclibc toolchain:

```bash
export GCC_COMPILER=<sdk>/tools/linux/toolchain/\
arm-rockchip830-linux-uclibcgnueabihf/bin/\
arm-rockchip830-linux-uclibcgnueabihf

./build-linux.sh -t rv1106 -a armhf -d yolov5
```

The target `-t rv1106` covers both RV1103 and RV1106. Architecture is `armhf` (ARMv7).
The runtime library for the board is `librknnmrt.so` (not `librknnrt.so` which is for
RK3588/aarch64).

## Conversion Checklist for Cat Laser Project

1. Export YOLOv8n ONNX with `opset=12`, no NMS, input shape `[1, 3, 640, 480]`.
2. Export MobileNetV2 ONNX with `opset=12`, **no** L2 norm layer, input shape
   `[1, 3, 128, 128]` (or re-ID crop size).
3. Prepare calibration dataset: 50–100 frames from the SC3336 camera.
4. Run conversion with `target_platform='rv1106'`, `do_quantization=True`.
5. Use `quantized_algorithm='mmse'` if default `'normal'` shows accuracy loss.
6. In Rust runtime: use `RKNN_QUERY_NATIVE_OUTPUT_ATTR` + zero-copy buffers.
7. Implement NC1HWC2→NCHW dequantization in Rust using per-tensor `zp` and `scale`.
8. Run NMS and L2-norm post-processing on the Cortex-A7 CPU.

## References

- [airockchip/rknn-toolkit2](https://github.com/airockchip/rknn-toolkit2) — canonical
  repo, docs, and examples.
- [airockchip/rknn_model_zoo](https://github.com/airockchip/rknn_model_zoo) — reference
  YOLO/MobileNet conversion scripts and C demos for RV1106.
- `doc/02_Rockchip_RKNPU_User_Guide_RKNN_SDK_*.pdf` — official user guide covering
  NC1HWC2 layout, quantization algorithms, and API reference.
- `doc/05_RKNN_Compiler_Support_Operator_List_*.pdf` — per-platform operator support
  matrix.
- [Luckfox RKNN Wiki](https://wiki.luckfox.com/Luckfox-Pico-Pro-Max/RKNN/) —
  RV1103/RV1106-specific guidance.
