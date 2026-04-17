[X] Contracts (catlaser-common, proto/, SQLite)
  - [X] ServoCommand packed struct + constants (safety limits, pin maps)
  - [X] detection.proto (Rust↔Python IPC messages)
  - [X] app.proto (App↔Device API)
  - [X] buf.yaml + codegen pipeline (Rust + Python)
  - [X] SQLite schema (sessions, cat profiles, embeddings, schedule, chute state)

[X] MCU Firmware (catlaser-mcu)
  - [X] Embassy setup, task spawning, UART receive + command parsing
  - [X] 200Hz servo interpolation loop + PWM output
  - [X] Laser GPIO control
  - [X] Watchdog (500ms timeout → laser off, servos home, dispenser door closed)
  - [X] Beam-dwell monitor (Secure-world PWM compare readback, Class 2 dose cap)
  - [X] Power monitoring (VBUS ADC, supercap shutdown sequence)
  - [X] Dispenser servo control (disc/door/deflector, jam detection via stall timeout)
  - [X] Hopper sensor GPIO read + status LED

[X] Vision Pipeline (catlaser-vision, partial)
  - [X] V4L2/libcamera DMA capture from SC3336
  - [X] RKNN NPU inference wrapper (YOLO INT8, 640x480)
  - [X] Detection post-processing (NMS, bbox extraction)
  - [X] SORT tracker (Kalman filter + Hungarian matching)
  - [X] Track lifecycle (tentative → confirmed → coasting → dead)
  - [X] Person detection → safety ceiling computation

[X] Targeting + Serial (catlaser-vision → catlaser-mcu)
  - [X] Bbox center → servo angle transform (camera FOV, laser offset)
  - [X] Safety ceiling enforcement (clamp tilt above person threshold)
  - [X] ServoCommand packing + UART TX
  - [X] End-to-end: camera sees cat → laser tracks cat

[X] IPC + Cat Identity
  - [X] Unix socket server (Rust) + client (Python)
  - [X] Wire format: [1B type][4B length LE][protobuf]
  - [X] DetectionFrame streaming (Rust → Python, ~15/sec)
  - [X] TrackEvent + SessionRequest (Rust → Python, sporadic)
  - [X] BehaviorCommand + SessionAck + IdentityResult (Python → Rust)
  - [X] Cat re-ID: MobileNetV2 embedding on NPU (Rust side)
  - [X] Embedding comparison + catalog matching (Python side)

[X] Behavior Engine (catlaser_brain)
  - [X] State machine (lure / chase / tease / cooldown / dispense)
  - [X] Engagement tracking (cat velocity, pounce count, time-on-target)
  - [X] Per-cat profile adaptation (speed, smoothing, pattern randomness)
  - [X] Pattern generation (offset streaming per-frame to Rust)
  - [X] Cooldown → lead-to-point (left/right chute exit)
  - [X] Dispense orchestration (variable reward: tier 0-2, chute alternation)
  - [X] Session scheduling (read schedule, accept/skip logic)

[X] Storage + Networking
  - [X] SQLite CRUD (cat profiles, sessions, play history, embeddings, schedule)
  - [X] App API (protobuf over WebRTC data channel / TCP over Tailscale)
  - [X] WebRTC live view (LiveKit, H.264/265 from hardware encoder)
  - [X] Push notifications (FCM/APNs: play summaries, session alerts, hopper empty)

[X] Deploy + CI
  - [X] Cross-compile toolchain (ARM Cortex-A7 for vision, thumbv8m for MCU)
  - [X] ONNX → RKNN model conversion pipeline
  - [X] Rootfs overlay + init scripts (catlaser-vision, catlaser-brain)
  - [X] build-image.sh (full firmware image assembly)
  - [X] flash.sh (USB flash to device)
  - [X] catlaser-update.sh (OTA updates)
  - [X] CI: lint + test (Rust + Python) + release image builds

[ ] App — iOS (SwiftUI, primary)
  - [X] Proto codegen (swift-protobuf from app.proto)
  - [X] Sign in with Apple + Google (AuthenticationServices + GoogleSignIn SDK, ID token exchanged for better-auth bearer)
  - [X] Sign in with email magic link (Universal Links target, device fingerprint payload sent at request time)
  - [ ] Sign in screen
  - [ ] Live view (LiveKit iOS SDK, WebRTC)
  - [ ] History + cat profiles (stats, naming, management)
  - [ ] Schedule setup (auto-play times, quiet hours)
  - [ ] Push notifications (APNs: play summaries, session alerts, hopper empty)

[ ] App — Android (Jetpack Compose, port)
  - [ ] Proto codegen (protobuf-kotlin from app.proto)
  - [ ] Sign in with Google (Credential Manager, ID token exchanged for better-auth bearer)
  - [ ] Sign in with email magic link (App Links target, device fingerprint payload sent at request time)
  - [ ] Port all screens from iOS (same flows, Compose equivalents)
  - [ ] Push notifications (FCM)
