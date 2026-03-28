# LiveKit WebRTC Integration with Hardware-Encoded H.264 on Embedded Linux (RV1106)

## 1. Problem Statement

The Catlaser vision daemon must stream live 640×480 video from an RV1106G3 to native apps via LiveKit WebRTC. The RV1106's dedicated VPU produces H.264 NAL units through Rockchip's RKMPI VENC API. The challenge is getting those pre-encoded bitstreams into a LiveKit room without redundant software re-encoding on a single-core Cortex-A7 with 256 MB RAM.

## 2. The Rust LiveKit SDK Architecture

The LiveKit Rust SDK (`livekit` crate on crates.io) wraps Google's libwebrtc via C++ FFI bindings (`webrtc-sys` crate). It requires the Tokio async runtime. The publish path for video is:

1. Create a `NativeVideoSource` (wraps libwebrtc's `VideoTrackSource`).
2. Build a `LocalVideoTrack` from that source.
3. Call `room.local_participant().publish_track(track, options)`.
4. Feed frames via `video_source.capture_frame(&video_frame)`.

The SDK currently expects **raw YUV frames** (I420/NV12 `VideoFrame` buffers). libwebrtc's internal encoder pipeline then compresses them using its own `VideoEncoder` implementation (software OpenH264 or platform-specific HW encoders where supported). There is no first-class API in the LiveKit Rust SDK for injecting pre-encoded H.264 NAL units directly — confirmed by GitHub issue #503 (hardware encoding support, Dec 2024) which found that `VideoConfiguration::hardware_encoder` exists in protobuf definitions but is not wired through the Rust SDK's public API.

## 3. Strategies for Feeding Pre-Encoded H.264

Because the SDK does not expose a pre-encoded frame path, three integration strategies exist, each with different tradeoffs:

### 3a. Passthrough Encoder (Custom libwebrtc Build)

This is the approach validated by NVIDIA's Jetson WebRTC integration and the `Webrtc-H264Capturer` project. The concept involves implementing a custom `webrtc::VideoEncoder` that acts as a no-op passthrough:

- The custom encoder's `Encode()` method receives raw frames but ignores them.
- Instead, the encoder holds a reference to the external H.264 bitstream queue.
- When `Encode()` is called, it dequeues the next hardware-encoded NAL unit buffer, wraps it in an `EncodedImage`, and fires the `EncodedImageCallback`.
- The encoder must respond to `RequestKeyFrame()` by signaling the RKMPI VENC channel to produce an IDR.
- The encoder must implement `SetRates()` to relay bitrate/framerate targets back to the RKMPI encoder.

This requires forking LiveKit's `webrtc-sys` bindings to register a custom `VideoEncoderFactory` that returns this passthrough encoder for H.264. The `LK_CUSTOM_WEBRTC` environment variable (documented in the Rust SDK build system) allows pointing at a custom libwebrtc build.

**Critical NAL formatting detail**: Rockchip's RKMPI VENC outputs Annex B format (start-code-delimited NALs: `0x00 0x00 0x00 0x01`). libwebrtc's H.264 packetizer also expects Annex B. Each IDR frame **must** be preceded by SPS and PPS NALs — the RKMPI VENC emits them on the first IDR but may omit them on subsequent keyframes. The passthrough encoder must cache the initial SPS/PPS and prepend them to every IDR, otherwise receivers will issue continuous PLI/FIR requests and the stream will never render.

### 3b. Feed Raw NV12 and Let libwebrtc Re-encode (Baseline Fallback)

The simplest path: feed NV12 frames from RKISP into `NativeVideoSource::capture_frame()`. libwebrtc's bundled OpenH264 software encoder handles compression. On a 1.0 GHz Cortex-A7, OpenH264 encoding 640×480@15fps is feasible but expensive — expect 60–80% CPU utilization, leaving little headroom for the NPU inference pipeline. This approach wastes the dedicated hardware VPU entirely.

### 3c. Bypass LiveKit SDK — Use Pion-style RTP Injection

JetKVM (another RV1106G3 product) takes this approach: their Go application uses Pion WebRTC, which handles only transport — encoding is entirely external. The application feeds RKMPI VENC's H.264 output directly into Pion's RTP packetizer. This is possible because Pion does not bundle an encoder; it accepts pre-packetized or raw H.264 NAL units.

For a Rust equivalent, the `webrtc-rs` crate (a pure-Rust WebRTC stack ported from Pion) can accept pre-encoded H.264 via its `Track` API. However, this means **not using the LiveKit Rust client SDK at all** — you would need to implement LiveKit's signaling protocol manually or use only `livekit-api` for token generation and room management while handling WebRTC transport yourself.

## 4. SDP Negotiation for Hardware Codec Profiles

### Profile-Level-ID

The SDP `fmtp` line for H.264 carries a `profile-level-id` parameter — a 3-byte hex value encoding the profile, constraint flags, and level. For WebRTC interoperability:

- **Constrained Baseline Profile Level 3.1** → `profile-level-id=42e01f`. This is the mandatory-to-implement profile per RFC 7742 and what Chrome, Firefox, and Safari all support.
- The `42` byte means Baseline Profile. The `e0` constraint flags mean constraint_set0 + constraint_set1 + constraint_set2 are all set, indicating Constrained Baseline. `1f` = level 3.1 (sufficient for 640×480@30fps at up to ~14 Mbps).

The RKMPI VENC encoder must be configured to produce a Constrained Baseline stream. Specifically, disable CABAC (use CAVLC), disable B-frames, and ensure the SPS NAL encodes `profile_idc=66`, `constraint_set0_flag=1`, `constraint_set1_flag=1`. If the hardware encoder produces Main or High profile bitstreams, browsers will reject the SDP or fail to decode.

### Packetization Mode

LiveKit's SDP typically offers `packetization-mode=1` (non-interleaved mode, using STAP-A and FU-A NAL unit aggregation). This is the standard for WebRTC. Ensure the H.264 packetizer splits NAL units larger than the MTU (~1200 bytes for WebRTC) into FU-A fragments.

### Level Asymmetry

The SDP parameter `level-asymmetry-allowed=1` is standard in WebRTC offers. This allows the sender to encode at a different level than the receiver can decode, which is fine for a send-only embedded device.

## 5. Bandwidth Adaptation Signaling

WebRTC uses two congestion control mechanisms:

### TWCC (Transport-Wide Congestion Control)

TWCC is the modern sender-side approach, negotiated via the SDP extension `urn:ietf:params:rtp-hdrext:transport-wide-cc-02` and the RTCP feedback type `transport-cc`. The receiver reports per-packet arrival timestamps; the sender runs Google Congestion Control (GCC) to estimate available bandwidth. LiveKit's SFU server participates in this — it relays TWCC feedback from subscribing clients back toward the publisher.

### REMB (Receiver Estimated Maximum Bitrate)

REMB is the older receiver-side mechanism. The LiveKit SFU can also send REMB messages to cap the publisher's send bitrate.

### Implications for a Hardware Encoder

When using a passthrough encoder, the custom `VideoEncoder::SetRates(const RateControlParameters& params)` callback delivers the target bitrate and framerate from libwebrtc's bandwidth estimator. The implementation must translate this into RKMPI VENC API calls:

- `RK_MPI_VENC_SetRcParam()` to adjust the target bitrate on the hardware encoder channel.
- Adjust the GOP interval if the framerate target changes significantly.
- Respond to `OnPacketLossRateUpdate()` — if loss exceeds ~10%, the GCC algorithm will reduce the target bitrate, and the encoder must comply.

On a constrained device, the response latency matters. The RKMPI rate control change takes effect on the next GOP boundary (or next frame in CBR mode). With a 1-second GOP at 15 fps, worst-case adaptation delay is ~1 second.

For a **PLI (Picture Loss Indication)** or **FIR (Full Intra Request)** RTCP message, the passthrough encoder must immediately signal the RKMPI VENC to force an IDR frame. This is done via `RK_MPI_VENC_RequestIDR()` on the VENC channel.

## 6. Constrained Single-Core ARM Considerations

### CPU Budget

On the RV1106's single Cortex-A7 at 1.0 GHz, the CPU budget is tight. The RKISP driver, NPU inference scheduler, RKMPI VENC, and the LiveKit SDK's signaling (WebSocket + DTLS + SRTP) all share one core. Key mitigations:

- **Hardware VENC is zero-CPU**: The VPU operates via DMA; the CPU only queues/dequeues buffers through RKMPI ioctls.
- **SRTP encryption**: libwebrtc's SRTP uses AES-128-CM. On ARMv7 without AES-NI, this is software-computed. At 640×480@15fps with ~500 kbps target, SRTP overhead is modest (~2–3% CPU).
- **Tokio runtime**: The LiveKit Rust SDK requires Tokio. On a single core, use `current_thread` runtime (not `multi_thread`) to avoid context-switch overhead.

### Memory

libwebrtc itself allocates significant memory for its internal buffers. Expect ~30–50 MB for the WebRTC stack. With 256 MB total and the NPU runtime, rootfs, and vision pipeline, memory is tight. Use `RK_MPI_SYS_SetMediaBufferDepth()` to limit RKMPI's internal buffer pool.

### Cross-Compilation

The LiveKit Rust SDK requires cross-compiling libwebrtc for `armv7-linux-gnueabihf` (or the Buildroot uclibc toolchain). The `webrtc-sys-build` crate manages this, but the Luckfox Pico SDK's uclibc toolchain may require patches. JetKVM's rv1106-system repository demonstrates a working cross-compilation configuration for the RV1106 with the Rockchip ARM toolchain.

## 7. Recommended Architecture

```
┌──────────────────────────────────────────────────┐
│ RV1106 Vision Daemon (Rust)                      │
│                                                  │
│  SC3336 ──► RKISP ──► NV12 buffer                │
│                │                                 │
│                ├──► NPU (YOLOv8n inference)       │
│                │                                 │
│                └──► RKMPI VENC (H.264 HW enc)     │
│                         │                        │
│                    Annex B NALs                   │
│                         │                        │
│                  ┌──────▼──────┐                  │
│                  │ Passthrough │                  │
│                  │  Encoder    │◄── SetRates()    │
│                  │ (custom     │◄── RequestIDR()  │
│                  │  libwebrtc) │                  │
│                  └──────┬──────┘                  │
│                         │                        │
│                    EncodedImage                    │
│                         │                        │
│                  libwebrtc RTP                     │
│                  packetizer + SRTP                 │
│                         │                        │
│              LiveKit signaling (WSS)              │
│                         │                        │
│              Tailscale WireGuard tunnel            │
└─────────────────────┬────────────────────────────┘
                      │
               LiveKit SFU Server
                      │
               Native App (subscriber)
```

## 8. Key Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| libwebrtc ARM cross-compile fails with uclibc | Blocks integration | Use musl or glibc via Buildroot; reference JetKVM's toolchain config |
| SPS/PPS missing on IDR after first frame | Black screen on viewer join/reconnect | Cache SPS/PPS from first VENC output; prepend to every IDR |
| Browser rejects non-CBP profile-level-id | No video renders | Configure VENC for Baseline profile; set SPS `profile_idc=66` with constraint flags |
| Bandwidth adaptation lag causes buffer bloat | High latency or frame drops | Use CBR rate control on VENC; respond to `SetRates()` immediately |
| libwebrtc memory exceeds budget | OOM kill | Limit RKMPI buffer depth; disable simulcast; use single-layer encoding |

## 9. Reference Implementations

- **JetKVM** (`github.com/jetkvm/kvm`): Production RV1106G3 device streaming H.264 via WebRTC using Go/Pion. Demonstrates RKMPI VENC → RTP packetization on the same SoC.
- **Webrtc-H264Capturer** (`github.com/nicotyze/Webrtc-H264Capturer`): Demonstrates the passthrough encoder pattern for feeding external H.264 into libwebrtc's native C++ API.
- **NVIDIA Jetson WebRTC** (`NvPassThroughEncoder`): Documents the same passthrough encoder concept in NVIDIA's libwebrtc fork, validating the approach for hardware-encoded streams.
- **LiveKit Rust SDK** (`github.com/livekit/rust-sdks`): The upstream SDK. Issues #503 and #92 document the current lack of hardware encoder and screen-capture APIs.
