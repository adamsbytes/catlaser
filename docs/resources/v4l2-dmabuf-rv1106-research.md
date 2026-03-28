# V4L2 DMA Buffer Capture on RV1106 with SC3336

Research notes for a pure-Rust V4L2 ioctl capture module targeting the Luckfox Pico Ultra W (RV1106G3) with an SC3336 MIPI CSI sensor.

---

## 1. RV1106 Camera Pipeline Architecture

The RV1106 exposes two V4L2/media-controller driver families for camera capture:

**RKCIF (`rkcif-mipi-lvds`)** — the Camera Interface. Receives raw Bayer frames from the MIPI CSI-2 D-PHY and writes them to memory. On a typical Luckfox Pico, this creates `/dev/video0`–`/dev/video10` plus a media device (`/dev/media0` or `/dev/media2`, depending on kernel config). Frames captured from CIF nodes are **raw sensor data** (e.g. `SBGGR10_1X10` for the SC3336) and have not passed through the ISP — they will appear dark/greenish without ISP processing.

**RKISP (`rkisp-vir0`)** — the Image Signal Processor. Connects downstream of CIF via an internal `sditf` link. Creates `rkisp_mainpath` and related video nodes (typically `/dev/video11`–`/dev/video22` depending on build). The mainpath supports ISP-processed YUV output (NV12, NV21, UYVY, NV16, etc.) at resolutions up to 2304×1296 for single-cam. The ISP handles demosaic, 3A (AE/AF/AWB), HDR, noise reduction, and gamma correction in hardware (ISP 3.2, up to 5MP).

**Typical device listing on Luckfox Pico (Buildroot):**

```
rkisp-statistics (platform: rkisp):     /dev/video23, /dev/video24
rkcif-mipi-lvds (platform:rkcif):       /dev/media2
rkcif (platform:rkcif-mipi-lvds):       /dev/video4–/dev/video14
rkisp_mainpath (platform:rkisp-vir0):   /dev/video15–/dev/video22, /dev/media3
```

Video node numbers vary across firmware builds. Always discover them via `v4l2-ctl --list-devices` or by walking `/sys`.

### Which node to open

For ISP-processed NV12 frames suitable for NPU inference, open the **`rkisp_mainpath`** node (driver name `rkisp_v7`, card `rkisp_mainpath`). This is a **multiplanar** device (`V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE`, capability flag `0x84201000`). The mainpath supports NV12 at up to 2304×1296 on the SC3336.

**Critical:** The default Luckfox firmware runs `rkipc`, which holds the ISP pipeline open. You must `killall rkipc` (and stop any `rockit` services) before your application can claim the device.

---

## 2. ISP Pipeline Format Negotiation for SC3336

The SC3336 is a SmartSens 3MP sensor outputting raw Bayer SBGGR10 at up to 2304×1296 @ 25fps over 2-lane MIPI CSI-2. The format negotiation chain through the media controller is:

```
SC3336 sensor (SBGGR10_1X10 / 2304×1296)
    → MIPI CSI-2 D-PHY
    → rkcif-mipi-lvds (raw Bayer capture)
    → sditf bridge → rkisp-isp-subdev
    → rkisp_mainpath (NV12 / YUV output)
```

The ISP subdevice performs the Bayer-to-YUV conversion. When using `media-ctl` from the command line, the pipeline is configured as:

```bash
# Reset links
media-ctl -d platform:rkisp -r

# Link sensor → ISP
media-ctl -d platform:rkisp -l "'sc3336 1-0030':0 -> 'rkisp-isp-subdev':0 [1]"

# Set sensor pad format (raw Bayer in)
media-ctl -d platform:rkisp --set-v4l2 \
  '"sc3336 1-0030":0 [fmt:SBGGR10_1X10/2304x1296]'

# Set ISP sink pad (matches sensor)
media-ctl -d platform:rkisp --set-v4l2 \
  '"rkisp-isp-subdev":0 [fmt:SBGGR10_1X10/2304x1296 crop:(0,0)/2304x1296]'

# Set ISP source pad (YUV out)
media-ctl -d platform:rkisp --set-v4l2 \
  '"rkisp-isp-subdev":2 [fmt:YUYV8_2X8/2304x1296 crop:(0,0)/2304x1296]'
```

**In practice on Luckfox Buildroot**, the kernel + `rkipc`/`rkaiq` services handle all media-controller link setup automatically via the device tree and IQ (Image Quality) tuning files in `/etc/iqfiles/`. For a pure V4L2 userspace application, you typically only need to:

1. Open the `rkisp_mainpath` video device
2. Call `VIDIOC_S_FMT` with your desired resolution and pixel format
3. The ISP pipeline is already linked by the kernel's async subdev framework

However, **the ISP's 3A (auto-exposure, auto-white-balance, auto-focus) requires the `rkaiq` library** (`librkaiq.so`) to feed parameters into the `rkisp-input-params` metadata node and read statistics from the `rkisp-statistics` node. Without `rkaiq`, the ISP will produce frames but with no automatic exposure/gain/WB adjustment — the image may be too dark or color-shifted.

**For a cat laser (NPU inference), this may be acceptable** — a fixed-exposure configuration can work if ambient lighting is controlled, and the NPU model may tolerate imperfect color balance.

---

## 3. V4L2 DMABUF Streaming Lifecycle

### 3.1 The two DMABUF patterns

V4L2 supports two DMABUF workflows:

**DMABUF Exporting** (`VIDIOC_EXPBUF`): Allocate buffers with `V4L2_MEMORY_MMAP`, then export each as a DMABUF fd. The V4L2 driver owns the allocation; the fd can be passed to other DMA-aware consumers (e.g. hardware encoder, RGA, NPU). This is the standard approach.

**DMABUF Importing** (`V4L2_MEMORY_DMABUF`): Someone else allocates the DMABUF (e.g. via a DMA heap or another device), and you pass the fd into V4L2 at `VIDIOC_QBUF` time. The V4L2 device writes captured frames into the externally-provided buffer.

### 3.2 Recommended flow: MMAP + EXPBUF

For the RV1106, the MMAP+EXPBUF pattern is better documented and more reliable. The CIF/ISP drivers allocate from CMA (which on RV1106 uses Rockchip's custom CMA allocator, not standard Linux CMA). Community reports indicate that direct `V4L2_MEMORY_DMABUF` importing has been unreliable on this platform.

**Ioctl sequence (multiplanar):**

```
1. open("/dev/videoN", O_RDWR)          // rkisp_mainpath

2. VIDIOC_QUERYCAP                      // verify V4L2_CAP_VIDEO_CAPTURE_MPLANE
                                        //   and V4L2_CAP_STREAMING

3. VIDIOC_S_FMT                         // type = VIDEO_CAPTURE_MPLANE
                                        // pixelformat = V4L2_PIX_FMT_NV12
                                        // width = 640, height = 480
                                        // num_planes = 1

4. VIDIOC_REQBUFS                       // type = VIDEO_CAPTURE_MPLANE
                                        // memory = V4L2_MEMORY_MMAP
                                        // count = 4 (request 4, driver may adjust)

5. For each buffer i in 0..count:
   a. VIDIOC_QUERYBUF(i)               // get plane lengths, offsets
   b. mmap() each plane                // map to userspace (for CPU access)
   c. VIDIOC_EXPBUF(i, plane=0)        // get DMABUF fd for zero-copy
                                        // to NPU/encoder

6. For each buffer i in 0..count:
      VIDIOC_QBUF(i)                   // enqueue all buffers

7. VIDIOC_STREAMON                      // start capture

8. Capture loop:
   a. poll() / select() on fd          // wait for frame ready
   b. VIDIOC_DQBUF                     // dequeue filled buffer
                                        // → buf.index tells you which buffer
                                        // → buf.timestamp has the frame time
   c. Process frame (CPU via mmap ptr,
      or zero-copy via DMABUF fd)
   d. VIDIOC_QBUF(buf.index)           // re-enqueue for reuse

9. VIDIOC_STREAMOFF                     // stop capture
10. close() all DMABUF fds
11. munmap() all mappings
12. VIDIOC_REQBUFS(count=0)             // free buffers (or just close fd)
```

### 3.3 Key ioctl details

**REQBUFS**: Sets the I/O method and requests buffer allocation. With `V4L2_MEMORY_MMAP`, the driver allocates from its internal pool (CMA on RV1106). The driver may return a different `count` than requested. Calling REQBUFS while buffers are still mapped/queued is undefined; call STREAMOFF first.

**QBUF**: Enqueues a buffer into the driver's incoming queue. For MMAP, set `type`, `memory`, and `index`. For DMABUF importing, also set `m.fd` (single-plane) or `planes[i].m.fd` (multiplanar). The driver locks the buffer for DMA — accessing a queued buffer from userspace is undefined behavior.

**DQBUF**: Dequeues a filled buffer from the driver's outgoing queue. Blocks by default; returns `EAGAIN` if the fd was opened with `O_NONBLOCK`. The returned `v4l2_buffer` contains the buffer index, timestamp, bytesused, and flags. Check `V4L2_BUF_FLAG_ERROR` — if set, the frame may be corrupted but the buffer is safe to re-enqueue.

**EXPBUF**: Exports an MMAP buffer as a DMABUF file descriptor. Only works on MMAP-mode queues. The returned fd can be passed to other DMA-aware devices (NPU, hardware encoder, RGA) for zero-copy processing. Close the fd when done to release the DMA-BUF reference.

**STREAMOFF**: Stops streaming, dequeues all buffers from both queues, and unlocks all buffer memory. This is an implicit dequeue of everything.

### 3.4 Buffer lifecycle state machine

```
        QBUF
  FREE ──────► QUEUED (driver input queue)
   ▲                    │
   │                    │ hardware DMA fills buffer
   │                    ▼
   │            DONE (driver output queue)
   │                    │
   │              DQBUF │
   │                    ▼
   └──── QBUF ── DEQUEUED (userspace owns it)
```

A buffer is **locked** (unsafe to access from CPU) from QBUF until DQBUF returns it. STREAMOFF forcibly moves all buffers back to FREE.

---

## 4. Rust Implementation Notes

### 4.1 Crate options

**`v4l2r`** (crates.io): Full-featured Rust V4L2 bindings with safe wrappers around every ioctl. Provides typed representations of `v4l2_buffer`, `v4l2_format`, `v4l2_requestbuffers` etc. Handles the multiplanar/single-planar format distinction cleanly. Generates bindings from `videodev2.h` at build time via `bindgen`.

**`libv4l-rs`** (crates.io): Higher-level but less complete. Two backend modes: `libv4l` (wraps the userspace library, emulates formats but no DMABUF/userptr support) or `v4l2` (raw kernel API, full feature support). For DMABUF work, use the `v4l2` feature.

**Raw ioctls via `nix`/`libc`**: For maximum control and minimal dependencies on a constrained embedded target, define the ioctl numbers and structs manually using `nix::ioctl_readwrite!` macros or raw `libc::ioctl()`. This is the most common approach for embedded V4L2 in Rust — define just the 5-6 structs and ~8 ioctl numbers you actually need.

### 4.2 Key ioctl numbers (from `videodev2.h`)

```
VIDIOC_QUERYCAP     = _IOR('V',  0, struct v4l2_capability)
VIDIOC_S_FMT        = _IOWR('V', 5, struct v4l2_format)
VIDIOC_REQBUFS      = _IOWR('V', 8, struct v4l2_requestbuffers)
VIDIOC_QUERYBUF     = _IOWR('V', 9, struct v4l2_buffer)
VIDIOC_QBUF         = _IOWR('V', 15, struct v4l2_buffer)
VIDIOC_DQBUF        = _IOWR('V', 17, struct v4l2_buffer)
VIDIOC_STREAMON      = _IOW('V', 18, int)
VIDIOC_STREAMOFF     = _IOW('V', 19, int)
VIDIOC_EXPBUF       = _IOWR('V', 16, struct v4l2_exportbuffer)
```

### 4.3 Multiplanar handling

The RKISP mainpath is a multiplanar device. Even though NV12 is logically two planes (Y + UV), the driver exposes it as **1 plane** in the multiplanar API (the Y and UV data are contiguous in the single plane buffer, with UV starting at `height × stride`). You still must use `v4l2_buffer` with the `m.planes` pointer set to a `v4l2_plane` array, and `length` set to the number of planes (1 for NV12 on this driver).

### 4.4 Non-blocking capture for real-time control

For a cat laser running at a target control rate, open the device with `O_NONBLOCK` and use `poll()`/`epoll()` to integrate frame arrival into your event loop. DQBUF returns `EAGAIN` when no frame is ready, letting you interleave frame capture with UART communication to the RP2040 servo controller.

---

## 5. RV1106-Specific Pitfalls

**CMA allocation**: The RV1106 uses Rockchip's custom CMA for camera buffers, not standard Linux CMA. This means `V4L2_MEMORY_DMABUF` importing (where *you* allocate the buffer externally) has been reported as unreliable. Prefer `V4L2_MEMORY_MMAP` + `VIDIOC_EXPBUF` for zero-copy sharing.

**ISP exclusivity**: Only one consumer can hold the ISP pipeline at a time. The default `rkipc` service must be stopped. The RKMPI library (`librkmpi.so`) and the ISP/encoder hardware are not open-source — direct V4L2 access bypasses Rockchip's proprietary stack.

**No rkaiq = no 3A**: Without running `rkaiq`, the ISP won't adjust exposure, gain, or white balance. Frames will use whatever parameters were set at initialization. For a fixed indoor environment, you can set manual exposure via V4L2 controls (`V4L2_CID_EXPOSURE`, `V4L2_CID_GAIN`) on the sensor subdevice.

**RKISP driver version**: The Luckfox SDK ships a Rockchip-patched kernel 5.10 with `rkisp_v7` driver. This is not the upstream `rkisp1` driver in mainline Linux — the ioctl behavior, video node layout, and supported formats differ.

---

## Sources

- Linux kernel documentation: Streaming I/O (DMA buffer importing), kernel.org
- Linux kernel documentation: ioctl VIDIOC_QBUF/VIDIOC_DQBUF, kernel.org
- Linux kernel documentation: ioctl VIDIOC_EXPBUF, kernel.org
- Linux kernel documentation: Rockchip ISP1 (rkisp1), docs.kernel.org
- Rockchip open source wiki: Rockchip-isp1 topology, opensource.rock-chips.com
- Luckfox Wiki: CSI Camera guide, wiki.luckfox.com
- Luckfox Forums: DMABUF mode for V4L2 (thread #924), forums.luckfox.com
- Luckfox Forums: Core1106 dual cam support (thread #1456), forums.luckfox.com
- GitHub LuckfoxTECH/luckfox-pico: SC3336 format question (issue #125)
- v4l2r crate documentation, docs.rs/v4l2r
- Gnurou/v4l2r GitHub repository
- Dorota Czaplejewicz: Notes on DMABUF and video, dorotac.eu
