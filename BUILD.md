[X] Contracts (catlaser-common, proto/, SQLite)
  - [X] ServoCommand packed struct + constants (safety limits, pin maps)
  - [X] detection.proto (Rust↔Python IPC messages)
  - [X] app.proto (App↔Device API)
  - [X] buf.yaml + codegen pipeline (Rust + Python)
  - [X] SQLite schema (sessions, cat profiles, embeddings, schedule, chute state)

[ ] MCU Firmware (catlaser-mcu)
  - [ ] Embassy setup, task spawning, UART receive + command parsing
  - [ ] 200Hz servo interpolation loop + PWM output
  - [ ] Laser GPIO control
  - [ ] Watchdog (500ms timeout → laser off, servos home, dispenser door closed)
  - [ ] Tilt clamp (hardware horizon limit enforcement)
  - [ ] Power monitoring (VBUS ADC, supercap shutdown sequence)
  - [ ] Dispenser servo control (disc/door/deflector, jam detection via stall timeout)
  - [ ] Hopper sensor GPIO read + status LED

[ ] Vision Pipeline (catlaser-vision, partial)
  - [ ] V4L2/libcamera DMA capture from SC3336
  - [ ] RKNN NPU inference wrapper (YOLO INT8, 640x480)
  - [ ] Detection post-processing (NMS, bbox extraction)
  - [ ] SORT tracker (Kalman filter + Hungarian matching)
  - [ ] Track lifecycle (tentative → confirmed → coasting → dead)
  - [ ] Person detection → safety ceiling computation

[ ] Targeting + Serial (catlaser-vision → catlaser-mcu)
  - [ ] Bbox center → servo angle transform (camera FOV, laser offset)
  - [ ] Safety ceiling enforcement (clamp tilt above person threshold)
  - [ ] ServoCommand packing + UART TX
  - [ ] End-to-end: camera sees cat → laser tracks cat

[ ] IPC + Cat Identity
  - [ ] Unix socket server (Rust) + client (Python)
  - [ ] Wire format: [1B type][4B length LE][protobuf]
  - [ ] DetectionFrame streaming (Rust → Python, ~15/sec)
  - [ ] TrackEvent + SessionRequest (Rust → Python, sporadic)
  - [ ] BehaviorCommand + SessionAck + IdentityResult (Python → Rust)
  - [ ] Cat re-ID: MobileNetV2 embedding on NPU (Rust side)
  - [ ] Embedding comparison + catalog matching (Python side)

[ ] Behavior Engine (catlaser_brain)
  - [ ] State machine (lure / chase / tease / cooldown / dispense)
  - [ ] Engagement tracking (cat velocity, pounce count, time-on-target)
  - [ ] Per-cat profile adaptation (speed, smoothing, pattern randomness)
  - [ ] Pattern generation (offset streaming per-frame to Rust)
  - [ ] Cooldown → lead-to-point (left/right chute exit)
  - [ ] Dispense orchestration (variable reward: tier 0-2, chute alternation)
  - [ ] Session scheduling (read schedule, accept/skip logic)

[ ] Storage + Networking
  - [ ] SQLite CRUD (cat profiles, sessions, play history, embeddings, schedule)
  - [ ] App API (protobuf over WebRTC data channel / TCP over Tailscale)
  - [ ] WebRTC live view (LiveKit, H.264/265 from hardware encoder)
  - [ ] Push notifications (FCM/APNs: play summaries, session alerts, hopper empty)

[ ] Deploy + CI
  - [ ] Cross-compile toolchain (ARM Cortex-A7 for vision, thumbv6m for MCU)
  - [ ] ONNX → RKNN model conversion pipeline
  - [ ] Rootfs overlay + systemd services (catlaser-vision, catlaser-brain)
  - [ ] build-image.sh (full firmware image assembly)
  - [ ] flash.sh (USB flash to device)
  - [ ] catlaser-update.sh (OTA updates)
  - [ ] CI: lint + test (Rust + Python) + release image builds

[ ] App — iOS (SwiftUI, primary)
  - [ ] Proto codegen (swift-protobuf from app.proto)
  - [ ] Firebase Auth (sign-in with Apple/Google)
  - [ ] Sign in screen
  - [ ] Live view (LiveKit iOS SDK, WebRTC)
  - [ ] History + cat profiles (stats, naming, management)
  - [ ] Schedule setup (auto-play times, quiet hours)
  - [ ] Push notifications (APNs: play summaries, session alerts, hopper empty)

[ ] App — Android (Jetpack Compose, port)
  - [ ] Proto codegen (protobuf-kotlin from app.proto)
  - [ ] Firebase Auth (sign-in with Google)
  - [ ] Port all screens from iOS (same flows, Compose equivalents)
  - [ ] Push notifications (FCM)
