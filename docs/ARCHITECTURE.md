**Architecture**
- Split-brain: Rust daemon on compute module owns camera/NPU/tracking, Python sidecar handles behavior/app/networking
- Separate RP2350 MCU (Cortex-M33, TrustZone-M) for servo control — safety-isolated via hardware partitioning, never talks to app, never touches network
- Python never touches hardware directly — it receives structured data from Rust over Unix domain socket (protobuf via `buffa`), emits behavior commands back
- Rust on compute module translates behavior commands into servo targets, sends packed 8-byte struct over UART to MCU
- Hierarchy is strict: App → Python → Rust (compute) → Rust (MCU). Each layer only talks to its neighbors

**Compute Module**
- Luckfox Pico Ultra W for dev, custom board for production (same RV1106G3)
- RV1106G3 SiP: Cortex-A7, 1 TOPS NPU, 256MB DDR3L in-package (no external memory traces), WiFi 6

**Storage**
- RP2350: 520KB SRAM on-die, boots from 2MB external QSPI flash
- Compute module: 256MB SPI NAND (8-pin, no BGA) — read-only Buildroot rootfs, ML models, small journaled writable partition for SQLite and config, never stores media
- microSD (ship 2GB, user-expandable) — clip buffer and offline store for session recordings, crops, embeddings
- Clips sync to phone app over the existing data channel whenever connected — phone is the archive
- No eMMC, no cloud storage dependencies — product works indefinitely without vendor servers

**Camera**
- SC3336 3MP module — known compatible, ISP tuning files pre-calibrated, good low-light

**Servos**
- MG90S metal gear micros for pan/tilt
- SG90 micros for treat dispenser (disc, door, deflector — three total)
- All servos use standard mount pattern, JST connectors, plug-in replacement
- Nylon pan/tilt bracket for prototyping, custom enclosure mount for production

**Enclosure**
- Pear-shaped housing: wide stable base (bottom 60%, hopper) narrows to electronics module (top 40%, board/camera/pan-tilt/laser)
- Top and bottom halves join via magnetic connector for power and signal — tool-free separation for refilling and cleaning
- Treat mass in the base keeps center of gravity low — cat bumps won't tip it
- All servo mounts are snap-fit with standard form factor — owner-replaceable, no tools, no glue
- Enclosure is a serviceable chassis, not sealed housing: exploded view published in app and on site

**Treat Dispenser**
- Gravity-fed hopper in the base, treats loaded by lifting off the top module
- Rotary disc at the bottom of the hopper column: a disc with a hole rotates over a fixed plate with a hole. Holes align = one treat drops. Holes misalign = closed. Slight dish (concave) on the disc so crumbs migrate to the edge rather than accumulating at center
- ~1mm clearance between disc and plate with rubber wiper on disc edge — self-clearing, crumb-tolerant
- Hopper interior has a slight cone taper to prevent treat bridging
- Below the disc: staging chute accumulates treats before release
- Chute door is angled top (up-and-inward bevel) — opens by servo pulling up, closes by gravity on release. Fail-closed by physics: power loss, servo death, or external force all result in door shut. No spring needed
- Deflector below the door routes treats left or right — set before the disc cycles
- Dispense sequence: laser off + servos home → position deflector → rotate disc N times (treats fall into staging chute) → open door (treats drop to floor on selected side)
- Variable reward mapped to engagement: 3 rotations (low engagement), 5 (moderate), 7 (high) — Python decides based on session metrics (cat velocity, pounce count, time-on-target). Variable ratio reinforcement produces strongest engagement and slowest extinction
- Alternates left/right chute per session, tracked in SQLite
- IR break-beam sensor at hopper base detects empty state — GPIO readable by both MCU and compute module (read-only shared signal, no UART return channel needed)
- Empty hopper blocks autonomous sessions at Python layer, pushes notification to owner via app
- Disc rests with holes misaligned (closed position) — second independent gravity-closed gate in series with the chute door

**MCU**
- RP2350 (Cortex-M33), TrustZone-M hardware isolation between safety-critical and application firmware
- Secure world (small, synchronous, no Embassy): laser GPIO, watchdog, tilt enforcement, person-detection gating — hardware-inaccessible to application code via SAU and ACCESSCTRL
- Non-Secure world (Embassy async runtime): 200Hz servo interpolation, UART parsing, dispenser control — calls Secure gateway functions to request laser state changes, report sensor data, and feed watchdog
- Dispenser control: drives disc/door/deflector servos on command, fixed-duration pulses, jam detection via servo stall timeout
- Hopper sensor GPIO: MCU reads IR break-beam for status LED, compute module reads same line for session gating
- Watchdog: no message in 500ms → Secure world forces laser off, pan/tilt servos home, dispenser door closed
- Supercap (10F) for 5-8 second clean shutdown on power loss, MCU monitors VBUS

**Vision Pipeline**
- YOLOv5/v8-nano quantized INT8 on NPU, ~15 FPS at 640x480, stock COCO weights for v1
- Detects cats and people in single pass
- Person detection computes safety ceiling at 75% of lowest detected person's bbox height — laser stays below
- SORT tracker (Kalman + Hungarian) for frame-to-frame cat following, runs on CPU, basically free
  - Track states: tentative (new) → confirmed (3+ hits) → coasting (no match, Kalman predicts) → dead (30 frames unmatched)
  - Identity assigned once at confirmation, not per-frame
- Cat re-ID via MobileNetV2 embedding model (128x128 crop, 128-dim vector), runs only on track confirmation — a few times per session, not per frame
  - Average embeddings over 5 frames, cosine-similarity match against stored profiles
  - >0.75 similarity = known cat, below = prompt user to name new cat via app
  - Re-verify identity when a track resumes after coasting to prevent swaps during occlusion
- Log crops and embeddings to microSD for future model improvement

**Behavior**
- Python state machine: lure / chase / tease / cooldown / dispense modes
- Adapts per-cat via parameter tuning (speed, smoothing, pattern randomness), not on-device ML training
- Cooldown leads the cat toward the device (servo home), then transitions to dispense
- Dispense mode: laser off, select chute side (alternates, tracked in SQLite), cycle disc N times, open door. Variable reward — 3/5/7 rotations mapped to session engagement score (cat velocity, pounce count, time-on-target). Variable ratio reinforcement keeps cats engaged across sessions
- `LEAD_TO_POINT` targets two defined positions: left chute and right chute exit, both near device base
- Python owns all patterns — drives them by streaming offsets per-frame, no canned patterns in Rust
- This lets the behavior engine measure engagement per pattern per cat and adapt

**Scheduling**
- Rust owns timing for autonomous play (scheduled sessions, auto-play on cat detection)
- Schedule data lives in Python's SQLite (user-facing state), Python writes a derived schedule file
- Rust reads schedule on boot and on SIGHUP, initiates sessions, sends `SessionRequest` to Python
- Python decides whether to engage — responds with `SessionAck` (accept/skip + reason). Skip reasons: session just ended (cooldown), hopper empty, user-configured quiet hours. Rust does not start a session without an accept
- Preserves hierarchy: for user-initiated commands, App → Python → Rust; for autonomous operation, Rust initiates (it has eyes) and Python decides whether and how to play
- Hopper empty = Python refuses all autonomous sessions and pushes refill notification to app

**IPC: Rust ↔ Python (Unix Domain Socket)**
- Wire format: `[1 byte: msg type][4 bytes: length (LE u32)][N bytes: protobuf]`
- Rust → Python, steady ~15/sec:
  - `DetectionFrame`: timestamp, frame number, list of `TrackedCat` (track_id, cat_id, normalized center/size/velocity, track state), pre-computed safety_ceiling_y, person_in_frame flag, ambient_brightness
  - Each `TrackedCat` has state: TENTATIVE / CONFIRMED / COASTING
  - Normalized coordinates (0-1) so Python never needs camera resolution or FOV
  - `safety_ceiling_y` pre-computed from all person detections — Python doesn't see individual person bboxes
- Rust → Python, sporadic events:
  - `TrackEvent`: new_track, track_lost (with duration_ms for play stats), identity_request (embedding bytes + confidence)
  - `IdentityRequest`: Rust runs embedding model on NPU, sends 128-dim vector; Python compares against catalog in SQLite
  - `SessionRequest`: Rust wants to start a session (scheduled or cat-detected), includes trigger reason
- Python → Rust, sporadic 1-5/sec:
  - `BehaviorCommand`: targeting mode (IDLE / TRACK / LEAD_TO_POINT / DISPENSE), offset from cat center (normalized), smoothing factor, max_speed, laser_on, target_track_id, lead_target coordinates (left or right chute exit), dispense_rotations (3/5/7)
  - `SessionAck`: accept or skip, with reason (cooldown, hopper_empty, quiet_hours) — sent in response to `SessionRequest`
  - `IdentityResult`: resolved cat_id (or empty for new cat) + similarity score, sent in response to IdentityRequest
- What does NOT cross this boundary: raw frames (Rust owns), servo angles (Rust computes), MCU protocol (Python doesn't know MCU exists), dispenser servo timing (Rust/MCU own), cat profiles (Python owns SQLite), network/app state (Python owns)

**UART: Rust (Compute) → MCU (8-byte packed struct)**
- `ServoCommand` in catlaser-common, `#[repr(C, packed)]`, little-endian (native to both ARM cores):
  - `pan: i16` — target angle x100 (e.g. 4523 = 45.23deg), 0.01deg resolution
  - `tilt: i16` — target angle x100, clamped by MCU to HORIZON_LIMIT regardless
  - `smoothing: u8` — 0-255 maps to 0.0-1.0 interpolation factor
  - `max_slew: u8` — 0-255 maps to max deg/sec (0 = use default)
  - `flags: u8` — bit 0: laser on, bit 1: person detected (MCU can tighten limits), bit 2: dispense left, bit 3: dispense right, bits 4-5: dispense tier (0-2 index into MCU rotation table, 3 reserved), bits 6-7: reserved
  - `checksum: u8` — XOR of bytes 0-6, failed check = keep last good command
- No serialization library — both crates import from catlaser-common, layout is compile-time identical

**App ↔ Device API (proto/app.proto)**
- Flat oneof request/response over WebRTC data channel or TCP over Tailscale
- App → Device commands: start_session, stop_session (triggers lead-to-treat cooldown), get_status, get/update/delete cat profiles, get play history (date range), start/stop stream (WebRTC SDP exchange), set_schedule (auto-play times), identify_new_cat (user names unknown cat), run_diagnostic (servo sweep + laser test + camera check + dispenser cycle)
- Device → App events: status_update (doubles as heartbeat, pushed every few seconds — includes hopper_level: ok/low/empty), cat profile list, play history response, stream offer (WebRTC SDP), session_summary (pushed at session end: cats, durations, engagement, treats_dispensed), new_cat_detected (push with thumbnail crop for naming UX), hopper_empty (push notification to refill), diagnostic result, error

**Networking & App**
- Tailscale/WireGuard on device, you broker tunnel creation
- Free tier: full functionality on local network
- Premium ($3-5/mo or ~$35/yr): remote relay for NAT-unfriendly networks
- Live view via WebRTC (LiveKit), H.264/265 from hardware encoder
- Native apps: SwiftUI (iOS, primary) + Jetpack Compose (Android)
- Thin clients — proto contract defines the app, minimal business logic
- Firebase Auth for sign-in with Apple/Google
- Push notifications via APNs (iOS) / FCM (Android) for play summaries and session alerts
