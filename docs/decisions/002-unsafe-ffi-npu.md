# ADR-002: Unsafe FFI for RKNN NPU Inference

## Status

Accepted

## Context

The vision daemon runs YOLO and MobileNetV2 models on the RV1106's integrated NPU via Rockchip's RKNN runtime (`librknnmrt.so`). This is a proprietary C library with no Rust bindings in the ecosystem that target the RV1106's specific runtime (which differs from the RK3588's `librknn_api.so`).

The NPU wrapper requires unsafe for:

1. **`libloading` to load `librknnmrt.so` at runtime** — same rationale as ADR-001's rkaiq wrapper. Runtime loading allows cross-compilation on x86 without the target library present.

2. **FFI calls to the RKNN C API** — `rknn_init`, `rknn_query`, `rknn_run`, `rknn_destroy`, and the zero-copy memory management functions (`rknn_create_mem`, `rknn_destroy_mem`, `rknn_set_io_mem`, `rknn_mem_sync`).

3. **Raw pointer access to NPU-allocated DMA memory** — `rknn_create_mem` returns `rknn_tensor_mem` structs whose `virt_addr` field is a raw pointer to CPU-accessible DMA buffer memory. Reading output tensor data and writing input tensor data requires dereferencing these pointers.

## Decision

Allow `unsafe_code` in one submodule of the `npu` module:

- `npu::rknn` — FFI declarations, `libloading` symbol resolution, and safe wrappers around all RKNN C API calls and DMA memory access.

Unsafe is suppressed via `#[expect(unsafe_code, reason = "...")]` on individual unsafe blocks within `rknn.rs`. All other modules in the npu subsystem (`mod.rs`, `error.rs`, `tensor.rs`) remain under `deny(unsafe_code)`.

Within the unsafe submodule:
- Every `unsafe` block has a `// SAFETY:` comment documenting the preconditions.
- Each block contains exactly one unsafe operation (`multiple_unsafe_ops_per_block = "deny"`).
- Safe wrapper functions validate inputs before entering unsafe code.
- DMA memory pointers are never exposed outside `rknn.rs` — the safe API in `mod.rs` provides `&[i8]` slices bounded by the tensor's known size.

## Consequences

- Unsafe surface area for NPU inference is auditable by inspecting one file (`npu/rknn.rs`).
- The rest of the npu module and vision crate cannot introduce unsafe without a new ADR.
- The `libloading` approach means the crate compiles and pure-Rust tests pass on x86 development machines without `librknnmrt.so`.
- The safe `Model` API in `npu/mod.rs` enforces the RKNN lifecycle (init → query → allocate → bind → run → sync → read) so callers cannot misuse the C API's ordering requirements.
