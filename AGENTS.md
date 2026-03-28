# Catlaser

Automated cat laser toy with vision-guided tracking, treat dispensing, and per-cat behavior adaptation. Split-brain: Linux compute module (RV1106G3) handles vision/behavior/networking, bare-metal RP2040 handles servo control and safety.

## Conventions

Run `just check` after all changes. See `justfile` for all targets. `just` commands should always be used - if one is missing, add it.

Review the `rust` skill which has critical information that will allow your work to succeed.

## Design Docs

| Document | Covers |
|----------|--------|
| `docs/BRIEF.md` | Complete product spec: vision pipeline, tracking, behavior engine, hardware, safety, networking, app, compliance, BOM, manufacturing |
| `docs/ARCHITECTURE.md` | System architecture: compute/MCU split, storage topology, IPC wire format, UART protocol, app API, dispenser mechanics, servo/sensor details |
| `docs/BUILD.md` | Task breakdown by subsystem |
| `docs/decisions/NNN-title.md` | Architecture Decision Records — one per non-obvious structural choice or spec deviation |
| `docs/resources/*.md` | Hardware/SDK reference material per subsystem (embassy-rp, rknn, v4l2, buffa, rockchip-mpp) |

## Architectural Invariants

These are hard constraints. Violating any of them breaks the project.

- **MCU is the safety layer.** The RP2040 enforces mechanical tilt limits, watchdog timeout, and power-loss laser kill regardless of compute module state. No software update to the compute module can bypass MCU protections.
- **Strict layer hierarchy.** App → Python → Rust (compute) → Rust (MCU). Each layer only talks to its neighbors. Python never touches hardware. The MCU never touches the network.
- **Python never sees raw hardware.** Python receives normalized coordinates (0.0-1.0) and pre-computed safety ceilings. It never knows camera resolution, FOV, servo angles, or that the MCU exists.
- **Safety ceiling is pre-computed.** Rust computes `safety_ceiling_y` from all person detections and sends a single float. Python never sees individual person bounding boxes.
- **Fail-safe on every layer.** Watchdog (MCU, 500ms) → laser off + servos home. Power loss (MCU, VBUS) → laser off within 100ms. Compute crash → watchdog fires. Any single layer failing keeps the product safe.
- **Deterministic wire formats.** `ServoCommand` is `#[repr(C, packed)]` imported from `catlaser-common`. IPC is length-prefixed protobuf. No serialization library on the UART path.

## Rust Conventions

- Workspace dependency inheritance via `[workspace.dependencies]` in root `Cargo.toml`
- `thiserror` for all error types
- `catlaser-common` owns all shared types — `ServoCommand`, constants, safety limits. `no_std` compatible
- `catlaser-mcu` is `no_std` (Embassy, bare-metal RP2040). `catlaser-vision` is `std` (Linux daemon)
- Lint policy defined in `[workspace.lints]` in root `Cargo.toml` — every member crate must have `[lints] workspace = true`
- Linting should NEVER be ignored without a fundamental requirement to do so, it is strict intentionally
- `tracing` for observability in `catlaser-vision`, not `log`
- `pub` is the exception. Start private, `pub(crate)` for intra-crate, `pub` only when another crate needs it
- Architecture decisions in `docs/decisions/NNN-title.md` when deviating from spec or making non-obvious structural choices

## Python Conventions

- `uv` for dependency management, `ruff` for linting + formatting, `pyright` strict for type checking
- Ruff `select = ["ALL"]` with targeted ignores — see `pyproject.toml`
- `from __future__ import annotations` required in every file (enforced by ruff isort)
- Google-style docstrings
- Generated proto code exempt from all linting (`**/proto/**`)

## Testing

- `proptest` for `ServoCommand` round-trips, safety limit enforcement, coordinate normalization
- `insta` snapshot tests for protobuf serialization
- Integration tests for IPC message flow (Rust ↔ Python)
- Python tests against real SQLite, no mocks

## Repo Structure

```
catlaser/
├── Cargo.toml                        # [workspace] — common, vision, mcu
├── Cargo.lock
│
├── proto/catlaser/
│   ├── detection/v1/
│   │   └── detection.proto           # Rust↔Python IPC: DetectionFrame,
│   │                                 # TrackEvent, BehaviorCommand, etc.
│   └── app/v1/
│       └── app.proto                 # App↔Device API: AppRequest/DeviceEvent
│                                     # oneof envelopes over WebRTC/TCP
│
├── crates/
│   ├── catlaser-common/              # Shared types between vision and MCU.
│   │                                 # ServoCommand (repr C packed), constants,
│   │                                 # safety limits, pin assignments. no_std.
│   │                                 # Changes here affect both targets.
│   │
│   ├── catlaser-vision/              # Rust daemon on compute module (std).
│   │   └── src/
│   │       ├── main.rs               # Entry, spawns camera + socket server
│   │       ├── camera.rs             # V4L2/libcamera DMA capture from SC3336
│   │       ├── npu.rs                # RKNN FFI wrapper (YOLO + MobileNetV2)
│   │       ├── tracker.rs            # SORT: Kalman + Hungarian matching
│   │       ├── targeting.rs          # Bbox → servo angles, safety ceiling
│   │       ├── serial.rs             # UART TX to MCU (ServoCommand packing)
│   │       └── ipc.rs               # Unix socket, protobuf via buffa
│   │
│   └── catlaser-mcu/                 # RP2040 firmware (Embassy, no_std).
│       ├── memory.x                  # Linker script
│       └── src/
│           ├── main.rs               # Embassy entry, task spawning
│           ├── control.rs            # 200Hz servo interpolation loop
│           ├── uart.rs               # UART RX, command parsing + checksum
│           ├── safety.rs             # Watchdog, tilt clamp, VBUS power monitor
│           └── pwm.rs               # Servo PWM + laser GPIO drivers
│
├── python/
│   ├── pyproject.toml                # uv-managed, ruff + pyright config
│   └── catlaser_brain/
│       ├── behavior/                 # State machine (lure/chase/tease/cooldown/
│       │                             # dispense), engagement, per-cat profiles,
│       │                             # pattern generation
│       ├── identity/                 # Embedding comparison, catalog CRUD
│       ├── network/                  # App API (proto over WebRTC/TCP),
│       │                             # LiveKit streaming, FCM/APNs push
│       └── storage/                  # SQLite: sessions, profiles, embeddings,
│                                     # schedule, chute alternation state
│
├── models/
│   ├── yolov8n-coco.onnx            # Detection model (git-lfs)
│   ├── cat_reid_mobilenet.onnx      # Re-ID embedding model
│   └── convert/                     # ONNX → RKNN quantized conversion
│
├── deploy/
│   ├── rootfs/                      # Buildroot overlay, systemd services
│   ├── build-image.sh               # Full firmware image assembly
│   └── flash.sh                     # USB flash to device
│
├── hardware/
│   ├── kicad/                       # PCB design (custom RV1106G3 board)
│   ├── enclosure/                   # 3D print STEP/3MF files
│   └── bom.csv                      # Production BOM
│
├── app/
│   ├── ios/                         # SwiftUI — thin client against app.proto
│   └── android/                     # Jetpack Compose — port of iOS
│
└── docs/                            # design docs, resources, ADRs
    ├── decisions/                   # Architecture Decision Records.
    │                                # NNN-title.md per decision.
    └── resources/                   # Hardware/SDK reference per subsystem
```
