# RKNN C API (librknn_api) for RV1106 — Rust FFI Research

## Platform Context

The RV1106 has a single-core NPU rated at 0.5 TOPS (not the 1 TOPS sometimes cited for the RV1106G3 SoC package). It uses the RKNPU2 SDK (v2.0.0+), hosted at `github.com/airockchip/rknn-toolkit2`. The runtime library for RV1106 is **`librknnmrt.so`** (not `librknn_api.so` — the latter is the header name, the former is the actual shared object on RV1103/RV1106). The architecture is `armhf-uclibc` (ARM 32-bit, uClibc toolchain: `arm-rockchip830-linux-uclibcgnueabihf`).

**Critical typedef**: on 32-bit ARM (`__arm__` defined), `rknn_context` is `uint32_t`. On 64-bit it's `uint64_t`. Your Rust FFI must match this — use `u32` when targeting RV1106.

---

## Core API Function Signatures

All functions return `int` (0 = `RKNN_SUCC`, negative = error). Source of truth: `rknn_api.h` in `rknpu2/runtime/`.

### rknn_init

```c
int rknn_init(rknn_context* context, void* model, uint32_t size, uint32_t flag, rknn_init_extend* extend);
```

- `model`: if `size > 0`, pointer to model bytes in memory. If `size == 0`, treated as a null-terminated filepath string.
- `flag`: bitfield of `RKNN_FLAG_*` values. Key flags for your use case:
  - `RKNN_FLAG_MEM_ALLOC_OUTSIDE` (0x10) — required for zero-copy; tells runtime you'll manage I/O memory.
  - `RKNN_FLAG_PRIOR_HIGH/MEDIUM/LOW` (0x00/0x01/0x02) — NPU scheduling priority.
  - `RKNN_FLAG_ASYNC_MASK` (0x04) — `rknn_outputs_get` returns previous frame's result immediately (single-thread pipelining).
  - `RKNN_FLAG_COLLECT_PERF_MASK` (0x08) — enables `RKNN_QUERY_PERF_DETAIL`.
- `extend`: can be `NULL`. Used for weight sharing and other advanced features.

**Rust FFI:**
```rust
type RknnContext = u32; // __arm__ target

extern "C" {
    fn rknn_init(
        context: *mut RknnContext,
        model: *const c_void,
        size: u32,
        flag: u32,
        extend: *const RknnInitExtend, // nullable
    ) -> c_int;
}
```

### rknn_query

```c
int rknn_query(rknn_context context, rknn_query_cmd cmd, void* info, uint32_t size);
```

Key query commands:
- `RKNN_QUERY_IN_OUT_NUM` (0) → `rknn_input_output_num { n_input: u32, n_output: u32 }`
- `RKNN_QUERY_INPUT_ATTR` (1) / `RKNN_QUERY_OUTPUT_ATTR` (2) → `rknn_tensor_attr` (user-friendly layout, runtime may convert)
- `RKNN_QUERY_NATIVE_INPUT_ATTR` (8) / `RKNN_QUERY_NATIVE_OUTPUT_ATTR` (9) → `rknn_tensor_attr` (NPU-native layout, needed for zero-copy)
- `RKNN_QUERY_SDK_VERSION` (5) → version strings
- `RKNN_QUERY_MEM_SIZE` (6) → weight/internal memory sizes

### rknn_run

```c
int rknn_run(rknn_context context, rknn_run_extend* extend);
```

`extend` can be `NULL`. Triggers NPU inference. In zero-copy mode, input data must already be in the bound `rknn_tensor_mem` buffers before calling.

### rknn_outputs_get (non-zero-copy path only)

```c
int rknn_outputs_get(rknn_context context, uint32_t n_outputs, rknn_output outputs[], rknn_output_extend* extend);
```

Allocates and copies output data. **Not used in zero-copy mode** — in zero-copy, you read directly from the output `rknn_tensor_mem.virt_addr` after `rknn_run` + cache sync.

### rknn_destroy

```c
int rknn_destroy(rknn_context context);
```

---

## Key Data Structures

### rknn_tensor_attr

This is the central struct for understanding tensor metadata. Fields critical for FFI:

```c
typedef struct _rknn_tensor_attr {
    uint32_t index;              // tensor index
    uint32_t n_dims;             // number of dimensions
    uint32_t dims[RKNN_MAX_DIMS]; // dimension values (RKNN_MAX_DIMS = 16)
    char     name[RKNN_MAX_NAME_LEN]; // tensor name (256 bytes)
    uint32_t n_elems;            // total element count
    uint32_t size;               // byte size of tensor data
    rknn_tensor_format fmt;      // NCHW(0), NHWC(1), NC1HWC2(2), UNDEFINED(3)
    rknn_tensor_type  type;      // FLOAT32(0), FLOAT16(1), INT8(2), UINT8(3), ...
    rknn_tensor_qnt_type qnt_type; // NONE(0), DFP(1), AFFINE_ASYMMETRIC(2)
    int32_t  zp;                 // zero point (for affine asymmetric quantization)
    float    scale;              // scale factor (for affine asymmetric quantization)
    uint32_t w_stride;           // width stride (0 = same as width)
    uint32_t size_with_stride;   // byte size including stride padding
    uint8_t  pass_through;       // if 1, no format/type conversion by runtime
    uint32_t h_stride;           // height stride
} rknn_tensor_attr;
```

### rknn_tensor_mem

```c
typedef struct _rknn_tensor_memory {
    void*    virt_addr;   // CPU-accessible virtual address
    uint64_t phys_addr;   // physical address (for DMA)
    int32_t  fd;          // DMA-BUF file descriptor
    int32_t  offset;      // offset within the allocation
    uint32_t size;        // buffer size
    uint32_t flags;       // memory flags
    void*    priv_data;   // internal use
} rknn_tensor_mem;
```

---

## Quantization

RV1106 models are typically INT8 with **affine asymmetric** quantization (`RKNN_TENSOR_QNT_AFFINE_ASYMMETRIC`). The dequantization formula is:

```
float_value = (int8_value - zp) * scale
```

where `zp` and `scale` come from `rknn_tensor_attr`. Each output tensor has its own `zp`/`scale` pair.

**Practical note**: `sigmoid(0) = 0.5`. After INT8 quantization round-trip this becomes approximately 0.502. If using 0.5 as a confidence threshold for detection, you'll get massive false positives. Use **≥ 0.51**.

---

## Tensor Formats on RV1106

When you query with `RKNN_QUERY_NATIVE_OUTPUT_ATTR`, the RV1106 NPU typically reports tensors in **NC1HWC2** format — a packed layout where channels are grouped into blocks of `c2` (typically 16).

Shape: `[1, c1, H, W, c2]` where `c1 * c2 >= total_channels`.

To convert to standard NCHW for post-processing:

```
for ch in 0..total_channels:
    c1_idx = ch / c2
    c2_idx = ch % c2
    for spatial in 0..(H*W):
        nchw[ch][spatial] = nc1hwc2[c1_idx][spatial][c2_idx]
```

**Input format**: the NPU expects **NHWC** in zero-copy mode. You must query `RKNN_QUERY_NATIVE_INPUT_ATTR` to confirm, and set `pass_through = 1` on the input attr to skip runtime conversion.

---

## Zero-Copy (DMA Buffer) Path

This is the high-performance path. The flow replaces `rknn_inputs_set`/`rknn_outputs_get` with direct memory management.

### Memory Management API

```c
rknn_tensor_mem* rknn_create_mem(rknn_context ctx, uint32_t size);
rknn_tensor_mem* rknn_create_mem_from_fd(rknn_context ctx, int32_t fd,
    void* virt_addr, uint32_t size, int32_t offset);
rknn_tensor_mem* rknn_create_mem_from_phys(rknn_context ctx,
    uint64_t phys_addr, void* virt_addr, uint32_t size);
int rknn_destroy_mem(rknn_context ctx, rknn_tensor_mem* mem);
int rknn_set_io_mem(rknn_context ctx, rknn_tensor_mem* mem, rknn_tensor_attr* attr);
int rknn_mem_sync(rknn_context ctx, rknn_tensor_mem* mem, int mode); // RV1106-specific cache sync
```

### Zero-Copy Workflow

1. **Init with `RKNN_FLAG_MEM_ALLOC_OUTSIDE`** — or call `rknn_init` normally and use `rknn_create_mem` (runtime allocates DMA memory for you).

2. **Query native attrs**: use `RKNN_QUERY_NATIVE_INPUT_ATTR` / `RKNN_QUERY_NATIVE_OUTPUT_ATTR` to get the NPU's preferred layout.

3. **Allocate I/O memory**: `rknn_create_mem(ctx, attr.size_with_stride)` returns a `rknn_tensor_mem*` with both `virt_addr` (for CPU writes) and `fd` (for DMA/RGA operations).

4. **Bind memory**: `rknn_set_io_mem(ctx, mem, &attr)` for each input and output tensor.

5. **Fill input**: `memcpy` into `input_mem->virt_addr`. Respect `w_stride` — if `w_stride != width`, you must copy row-by-row with stride padding.

6. **Run**: `rknn_run(ctx, NULL)`.

7. **Sync output cache**: `rknn_mem_sync(ctx, output_mem, ...)` — required on RV1106 to flush NPU cache to CPU view.

8. **Read output**: directly from `output_mem->virt_addr` as `*const i8` (for INT8 models). No allocation, no copy.

### RGA Integration via fd

The `rknn_tensor_mem.fd` field is a DMA-BUF fd. You can pass it directly to Rockchip's RGA (2D graphics accelerator) for hardware-accelerated resize/format conversion without any CPU memcpy, using `wrapbuffer_fd_t()` from librga.

---

## Running Two Models on One NPU

The RV1106 has a single NPU core. You can create multiple `rknn_context` handles (one per model), each with its own `rknn_init` call. Key considerations:

- **Serialized execution**: with one core, `rknn_run` calls are serialized by the driver. Two contexts share the NPU time-sliced.
- **Memory pressure**: each context allocates weights + internal buffers. On the RV1106 with 256MB RAM, two models (e.g., YOLOv5s ~7MB + MobileNetV2 ~3.5MB as .rknn) can fit, but monitor for the `"failed to allocate fd, ret: -1, errno: 12"` error that indicates DMA memory exhaustion. The Rockchip docs recommend closing unnecessary processes on RV1103/RV1106 when this occurs.
- **Weight sharing**: if both models share a backbone, `RKNN_FLAG_SHARE_WEIGHT_MEM` (0x20) can reduce memory. Unlikely for YOLO + MobileNetV2.
- **Priority control**: use `RKNN_FLAG_PRIOR_HIGH` for your latency-critical model (YOLO for tracking) and `RKNN_FLAG_PRIOR_LOW` for the classifier (MobileNetV2).
- **Sequential recommended**: for your cat laser, run YOLO first (detect cat), crop the region, then run MobileNetV2 on the crop. This avoids concurrent NPU contention and keeps memory lower since you can destroy/reinit contexts if needed — though keeping both loaded avoids the ~100-200ms `rknn_init` cost.
- **Matmul API**: not supported on RV1103/RV1106.

---

## Existing Rust FFI Reference

The [`rknn-runtime`](https://github.com/LdDl/rknn-runtime) crate (by LdDl) provides a working Rust wrapper tested specifically on the Luckfox Pico Ultra W with RV1106. It uses `libloading` to dynamically load `librknnmrt.so` at runtime, meaning you can cross-compile on x86 without the RKNN library present. The crate covers zero-copy init, `rknn_mem_sync`, NC1HWC2 conversion, and INT8 dequantization. It's a useful reference for FFI signatures and memory management patterns even if you write your own bindings.

---

## RV1106-Specific Gotchas

1. **Library name**: the shared object is `librknnmrt.so`, not `librknn_api.so`. Located at `/usr/lib/librknnmrt.so` or `/oem/usr/lib/`.

2. **Toolchain**: must use `armhf-uclibcgnueabihf` (the Rockchip 830 toolchain), not standard glibc armhf. This affects Rust cross-compilation — you need the correct linker and sysroot.

3. **Cache coherency**: unlike RK3588, the RV1106 requires explicit `rknn_mem_sync` after `rknn_run` to make output data visible to CPU in zero-copy mode.

4. **NC1HWC2 output**: this is the default native output format. The `c2` block size is typically 16. You must handle this in post-processing or request conversion (at a performance cost) by querying `RKNN_QUERY_OUTPUT_ATTR` instead of `RKNN_QUERY_NATIVE_OUTPUT_ATTR` and not using `pass_through`.

5. **NHWC input only**: in zero-copy mode, the NPU only accepts NHWC input layout.

6. **Stride alignment**: check `w_stride` from tensor attrs. If non-zero and different from width, rows have padding bytes that must be accounted for when writing input data.

---

## Sources

- `rknn_api.h` — canonical header in `rknpu2/runtime/*/librknn_api/include/` ([rockchip-linux/rknpu2](https://github.com/rockchip-linux/rknpu2), [airockchip/rknn-toolkit2](https://github.com/airockchip/rknn-toolkit2))
- Official RV1106 examples: `rknpu2/examples/RV1106_RV1103/rknn_mobilenet_demo/`
- Zero-copy examples: `rknpu2/examples/rknn_api_demo/src/rknn_create_mem_demo.cpp`
- Rockchip RKNPU User Guide RKNN SDK V2.0.0beta0
- [LdDl/rknn-runtime](https://github.com/LdDl/rknn-runtime) — Rust bindings tested on Luckfox Pico Ultra W / RV1106
- [Luckfox Wiki — RKNN](https://wiki.luckfox.com/Luckfox-Pico-Pro-Max/RKNN/)
