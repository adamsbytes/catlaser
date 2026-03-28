# ADR-001: Unsafe FFI in catlaser-vision

## Status

Accepted

## Context

The workspace enforces `unsafe_code = "deny"` globally. The vision daemon requires direct interaction with two C APIs that have no safe Rust alternatives:

1. **V4L2 kernel ioctls** for camera capture (ioctl, mmap, munmap, poll). No crate provides safe wrappers for the RKISP multiplanar driver's specific behavior on the RV1106. The standard `v4l2r` crate generates bindings from `videodev2.h` via bindgen, but still requires unsafe for the actual ioctl calls, mmap operations, and pointer-based buffer access.

2. **librkaiq.so** (Rockchip ISP 3A library) for auto-exposure, auto-white-balance, and auto-gain. This is a proprietary C library with no Rust bindings. Without it, captured frames are dark and green-tinted. The library is loaded at runtime via `libloading` to avoid link-time dependency on a target-only shared object.

## Decision

Allow `unsafe_code` in two specific submodules of the `camera` module:

- `camera::v4l2` — V4L2 ioctl wrappers, mmap/munmap, poll, file descriptor management.
- `camera::rkaiq` — FFI declarations and safe wrapper for the rkaiq uapi2 init/prepare/start/stop lifecycle.

Unsafe is suppressed via `#[expect(unsafe_code, reason = "...")]` on the `mod` declarations in `camera/mod.rs`, confining it to these two files. All other modules in the vision crate remain under `deny(unsafe_code)`.

Within the unsafe submodules:
- Every `unsafe` block has a `// SAFETY:` comment documenting the preconditions.
- Each block contains exactly one unsafe operation (`multiple_unsafe_ops_per_block = "deny"`).
- Safe wrapper functions validate inputs before entering unsafe code.

## Consequences

- Unsafe surface area is auditable by inspecting two files.
- The rest of the vision crate (tracker, targeting, IPC, main) cannot introduce unsafe without a new ADR.
- The rkaiq wrapper uses `libloading` for runtime loading, so the crate compiles and tests pass on x86 development machines without the target library present.
