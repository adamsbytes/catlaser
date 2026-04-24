# Catlaser PCB

All-in-one production board for the catlaser. RV1106G3 SiP (vision/network/Wi-Fi), RP2350 (servo control + TrustZone-M safety), Class 2 laser driver, treat-dispenser servo headers, IR break-beam input, USB-C power with supercap-backed 5 V rail. Single PCB, no daughtercard.

## Source of truth

| Artifact | Source of truth | Generated from |
|----------|----------------|----------------|
| Schematic netlist (`*.kicad_sch`) | Python (`catlaser_pcb/*.py`) | `just kicad-generate` |
| PCB layout (`*.kicad_pcb`) | Python (`catlaser_pcb/layout/*.py`) | `just kicad-layout` |
| Project file (`*.kicad_pro`) | Generated | `just kicad-generate` |
| BOM (`*.csv`) | Python + JLCPCB part numbers | `just kicad-bom` |
| Schematic PDF | Generated for review | `just kicad-pdf` |
| Gerbers / drill files | Generated for fab | `just kicad-gerbers` |

Schematic and layout are both Python. The schematic side runs `circuit-synth` to emit the KiCad project. The layout side runs in-process against KiCad's `pcbnew` SWIG bindings — `LoadBoard()`, set footprint positions, create tracks/zones, `ExportSpecctraDSN()` / `ImportSpecctraSES()` for the Freerouting bridge, `SaveBoard()`. No IPC server, no display, no GUI process.

The committed `.kicad_pcb` is the deterministic output of `just kicad-layout` — open it in KiCad to inspect, but never edit by hand. Hand edits are clobbered on the next layout run.

Generated PDFs, BOM CSVs, and Gerbers are checked into git only when a revision is tagged for fab; day-to-day they live under `project/output/` (gitignored).

## Layout

```
hardware/kicad/
├── README.md                       # this file
├── pyproject.toml                  # uv-managed, ruff + pyright strict
├── catlaser_pcb/                   # Python package
│   ├── __init__.py
│   ├── top.py                      # schematic entry: assembles sheets, emits KiCad project
│   ├── pcb.py                      # layout entry: load .kicad_pcb, run pipeline, save
│   ├── power.py                    # schematic: USB-C, supercap, 3.3 V LDO
│   ├── mcu_rp2350.py               # schematic: RP2350 + boot flash + SWD
│   ├── laser_driver.py             # schematic: AMC7135 constant-current sink
│   ├── servo_headers.py            # schematic: 5x JST-XH 3-pin
│   ├── hopper_sensor.py            # schematic: IR break-beam, dual-reader
│   ├── compute_sip.py              # schematic: RV1106G3 BGA + decoupling + sequencing
│   ├── compute_storage.py          # schematic: SPI NAND + QSPI flash + microSD
│   ├── camera_mipi.py              # schematic: SC3336 MIPI-CSI ribbon connector
│   ├── wifi_rf.py                  # schematic: chip antenna or U.FL + π-network
│   └── layout/                     # layout: peer-modules, one per subsystem
│       ├── __init__.py
│       ├── board.py                # outline, stackup, mounting holes, origins
│       ├── pours.py                # GND/VCC zones, antenna keep-out
│       ├── route.py                # constrained traces + Freerouting bridge
│       ├── power.py                # placement: USB-C, charger, supercap, 3v3 LDO
│       ├── mcu_rp2350.py           # placement: RP2350 cluster + decoupling
│       ├── laser_driver.py         # placement: AMC7135 + bypass + laser terminal
│       ├── servo_headers.py        # placement: connector bank + ESD stacks
│       ├── hopper_sensor.py        # placement: connector + pull-up + fanout
│       ├── compute_sip.py          # placement: SiP + decoupling + sequencing
│       ├── compute_storage.py      # placement: flash + NAND + microSD
│       ├── camera_mipi.py          # placement: FPC connector + per-rail LDOs
│       └── wifi_rf.py              # placement: antenna + π-network pads
└── project/                        # generated KiCad project (committed)
    ├── catlaser_aio.kicad_pro
    ├── catlaser_aio.kicad_sch
    ├── catlaser_aio.kicad_pcb
    └── output/                     # gitignored: PDFs, gerbers, BOM
```

## Setup

KiCad 10.x must be installed system-wide. The pcbnew SWIG bindings ship at `/usr/lib/python3/dist-packages/{pcbnew.py,_pcbnew.so}`; the justfile recipes set `PYTHONPATH` so the uv venv finds them. Ubuntu/Debian install path: `apt install kicad`.

Freerouting (Java jar) handles the bulk autorouting phase. Download from the [Freerouting releases](https://github.com/freerouting/freerouting/releases), pin a tested version, and export `FREEROUTING_JAR=/path/to/freerouting-X.Y.Z.jar` so `just kicad-layout` finds it.

```sh
cd hardware/kicad
uv sync          # circuit-synth + lints into .venv
```

## Workflow

1. **Edit a schematic sheet** in `catlaser_pcb/<subsystem>.py`, or a layout module in `catlaser_pcb/layout/<subsystem>.py`.
2. **Regenerate the schematic.** `just kicad-generate` rebuilds `catlaser_aio.kicad_sch` and ensures the `.kicad_pcb` has all current footprints.
3. **Apply the layout.** `just kicad-layout` runs the pipeline (board outline → placement → pours → constrained traces → Freerouting → final widths) and saves the `.kicad_pcb`.
4. **Diff.** `git diff` shows the Python change and the resulting `.kicad_pcb` change atomically.
5. **Check.** `just kicad-check` lints the Python sources (ruff + pyright strict).
6. **Tag for fab.** When the board is ready: `just kicad-bom`, `just kicad-pdf`, `just kicad-gerbers`. Commit the outputs alongside a revision tag.

## Locked design decisions

Flagged here so a casual reader does not have to dig:

- **Power.** USB-C 2.0 input (CC1/CC2 5.1 kΩ pull-downs, USB 2.0 only). 10 F / 5.5 V supercap backs the **5 V rail** so the MCU can complete a "park to home" servo move during brownout. Charger IC (MCP73871-class) handles inrush limiting, charge regulation, and auto-handoff to supercap on USB drop. 3.3 V derived from a downstream LDO/buck.
- **Laser driver.** AMC7135-class constant-current sink, gated by RP2350 GPIO7. Constant current bounds optical output regardless of VBUS sag — the FDA Class 2 argument depends on this being deterministic.
- **MCU.** RP2350 with TrustZone-M. Pin assignments are fixed by [`crates/catlaser-common/src/constants.rs:372-407`](../../crates/catlaser-common/src/constants.rs#L372-L407) and must match the firmware exactly.
- **Compute SiP.** RV1106G3 (Cortex-A7 + 1 TOPS NPU, in-package 256 MB DDR3L, on-die Wi-Fi 6). No external DDR traces.
- **Storage.** 256 MB SPI NAND (8-pin SOIC, no BGA), 2 MB QSPI boot flash, microSD slot.
- **Camera.** SC3336 module on a MIPI-CSI ribbon — connector on board, sensor module mounts in the enclosure.
- **Connectors.** Servo: JST-XH 2.54 mm 3-pin. Hopper sensor: JST-PH 2 mm. USB-C: standard mid-mount or SMT receptacle, USB 2.0 only.

See [docs/decisions/008-pcb-design-via-circuit-synth.md](../../docs/decisions/008-pcb-design-via-circuit-synth.md) for rationale.

## Status

Stubs. Every `catlaser_pcb/*.py` and `catlaser_pcb/layout/*.py` file is a skeleton: subsystem contract in the docstring, a `pass`-bodied function. Filling them in is incremental work, one subsystem per session.
