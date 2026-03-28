# Rockchip rkaiq ISP 3A Library Integration on the RV1106

## Overview

The RV1106 contains Rockchip's ISP v3.2 (identified as `ISP HW ver: 32` in logs), capable of processing up to 5 megapixels. The `librkaiq.so` library (RkAiq — Rockchip Auto Image Quality) is the userspace component that closes the 3A control loop: it reads ISP statistics, runs auto-exposure (AE), auto-white-balance (AWB), and auto-gain algorithms, then writes new parameters back to the ISP hardware. Without it, captured frames appear dark and green-tinted because no 3A tuning occurs.

On the Luckfox Pico SDK for RV1106, the current release ships **AIQ v5.0x5.0** with JSON-format IQ files.

## Integration Modes

RkAiq offers two integration paths, both fully supported on the RV1106:

**Standalone process (`rkaiq_3A_server`):** The library runs inside a separate daemon that communicates with the ISP kernel driver autonomously. Applications capture from the ISP video nodes via plain V4L2 (or GStreamer `v4l2src`, VLC, etc.) and receive ISP-tuned frames with no code changes. The server exposes a UNIX domain socket at `/tmp/UNIX.domain0` for external control. This is the lowest-effort approach.

**In-process linking (`librkaiq.so` directly):** The application links against `librkaiq.so` and calls the rkaiq API itself. The library internally opens the ISP's metadata V4L2 nodes to run its 3A loop. The application separately opens the ISP capture node (e.g., `rkisp_mainpath`) for frame data. This is the approach used by the Luckfox RKMPI examples and the opencv-mobile project, and is the recommended path for the catlaser Rust vision daemon.

## Initialization API Sequence

When linking `librkaiq.so` directly, the call sequence is:

1. **`rk_aiq_uapi2_sysctl_enumStaticMetas(cam_id, &static_info)`** — Queries sensor identity and resolution from the kernel driver. Returns the sensor name string (e.g., `m00_b_sc3336 4-0030`).

2. **`rk_aiq_uapi2_sysctl_preInit_scene(main_scene, sub_scene)`** *(optional)* — Sets the IQ scene preset (typically `"normal"` / `"day"`).

3. **`rk_aiq_uapi2_sysctl_preInit_devBufCnt(entity_name, buf_cnt)`** *(optional)* — Configures internal buffer counts for raw-receive entities.

4. **`rk_aiq_uapi2_sysctl_init(sensor_name, iq_file_dir, err_cb, sof_cb)`** — Core initialization. Loads the IQ JSON file matching the sensor name from the specified directory (typically `/etc/iqfiles/`). Internally discovers and opens the ISP's metadata V4L2 nodes.

5. **`rk_aiq_uapi2_sysctl_prepare(ctx, width, height, mode)`** — Configures the ISP pipeline resolution and working mode (e.g., `RK_AIQ_WORKING_MODE_NORMAL` for SDR).

6. **`rk_aiq_uapi2_sysctl_start(ctx)`** — Starts the sensor data stream and the internal 3A algorithm loop. After this call, the sensor begins outputting data, the ISP processes it, and tuned frames become available on `rkisp_mainpath`.

7. *(Application captures frames via V4L2 on `rkisp_mainpath`)*

8. **`rk_aiq_uapi2_sysctl_stop(ctx)`** — Stops the 3A loop and sensor streaming. Must be called before stopping the V4L2 capture data flow.

The Luckfox SDK wraps steps 1–6 in `SAMPLE_COMM_ISP_Init()` / `SAMPLE_COMM_ISP_Run()` helper functions, which can serve as a reference for the Rust FFI bindings.

## Communication via V4L2 Metadata Nodes

The RKISP kernel driver creates a media-controller topology with several V4L2 video device nodes. The ones relevant to 3A are:

**`rkisp-statistics`** — A V4L2 metadata capture node (output direction, from kernel to userspace). The ISP hardware writes per-frame 3A statistics (luminance histograms, color channel averages, focus metrics) into buffers on this node. The `librkaiq.so` library dequeues these buffers internally, feeds the data to its AE/AWB/AF algorithms, and computes new ISP parameters. The buffer format is identified by `V4L2_META_FMT_RK_ISP1_STAT_3A`.

**`rkisp-input-params`** — A V4L2 metadata output node (input direction, from userspace to kernel). The library queues buffers containing computed ISP parameter updates (black level, color correction matrices, gamma curves, noise reduction settings, lens shading correction tables, etc.) to this node. The ISP driver applies them to the hardware on the next frame. The buffer format is identified by `V4L2_META_FMT_RK_ISP1_PARAMS`.

On a typical Luckfox Pico Ultra W with SC3336, the `rkaiq_3A_server` debug output confirms this discovery:

```
DBG: get rkisp-input-params devname: /dev/video19
DBG: get rkisp-statistics devname: /dev/video18
DBG: get rkisp_mainpath devname: /dev/video11
```

The exact `/dev/videoN` numbers vary by DTS configuration, but the entity names are stable. The library uses the Linux media-controller API (`/dev/mediaX`) to discover these nodes by entity name at init time — your application does not need to hard-code device paths.

## IQ Tuning File for the SC3336

The IQ (Image Quality) tuning file stores all algorithm-specific parameters and sensor calibration data that RkAiq needs. On AIQ v5.x (the version shipping with the Luckfox RV1106 SDK), the format is **JSON**. (Older AIQ v1.x/v2.x platforms used XML; a converter tool `iqConverTer` exists in the Rockchip SDK but is not needed here.)

The file for the SC3336 on the standard Luckfox camera module is:

```
/etc/iqfiles/sc3336_CMK-OT2119-PC1_30IRC-F16.json
```

The naming convention encodes: `{sensor}_{module-vendor-model}_{lens-spec}.json`. The init call matches the sensor name reported by the kernel driver (via `RKMODULE_GET_MODULE_INFO` ioctl) against filenames in the IQ directory.

The JSON file contains calibration sections including (non-exhaustive): AE strategy and exposure tables, AWB color temperature presets and light-source characterization, black level correction per ISO, color correction matrices (CCM), lens shading correction (LSC) meshes, noise profiles for spatial/temporal denoising, gamma/tone curves, sharpening kernels, and HDR merge parameters. These are generated using Rockchip's proprietary **RKISPTuner** desktop tool during sensor+lens bring-up. For a custom lens/IR-cut assembly, you would need to re-tune; for the stock SC3336 module, the shipped JSON file works out of the box.

## Coexistence: rkaiq + Direct V4L2 Capture on `rkisp_mainpath`

**Yes, rkaiq can coexist with an application that directly opens `rkisp_mainpath` for V4L2 capture. You do not need to use RKMPI's VI module.**

This is architecturally sound because rkaiq and the application's frame capture operate on *different* V4L2 device nodes:

- **rkaiq** opens `rkisp-statistics` (read stats) and `rkisp-input-params` (write params) — the metadata control plane.
- **Your application** opens `rkisp_mainpath` (read frames) — the data plane.

These are independent V4L2 video devices within the same media-controller graph. There is no mutual exclusion between them.

This pattern is demonstrated in practice by the **opencv-mobile** project (nihui/opencv-mobile), which on the Luckfox Pico boards initializes `librkaiq.so` in-process and then captures NV12 frames from `/dev/video11` (`rkisp_mainpath`) using standard V4L2 `MMAP` ioctls. Community users on the Luckfox forums have confirmed this works on the RV1106 with SC3336.

### Caveats for the RV1106

- **CMA memory quirk:** The RV1106 uses a non-standard CMA allocation path for camera buffers. V4L2 `MMAP` mode works. V4L2 `DMABUF` export from `rkisp_mainpath` for zero-copy to the hardware encoder is more complex — Luckfox forum reports indicate that raw V4L2 DMABUF without RKMPI has not been fully proven on this SoC. If you need zero-copy DMABUF to the MPP encoder, using RKMPI's VI+VENC pipeline (which handles the CMA allocation internally) may be more reliable.

- **Online vs. offline ISP mode:** The RV1106 SDK defaults to `isOnline:1` mode where the CIF feeds the ISP directly without writing raw frames to DRAM. In this mode, when rkaiq is active, plain `v4l2-ctl --stream-mmap` from the CIF node (not the ISP node) does not work — you must capture from the ISP output nodes (`rkisp_mainpath` or `rkisp_selfpath`). This is the correct approach anyway.

- **Single consumer constraint:** Only one process should open `rkisp_mainpath` for streaming at a time. If the default `rkipc` daemon is running, you must stop it first (`RkLunch-stop.sh` or `killall rkipc`) before your vision daemon can claim the node.

## Recommended Architecture for the Catlaser Vision Daemon

For the Rust vision daemon that needs 640×480 NV12 at ~15 FPS with 3A tuning:

1. Create Rust FFI bindings for the rkaiq `uapi2` init/prepare/start/stop functions (4–6 C calls via `extern "C"`).
2. Call the rkaiq init sequence at startup, pointing to `/etc/iqfiles/`.
3. Open `rkisp_mainpath` with V4L2 in `MMAP` mode, configure for 640×480 NV12.
4. Dequeue frames in your capture loop → feed to RKNN for YOLOv8n inference.
5. For the LiveKit H.264/H.265 stream, either use MPP's encoder API directly with the captured buffers, or if zero-copy DMABUF proves problematic, fall back to RKMPI's `VI→VENC` binding for the encoding path while keeping your own V4L2 capture for the NPU path.

This approach avoids the full RKMPI dependency for the primary vision pipeline while still getting proper 3A image quality from the SC3336.
