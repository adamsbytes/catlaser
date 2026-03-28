# Rockchip MPP Hardware Encoding on RV1106

## What MPP Is

MPP (Media Process Platform) is Rockchip's userspace library for hardware-accelerated video encoding and decoding. It provides a unified API (called MPI — Media Process Interface) that abstracts away chip-specific hardware encoder differences. MPP talks to the kernel via the `mpp_service` device driver (`/dev/mpp_service`), which is a stateless, frame-based driver distinct from the V4L2 codec driver used on ChromeOS.

MPP's architecture is layered: the **MPI** layer faces user applications, a **codec** layer handles protocol-specific parsing and encoding logic (H.264, H.265, JPEG), and a **HAL** (Hardware Abstraction Layer) generates register configurations for specific hardware encoder cores and communicates with the kernel driver.

Source: [github.com/rockchip-linux/mpp](https://github.com/rockchip-linux/mpp), [opensource.rock-chips.com/wiki_Mpp](https://opensource.rock-chips.com/wiki_Mpp)

## RV1106 Encoder Hardware

The RV1106 contains a VEPU (Video Encoder Processing Unit) hardware block, identified in the device tree as `rockchip,rkv-encoder-rv1106` at register base `0xffa50000`. It has three clock domains: `ACLK_VEPU` (300 MHz), `HCLK_VEPU`, and `CLK_CORE_VEPU` (400 MHz). The encoder supports **H.265 and H.264** encoding, with multi-stream encoding capability — the datasheet describes simultaneous high-resolution local recording and lower-resolution cloud streaming.

The device tree node also references `dvbm = <&rkdvbm>`, which is the **Direct Video Buffer Manager** — Rockchip's mechanism for zero-copy buffer handoff between the ISP output and the encoder input. The kernel module `rk_dvbm` is loaded alongside `mpp_vcodec` and `video_rkisp`, and its `Used by` count confirms both modules depend on it. This is the hardware-level ISP→encoder bridge.

The encoder additionally includes a 22-unit intelligent video engine that enables scene-adaptive bitrate savings — Rockchip claims over 50% bitrate reduction versus conventional CBR in certain scenarios.

Sources: [RV1106 device tree](https://github.com/LuckfoxTECH/luckfox-pico/blob/main/sysdrv/source/kernel/arch/arm/boot/dts/rv1106.dtsi), [RV1106 Datasheet Rev 1.3](https://studylib.net/doc/27853048/rockchip-rv1106-datasheet-v1.3-202305221), [lsmod output from Luckfox wiki](https://wiki.luckfox.com/Luckfox-Pico-Pi/MPI/)

## Two API Layers: Raw MPP vs RKMPI

There are two ways to drive the encoder on RV1106:

**Raw MPP (low-level):** You call `mpp_create()` → `mpp_init(MPP_CTX_ENC)` → configure prep/rc/codec params → call `encode_put_frame()` / `encode_get_packet()` in a loop. This is the approach used in `mpi_enc_test` and is what FFmpeg's `h264_rkmpp`/`hevc_rkmpp` encoders wrap. You manage buffer allocation and frame input yourself.

**RKMPI / Rockit (high-level):** This is the Luckfox Pico SDK's preferred path. It provides a module-binding system where you connect pipeline stages: **VI** (video input / ISP capture) → **VPSS** (video processing subsystem, scaling/cropping) → **VENC** (video encoder). You bind them with `RK_MPI_SYS_Bind()` and the data flows automatically without CPU-side frame copies. The VENC module wraps MPP internally.

For your project, **RKMPI is the practical choice** on the Luckfox Pico Ultra W. The Luckfox SDK examples (`simple_vi_bind_venc`, the RTSP+YOLOv5 demo) all use this path. The `rockit` kernel module orchestrates the pipeline and depends on `mpp_vcodec`.

Sources: [Luckfox RKMPI wiki](https://wiki.luckfox.com/Luckfox-Pico-Pi/MPI/), [Rockchip MPP developer guide](https://github.com/rockchip-linux/mpp/blob/develop/doc/Rockchip_Developer_Guide_MPP_EN.md), [Luckfox RKMPI examples](https://github.com/LuckfoxTECH/luckfox_pico_rkmpi_example)

## ISP → Encoder Buffer Handoff

The data path on RV1106 is:

```
Sensor → MIPI CSI → rkcif (Camera Interface) → rkisp (ISP3.2) → [DVBM] → VEPU (encoder)
```

The key detail is the `rk_dvbm` kernel module. It enables a **direct memory path** between the ISP output and the encoder input, bypassing the CPU. In `lsmod` output on a running Luckfox board, `rk_dvbm` shows as used by both `mpp_vcodec` and `video_rkisp`, confirming it bridges the two hardware blocks.

When using RKMPI's bind system (`VI→VPSS→VENC`), this buffer handoff is set up automatically. The VPSS module can tap into the stream for scaling (e.g., producing a lower-resolution branch for NPU inference) while the main resolution flows to VENC. The memory buffer pool is managed by RKMPI internally using `MppBufferGroup`, with DMA-BUF file descriptors for zero-copy sharing between hardware blocks.

If you need to also feed frames to the NPU for cat detection, a typical pipeline forks at VPSS: one channel goes to VENC for the stream, another channel (scaled down) goes to `RK_MPI_VPSS_GetChnFrame()` for NPU inference.

Sources: [Luckfox RKMPI wiki](https://wiki.luckfox.com/Luckfox-Pico-Pi/MPI/), [Luckfox forums pipeline discussion](https://forums.luckfox.com/viewtopic.php?t=2235), [lsmod analysis](https://github.com/themrleon/luckfox-pico-mini-b)

## Encoder Configuration for WebRTC

### Rate Control Modes

MPP supports four rate control modes: **VBR** (variable, default), **CBR** (constant), **FIXQP** (fixed quantization parameter), and **AVBR** (adaptive). For WebRTC streaming, **CBR** is generally preferred to avoid bitrate spikes that overwhelm the WebRTC transport. Key parameters:

- `rc_mode`: 0=VBR, 1=CBR, 2=FIXQP, 3=AVBR
- `bps_target`: target bitrate in CBR mode
- `bps_max` / `bps_min`: bitrate bounds in VBR mode
- `fps_in_num` / `fps_out_num`: input/output frame rate numerators (default 30/1)
- `gop`: I-frame interval (0 = only one I-frame; for WebRTC, periodic IDR frames are needed for recovery)
- `qp_init`, `qp_min`, `qp_max`: quantization parameter bounds

### H.264 Output Format

The VENC H.264 output from `RK_MPI_VENC_GetStream()` is in **Annex B format** (start code delimited NAL units, `0x00000001` prefixes). SPS/PPS are included with I-frames. For WebRTC packetization, the `VENC_STREAM_S` structure's `pstPack->pMbBlk` data (accessed via `RK_MPI_MB_Handle2VirAddr()`) can be fed directly to an RTP packetizer configured for Annex B start codes.

### Encoding Type Setup (RKMPI)

```c
VENC_CHN_ATTR_S stAttr;
stAttr.stVencAttr.enType = RK_VIDEO_ID_AVC;        // H.264
stAttr.stVencAttr.u32Profile = H264E_PROFILE_MAIN;  // Baseline/Main/High
// For H.265: enType = RK_VIDEO_ID_HEVC
```

Sources: [Luckfox forums WebRTC thread](https://forums.luckfox.com/viewtopic.php?t=1860), [Luckfox RKMPI wiki](https://wiki.luckfox.com/Luckfox-Pico-Pi/MPI/), [MPP developer guide rate control docs](https://opensource.rock-chips.com/wiki_Mpp)

## Kernel Modules Required

A working encoding pipeline on RV1106 requires these kernel modules (verified from Luckfox board `lsmod`):

| Module | Role |
|---|---|
| `rockit` | High-level multimedia framework, orchestrates pipeline |
| `mpp_vcodec` | MPP video codec kernel interface (used by rockit) |
| `rga3` | 2D graphics accelerator (scaling, format conversion) |
| `rk_dvbm` | Direct Video Buffer Manager (ISP↔encoder zero-copy) |
| `video_rkisp` | ISP3.2 driver |
| `video_rkcif` | Camera interface (MIPI CSI receiver) |
| Sensor driver (e.g. `sc3336`) | Camera sensor specific |

The default Luckfox image runs `rkicp` in the background which holds the camera. Run `RkLunch-stop.sh` before starting your own pipeline.

Sources: [Luckfox RKMPI wiki](https://wiki.luckfox.com/Luckfox-Pico-Pi/MPI/), [Luckfox RKMPI examples README](https://github.com/LuckfoxTECH/luckfox_pico_rkmpi_example)

## Practical Considerations for Your Project

**H.264 vs H.265 for WebRTC:** H.264 has broader browser support and is the safer choice for WebRTC. H.265 is more bandwidth-efficient but WebRTC client support is inconsistent. The RV1106 encoder handles both in hardware at equivalent CPU cost (near zero — it's all VEPU).

**Multi-stream encoding:** The encoder supports simultaneous multi-stream output. You could encode a main 1080p H.264 stream for WebRTC and a lower-resolution stream for recording, or use the VPSS fork to feed a scaled-down frame to the NPU while the full-resolution frame goes to the encoder.

**Latency:** The RKMPI bind pipeline is designed for IPC use and adds minimal latency. The main WebRTC latency sources will be network-side (STUN/TURN, jitter buffer), not encode-side. The Luckfox forums report issues with WebRTC disconnection after ~1 minute due to STUN consent expiry and buffer overflow under motion — this is a libdatachannel/network tuning issue, not an encoder issue.

**CPU budget:** The entire encode path (ISP → DVBM → VEPU) runs in dedicated hardware. The Cortex-A7 CPU is free for your application logic: UART communication with the RP2040, NPU inference scheduling, and WebRTC signaling. Forum users report the main CPU consumers are the RTSP/WebRTC networking stack and NPU inference, not encoding.

**Key device nodes:** `/dev/mpp_service` (encoder), `/dev/dri` (DRM allocator), `/dev/dma_heap` (DMA-BUF allocator), `/dev/rga` (2D accelerator).
