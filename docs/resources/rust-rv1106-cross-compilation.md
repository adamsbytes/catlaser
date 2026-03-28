# Rust Cross-Compilation for RV1106 armhf-uclibc

## Target Overview

The RV1106's Cortex-A7 runs Linux with a uClibc-ng userspace, built by the Luckfox Pico SDK's Buildroot configuration. The SDK ships a dedicated GCC toolchain with the triple `arm-rockchip830-linux-uclibcgnueabihf`. Rockchip's precompiled media libraries (`librga.so`, `librkaiq.so`, `librknnmrt.so`, `librkmpi.so`) are built exclusively against this uclibc toolchain — no glibc variants are provided for the RV1106. This means the Rust toolchain **must** target uclibc and link against this specific sysroot.

## Closest Built-in Target and Its Limitations

Rust ships a Tier 3 built-in target: **`armv7-unknown-linux-uclibceabihf`**. This target supports ARMv7-A with hard-float and the uClibc-ng C library. Because it is Tier 3, no precompiled `std` is distributed via `rustup`; the standard library must be built from source using `-Zbuild-std` on nightly.

### The EABI Version Mismatch

A known, critical issue exists when pairing this built-in target with the Rockchip SDK linker: LLVM emits objects tagged as **EABI5** (the standard for modern ARM), but the Rockchip `arm-rockchip830-linux-uclibcgnueabihf-ld.bfd` rejects them, expecting **EABI version 0**. The resulting linker error looks like:

```
error: source object ... has EABI version 5, but target ... has EABI version 0
```

This is a toolchain-age issue — the Rockchip SDK bundles an older `ld.bfd` that does not accept EABI5 objects. There are two viable solutions.

### Solution A: Use a Modern Linker (Recommended)

Override the linker to use **`gcc`** from the Rockchip toolchain (which invokes a compatible `collect2`/`ld`) rather than calling `ld.bfd` directly, or better, use `rust-lld` which Rust ships:

```toml
# .cargo/config.toml
[target.armv7-unknown-linux-uclibceabihf]
linker = "arm-rockchip830-linux-uclibcgnueabihf-gcc"
```

Using GCC as the linker driver delegates object-file compatibility handling to GCC's internal pipeline, which typically resolves the EABI version negotiation. If the SDK's GCC still refuses, consider building a newer cross-toolchain via Buildroot or crosstool-NG with an updated binutils that accepts EABI5.

### Solution B: Custom Target JSON

If the linker workaround is insufficient, define a custom target spec derived from the built-in target. Dump the base spec:

```bash
rustc +nightly -Z unstable-options --print target-spec-json \
  --target armv7-unknown-linux-uclibceabihf
```

Save the output as `armv7-rockchip-linux-uclibceabihf.json` in the project root and make adjustments:

```jsonc
{
  // Key fields from the built-in target — keep as-is:
  "arch": "arm",
  "os": "linux",
  "env": "uclibc",
  "vendor": "rockchip",
  "data-layout": "e-m:e-p:32:32-Fi8-i64:64-v128:64:128-a:0:32-n32-S64",
  "llvm-target": "armv7-unknown-linux-gnueabihf",
  "features": "+v7,+vfp3,-d32,+thumb2,-neon",
  "max-atomic-width": 64,
  "dynamic-linking": true,
  "has-rpath": true,
  "position-independent-executables": true,
  "target-family": ["unix"],
  "target-c-int-width": "32",
  "target-endian": "little",
  "target-pointer-width": "32",

  // Override for Rockchip toolchain:
  "linker": "arm-rockchip830-linux-uclibcgnueabihf-gcc",
  "linker-flavor": "gcc",

  // Remove is-builtin so Rust treats it as custom:
  // (do NOT include "is-builtin": true)

  "pre-link-args": {
    "gcc": [
      "-Wl,--as-needed",
      "-Wl,-z,noexecstack",
      "--sysroot", "${SYSROOT}"
    ]
  }
}
```

> **Note on `features`**: The RV1106's Cortex-A7 supports VFPv4-D16 and NEON. Adjust to `+v7,+vfp4,-d32,+thumb2,+neon` if your SDK libraries are built with NEON. Verify with `readelf -A` on an SDK-produced `.so`.

## Sysroot Setup

The sysroot lives inside the SDK at:

```
$SDK/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf/
  arm-rockchip830-linux-uclibcgnueabihf/sysroot/
```

Buildroot also produces a sysroot at:

```
$SDK/sysdrv/source/buildroot/buildroot-2023.02.6/output/host/
  arm-buildroot-linux-uclibcgnueabihf/sysroot/
```

Export a convenience variable:

```bash
export RV1106_SYSROOT="$SDK/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf/arm-rockchip830-linux-uclibcgnueabihf/sysroot"
```

Ensure the toolchain is on `$PATH`:

```bash
cd $SDK/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf/
source env_install_toolchain.sh
```

## Building `std` with `-Zbuild-std`

Since this is a Tier 3 target, the standard library must be compiled from source. This requires the nightly toolchain with the `rust-src` component:

```bash
rustup toolchain install nightly
rustup component add rust-src --toolchain nightly
```

Build with:

```bash
cargo +nightly build \
  -Zbuild-std=std,panic_abort \
  --target armv7-unknown-linux-uclibceabihf \
  --release
```

If using a custom target JSON, replace the target triple with the JSON path:

```bash
cargo +nightly build \
  -Zbuild-std=std,panic_abort \
  --target ./armv7-rockchip-linux-uclibceabihf.json \
  --release
```

> **Known issue**: Older nightly versions had a build failure where `siginfo_t.si_addr()` was missing for uclibc targets due to an incomplete `libc` crate definition. This was tracked in rust-lang/rust#95866 and has been fixed in subsequent nightlies. Pin to a nightly newer than the fix if encountered.

## Linking Against Rockchip Platform Libraries

The SDK ships precompiled shared libraries under `media/`:

| Library | SDK Path | Purpose |
|---|---|---|
| `librknnmrt.so` | `media/npu/...` or `rknpu2/runtime/RV1106/Linux/librknn_api/armhf/` | NPU inference runtime |
| `librga.so` | `media/rga/release_rga_rv1106_arm-rockchip830-linux-uclibcgnueabihf/` | 2D raster acceleration |
| `librkaiq.so` | `media/isp/release_camera_engine_rkaiq_rv1106_arm-rockchip830-linux-uclibcgnueabihf/` | ISP auto image quality |
| `librkmpi.so` | `media/mpp/release_mpp_rv1106_arm-rockchip830-linux-uclibcgnueabihf/` | Media processing pipeline |

To link these in Rust, use a combination of `build.rs` and Cargo configuration:

**`build.rs`** (in the vision-daemon crate):

```rust
fn main() {
    let sdk = std::env::var("LUCKFOX_SDK_PATH")
        .expect("Set LUCKFOX_SDK_PATH to luckfox-pico SDK root");

    // NPU runtime
    println!("cargo:rustc-link-search=native={sdk}/path/to/librknn_api/armhf");
    println!("cargo:rustc-link-lib=dylib=rknnmrt");

    // RGA
    println!("cargo:rustc-link-search=native={sdk}/media/rga/release_rga_rv1106_arm-rockchip830-linux-uclibcgnueabihf/lib");
    println!("cargo:rustc-link-lib=dylib=rga");

    // ISP
    println!("cargo:rustc-link-search=native={sdk}/media/isp/release_camera_engine_rkaiq_rv1106_arm-rockchip830-linux-uclibcgnueabihf/lib");
    println!("cargo:rustc-link-lib=dylib=rkaiq");

    // MPP
    println!("cargo:rustc-link-search=native={sdk}/media/mpp/release_mpp_rv1106_arm-rockchip830-linux-uclibcgnueabihf/lib");
    println!("cargo:rustc-link-lib=dylib=rkmpi");

    // Allow unresolved symbols from vendor libs (they resolve at runtime on-device)
    println!("cargo:rustc-link-arg=-Wl,--allow-shlib-undefined");
}
```

**Alternative**: Use runtime `dlopen`/`dlsym` via the `libloading` crate instead of link-time binding. This decouples the build from SDK library paths and is the approach used by `opencv-mobile` on this platform.

## Cargo Configuration

### `.cargo/config.toml` (Workspace Root)

```toml
# ── RV1106 Linux target ──────────────────────────────────────
[target.armv7-unknown-linux-uclibceabihf]
linker = "arm-rockchip830-linux-uclibcgnueabihf-gcc"
rustflags = [
  "-C", "link-arg=--sysroot=${RV1106_SYSROOT}",
  "-C", "link-arg=-Wl,--dynamic-linker=/lib/ld-uClibc.so.1",
  "-C", "link-arg=-Wl,--allow-shlib-undefined",
]

# ── RP2040 MCU target (thumbv6m) ─────────────────────────────
[target.thumbv6m-none-eabi]
linker = "flip-link"      # or "arm-none-eabi-ld" / "rust-lld"
runner = "probe-rs run"
rustflags = [
  "-C", "link-arg=-Tlink.x",
  "-C", "link-arg=-Tdefmt.x",
]

# Do NOT set a default [build] target here — each crate is
# built with an explicit --target flag via the build script.
```

### Workspace `Cargo.toml`

```toml
[workspace]
resolver = "2"
members = [
  "vision-daemon",   # → armv7-unknown-linux-uclibceabihf
  "behavior-sidecar",# → (Python, not Rust — placeholder if needed)
  "mcu-firmware",    # → thumbv6m-none-eabi
  "shared-protocol", # → both targets (no_std compatible)
]
```

### Build Commands

Cargo does not natively support building different workspace members for different targets in a single invocation. Use a Makefile, `just`, or `xtask` pattern:

```makefile
.PHONY: vision mcu all

vision:
	cargo +nightly build \
	  -Zbuild-std=std,panic_abort \
	  --target armv7-unknown-linux-uclibceabihf \
	  --release \
	  -p vision-daemon

mcu:
	cargo build \
	  --target thumbv6m-none-eabi \
	  --release \
	  -p mcu-firmware

all: vision mcu
```

> **Key constraint**: The `shared-protocol` crate must be `#![no_std]` compatible (with optional `std` feature) so it can compile under both targets. Use `#[cfg(feature = "std")]` guards around anything that requires `alloc` or `std`.

### Environment Variables for `cc` Crate

Some `-sys` crates use the `cc` crate, which looks for target-specific environment variables:

```bash
export CC_armv7_unknown_linux_uclibceabihf=arm-rockchip830-linux-uclibcgnueabihf-gcc
export CXX_armv7_unknown_linux_uclibceabihf=arm-rockchip830-linux-uclibcgnueabihf-g++
export AR_armv7_unknown_linux_uclibceabihf=arm-rockchip830-linux-uclibcgnueabihf-ar
export CFLAGS_armv7_unknown_linux_uclibceabihf="-march=armv7-a -mfpu=vfpv4-d16 -mfloat-abi=hard"
```

## Summary of Key Decisions

| Concern | Recommendation |
|---|---|
| Rust target triple | `armv7-unknown-linux-uclibceabihf` (built-in, Tier 3) |
| Fallback if EABI mismatch | Custom target JSON with `"vendor": "rockchip"` |
| Linker | SDK GCC as linker driver, not `ld.bfd` directly |
| `std` library | `-Zbuild-std=std,panic_abort` on nightly |
| Vendor `.so` linking | `build.rs` with link-search paths, or runtime `dlopen` |
| MCU crate (RP2040) | `thumbv6m-none-eabi` — stable Tier 2 target |
| Shared code | `#![no_std]` crate with optional `std` feature |
| Build orchestration | Per-crate `--target` flags via Makefile / `just` / xtask |
