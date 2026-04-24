# ADR-008: PCB design entirely in Python (circuit-synth schematic + pcbnew layout)

## Status

Accepted

## Context

The catlaser AIO board carries the RV1106G3 SiP (BGA, integrated Wi-Fi 6 RF, in-package DDR3L), the RP2350 (TrustZone-M, owns the Class 2 laser and the safety watchdog), five servo headers, an MIPI-CSI camera ribbon, USB-C power with a supercap-backed 5 V rail, two flash devices and a microSD slot. It is the only PCB in the BOM — there is no daughtercard step. Three forces shape how it gets designed:

**The whole design must live in version control as text.** Future Claude sessions, EE consultants, and the FCC SDoC + FDA product report all need to inspect the design; binary `.kicad_sch` and `.kicad_pcb` files defeat git diff. Pin assignments are co-owned with `catlaser-common/src/constants.rs` (RP2350 GPIO map, VBUS divider, hopper sensor wiring) — when constants drift, the PCB has to drift with them, and that is only safe if the design source is reviewable and machine-checkable. Layout-relevant invariants (BGA decoupling pattern, MIPI-CSI 100 Ω length-matching, 50 Ω antenna trace, antenna keep-out, mounting-hole positions matching the enclosure) belong in code for the same reason.

**The dev environment is SSH-only.** The catlaser dev VM has no display server. Any PCB workflow that requires a KiCad GUI process is unworkable — there is no GUI to host. Even Xvfb-wrapped GUIs add fragility (display server lifecycle, IPC socket races) when the alternative is in-process Python bindings that need none of it.

**The board has hard FDA/FCC dependencies.** The Class 2 laser argument requires the constant-current driver to be deterministic across VBUS sag; the FCC SDoC pre-certification of the RV1106G3 Wi-Fi only carries over if the antenna integration follows the SiP vendor's reference layout. Both arguments rest on layout details that must be reproducible from source — a hand-edited `.kicad_pcb` cannot be regenerated when a part needs to change.

The other paths considered:

- **Pure KiCad, hand-drawn schematic + manual layout.** Standard. Defeats both the source-of-truth-in-text requirement and the SSH-only constraint.
- **circuit-synth schematic + manual layout in KiCad GUI.** Resolves text-source for the schematic but leaves layout binary, requires a GUI, and breaks regenerability.
- **kipy (KiCad's IPC bindings) for layout.** Requires a running KiCad process listening on an IPC socket. KiCad 11 will ship `kicad-cli api-server` for true headless operation; the released version of KiCad is 10, which only exposes the API server from the GUI binary. Using kipy on KiCad 10 means launching the GUI under Xvfb — exactly the GUI-process dependency the SSH constraint rules out.
- **SKiDL / atopile / pyhdl-cc.** Same Python-as-schematic shape. circuit-synth is chosen because it emits a complete KiCad project (not just a netlist), supports hierarchical sheets that map cleanly to one-Python-file-per-subsystem, and round-trips manual PCB modifications via `preserve_user_components=True` so additive iteration works without clobbering placement state from earlier runs.

## Decision

**Python is the source of truth for both schematic and PCB layout. The committed `.kicad_pcb` is a deterministic build artifact, not an authored file. Both are committed to git.**

Two Python entry points, both in `hardware/kicad/`:

- **Schematic** lives in `catlaser_pcb/<subsystem>.py`. Each module is a `@circuit`-decorated function (`power`, `mcu_rp2350`, `laser_driver`, `servo_headers`, `hopper_sensor`, `compute_sip`, `compute_storage`, `camera_mipi`, `wifi_rf`). `top.py` assembles them and calls `circuit.generate_kicad_project(project_name="catlaser_aio", placement_algorithm="hierarchical", preserve_user_components=True, force_regenerate=False)` — the schematic is rebuilt and footprints land in the `.kicad_pcb` for the layout pipeline to position.
- **Layout** lives in `catlaser_pcb/layout/<subsystem>.py`. Each module mirrors the schematic peer of the same name and exposes `place(board: BOARD)` operating on the loaded `pcbnew.BOARD` in place. `catlaser_pcb/layout/board.py` owns outline / stackup / mounting holes / origins, `catlaser_pcb/layout/pours.py` owns copper zones and the antenna keep-out, `catlaser_pcb/layout/route.py` owns constrained traces (MIPI-CSI 100 Ω diff pairs, 50 Ω antenna feed, BGA fanout, laser loop) and the Freerouting bridge for everything else. `catlaser_pcb/pcb.py` is the entry: `pcbnew.LoadBoard()` → run pipeline → `pcbnew.SaveBoard()`.

**KiCad's `pcbnew` SWIG bindings are the layout API.** They ship with the `kicad` package at `/usr/lib/python3/dist-packages/{pcbnew.py,_pcbnew.so}`, run in-process, and require no display, no IPC server, and no separate KiCad process. The `pcbnew` module exposes everything the layout pipeline needs: `BOARD`, `FOOTPRINT`, `PCB_TRACK`, `PCB_VIA`, `ZONE`, `LoadBoard` / `SaveBoard`, `ExportSpecctraDSN` / `ImportSpecctraSES` for the Freerouting bridge, `FootprintLoad` for symbol-library footprint resolution. The justfile recipes set `PYTHONPATH=/usr/lib/python3/dist-packages` so the uv venv can import them.

**Routing is two-phase.** Constrained traces (MIPI-CSI, antenna feed, BGA fanout, laser loop) are created as explicit `PCB_TRACK` and `PCB_VIA` items via pcbnew with `track.SetLocked(True)`. Then `pcbnew.ExportSpecctraDSN()` writes a `.dsn` with locked tracks marked as fixed; Freerouting (downloaded jar, pinned via `FREEROUTING_JAR` env var) routes the rest; `pcbnew.ImportSpecctraSES()` merges the routed session back into the live `BOARD`. Per-net-class track widths (power: 0.4 mm, signal: 0.2 mm) are applied as a final pass.

`just kicad-check` runs ruff + pyright over the Python sources and is wired into the top-level `just check`. `just kicad-generate` rebuilds the schematic; `just kicad-layout` applies the layout pipeline; `just kicad-bom`, `just kicad-pdf`, `just kicad-gerbers` produce manufacturing artifacts under `project/output/` (gitignored day-to-day, committed at fab-tag time).

**Locked technical decisions** that the stub files and the `README.md` reflect:

- **Production board includes the bare RV1106G3 SiP.** No Luckfox-Pico-as-daughtercard intermediate step — the spec calls for one PCB, and devboards already exist for firmware iteration.
- **Power.** USB-C 2.0 input (CC1/CC2 5.1 kΩ pull-downs). 10 F / 5.5 V supercap on the **5 V rail** so the brownout sequence in `catlaser-mcu` can complete the "park to home" servo move documented in `crates/catlaser-common/src/constants.rs:417-421`. MCP73871-class charger IC handles inrush limiting on a discharged supercap, charge regulation, and auto-handoff to supercap on USB drop. 3.3 V derived from a downstream LDO/buck.
- **Laser driver.** AMC7135-class constant-current sink, gated by RP2350 GPIO7. Constant current means optical output is independent of VBUS during supercap holdup — the FDA Class 2 dose-per-exposure argument depends on this determinism. Bare MOSFET + series resistor was rejected for this reason.
- **Pin assignments are owned by `catlaser-common/src/constants.rs:372-407`.** The PCB schematic mirrors them; firmware tests treat them as ground truth. Reassigning a pin is a coupled change to both files, reviewed atomically.
- **Connectors.** Servo: JST-XH 2.54 mm 3-pin × 5. Hopper sensor: JST-PH 2 mm 4-pin × 1. USB-C: SMT or mid-mount receptacle, USB 2.0 only.

## Consequences

- Schematic and layout changes show up as Python diffs in code review. Pin-map drift between firmware (`catlaser-common`) and PCB schematic (`catlaser_pcb`) becomes visible at PR time, not at bring-up. Layout-relevant invariants (BGA decoupling, MIPI length-matching, antenna keep-out) live in source.
- The `.kicad_pcb` is regenerable from source. Changing a part, repositioning a connector, or updating the antenna match values is a Python edit followed by `just kicad-layout`, not a manual GUI session.
- The dev workflow runs entirely over SSH. No display, no Xvfb, no IPC socket, no separate KiCad process — just `pcbnew` in-process inside the uv venv.
- The toolchain dependencies are: `uv`, `circuit-synth` (PyPI), `kicad` 10.x system package (provides the `pcbnew` SWIG bindings at `/usr/lib/python3/dist-packages/`), and a downloaded Freerouting jar pointed at by `FREEROUTING_JAR`. `just check` enforces ruff + pyright on the Python sources but does not invoke `kicad-generate` or `kicad-layout` itself — those require the KiCad system package, and CI runners are not provisioned with it. Manufacturing output (`kicad-bom`, `kicad-gerbers`) is a manual fab-tag step, not a CI gate.
- The Python sources start as stubs — `@circuit`-decorated functions and `def place(board: BOARD)` functions with subsystem contracts in docstrings and empty bodies. Filling them in is incremental work, one subsystem per session, gated by the same `just kicad-check` flow.
- The `.kicad_pcb` is committed binary-ish content. Diffs are ugly. The mitigation is that the `.kicad_pcb` is never the place edits originate — it is always the deterministic output of `just kicad-layout`, so diffs are confined to what the layout pipeline actually changed.
- circuit-synth is upstream of the project and not pinned strictly in `pyproject.toml`; `uv.lock` is the authoritative pin. A circuit-synth release that breaks `generate_kicad_project` would block schematic regeneration; the lockfile lets us hold a known-good version while we evaluate.
- The `pcbnew` SWIG bindings are deprecated in KiCad 11 in favour of the `kicad-cli api-server` IPC path. KiCad 11 is over a year out per the KiCad release schedule. When KiCad 11 ships, the layout side migrates from `pcbnew` to `kicad-python` (`kipy`) running against `kicad-cli api-server`; the conceptual model — load a board, mutate footprints/tracks/zones, save — is identical, and the per-subsystem `place` / `apply` / `route` modules are the unit of porting.
- FCC SDoC and FDA product report submissions reference both the Python source (for schematic and layout evidence) and the rendered `.kicad_pdf` + Gerbers (for as-built fab evidence). Both must be tagged together at fab time.
