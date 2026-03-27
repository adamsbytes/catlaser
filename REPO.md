catlaser/
├── README.md
├── .github/
│   └── workflows/
│       ├── ci.yml                    # lint + test both rust + python
│       └── release.yml               # build firmware images
│
├── proto/
│   ├── detection.proto               # rust↔python IPC messages
│   ├── app.proto                     # app↔device API
│   └── buf.yaml                      # buf config for codegen
│
├── crates/
│   ├── catlaser-vision/                # rust daemon on compute module
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── main.rs               # entry, spawns camera + socket server
│   │       ├── camera.rs             # V4L2/libcamera DMA capture
│   │       ├── npu.rs                # RKNN inference wrapper (FFI to librknn)
│   │       ├── tracker.rs            # SORT implementation, kalman + hungarian
│   │       ├── targeting.rs          # bbox → servo angle math, safety ceiling
│   │       ├── serial.rs             # UART to MCU, packed struct protocol
│   │       └── ipc.rs               # unix socket server, protobuf via buffa
│   │
│   ├── catlaser-mcu/                   # RP2040 firmware (embassy, no_std)
│   │   ├── Cargo.toml
│   │   ├── .cargo/config.toml        # target = thumbv6m-none-eabi
│   │   ├── memory.x                  # linker script
│   │   └── src/
│   │       ├── main.rs               # embassy entry, spawns tasks
│   │       ├── control.rs            # 200Hz servo interpolation loop
│   │       ├── uart.rs               # receive commands from compute module
│   │       ├── safety.rs             # watchdog, tilt clamp, power monitor
│   │       └── pwm.rs               # servo + laser GPIO drivers
│   │
│   └── catlaser-common/                # shared types between crates
│       ├── Cargo.toml
│       └── src/
│           ├── lib.rs
│           ├── servo_cmd.rs          # packed struct definition (repr C)
│           └── constants.rs          # safety limits, pin assignments, etc.
│
├── python/
│   ├── pyproject.toml                # uv-managed, [project] with deps
│   ├── uv.lock
│   └── catlaser_brain/
│       ├── __init__.py
│       ├── main.py                   # entry, connects to rust unix socket
│       ├── behavior/
│       │   ├── __init__.py
│       │   ├── engine.py             # state machine: lure/chase/tease/cooldown
│       │   ├── engagement.py         # tracks cat responsiveness metrics
│       │   └── profiles.py           # per-cat parameter storage + adaptation
│       ├── identity/
│       │   ├── __init__.py
│       │   ├── embeddings.py         # embedding model inference + comparison
│       │   └── catalog.py            # cat profile CRUD, naming, persistence
│       ├── network/
│       │   ├── __init__.py
│       │   ├── api.py                # app-facing API (websocket or HTTP)
│       │   ├── streaming.py          # WebRTC live view orchestration
│       │   └── notifications.py      # FCM/APNs push for play summaries
│       └── storage/
│           ├── __init__.py
│           └── db.py                 # sqlite for sessions, profiles, embeddings
│
├── app/
│   ├── ios/                           # SwiftUI app (primary, ships first)
│   └── android/                       # Jetpack Compose app (port)
│
├── models/
│   ├── yolov8n-coco.onnx            # detection model (git-lfs or .gitignore)
│   ├── cat_reid_mobilenet.onnx       # re-ID embedding model
│   └── convert/
│       ├── to_rknn.py                # ONNX → RKNN quantized conversion script
│       └── requirements.txt          # rknn-toolkit2 deps (separate from main python)
│
├── deploy/
│   ├── rootfs/                       # overlay files for buildroot/ubuntu image
│   │   ├── etc/
│   │   │   └── systemd/system/
│   │   │       ├── catlaser-vision.service    # rust daemon
│   │   │       └── catlaser-brain.service     # python daemon
│   │   └── usr/local/bin/
│   │       └── catlaser-update.sh      # OTA update script
│   ├── build-image.sh                # assemble full firmware image
│   └── flash.sh                      # flash to device over USB
│
├── hardware/
│   ├── kicad/                        # PCB design (v2 custom board)
│   │   ├── catlaser.kicad_pro
│   │   ├── catlaser.kicad_sch
│   │   └── catlaser.kicad_pcb
│   ├── enclosure/                    # 3D print files
│   │   ├── body.step
│   │   ├── body.3mf
│   │   └── pan_tilt_mount.step
│   └── bom.csv                       # production BOM
│
├── Cargo.toml                        # workspace root
├── Justfile                          # task runner (or Makefile)
└── .envrc                            # direnv for tool versions
