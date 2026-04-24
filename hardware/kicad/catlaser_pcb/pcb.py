"""Layout pipeline entry: load .kicad_pcb, apply layout, save, DRC.

Run via ``just kicad-layout``. Uses KiCad's in-process ``pcbnew`` SWIG
bindings -- no IPC, no display, no daemon. The KiCad 10 install ships
``pcbnew.py`` and ``_pcbnew.so`` under ``/usr/lib/python3/dist-packages``
so the justfile recipe sets ``PYTHONPATH`` to make them importable
inside the uv venv.

Pipeline order:
    1. ``layout.design_rules.apply`` -- global track / clearance / via
       minima written into BOARD_DESIGN_SETTINGS
    2. ``layout.board.configure``    -- outline, stackup, mounting holes
    3. per-subsystem ``place``       -- footprint positions
    4. ``layout.pours.apply``        -- copper zones, antenna keep-out
    5. ``layout.route.route``        -- constrained traces, then
       Freerouting via ``pcbnew.ExportSpecctraDSN`` /
       ``pcbnew.ImportSpecctraSES``
    6. ``pcbnew.SaveBoard``          -- persist the result
    7. ``kicad-cli pcb drc``         -- fail loud on errors

Each phase mutates the loaded ``BOARD`` in place. DRC runs out of
process via ``kicad-cli`` so its parser sees the saved file exactly as
fab and CI will see it.
"""

from __future__ import annotations

import subprocess
import sys

import pcbnew

from catlaser_pcb._cli import kicad_cli_path
from catlaser_pcb.layout import (
    board,
    camera_mipi,
    compute_sip,
    compute_storage,
    design_rules,
    hopper_sensor,
    laser_driver,
    mcu_rp2350,
    pours,
    power,
    route,
    servo_headers,
    wifi_rf,
)
from catlaser_pcb.top import PROJECT_DIR, PROJECT_NAME

PCB_PATH = PROJECT_DIR / f"{PROJECT_NAME}.kicad_pcb"
DRC_REPORT_PATH = PROJECT_DIR / "output" / "drc-report.txt"


def main() -> int:
    """Apply the layout pipeline to the existing .kicad_pcb, then DRC."""
    if not PCB_PATH.exists():
        sys.stderr.write(f"missing {PCB_PATH}; run `just kicad-generate` first\n")
        return 1
    active = pcbnew.LoadBoard(str(PCB_PATH))
    design_rules.apply(active)
    board.configure(active)
    power.place(active)
    mcu_rp2350.place(active)
    laser_driver.place(active)
    servo_headers.place(active)
    hopper_sensor.place(active)
    compute_sip.place(active)
    compute_storage.place(active)
    camera_mipi.place(active)
    wifi_rf.place(active)
    pours.apply(active)
    route.route(active)
    pcbnew.SaveBoard(str(PCB_PATH), active)
    sys.stdout.write(f"layout applied: {PCB_PATH}\n")
    return _run_drc()


def _run_drc() -> int:
    """Run kicad-cli DRC against the saved board; return its exit code."""
    DRC_REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(  # noqa: S603 -- args are static, no shell, no user input
        [
            kicad_cli_path(),
            "pcb",
            "drc",
            "--output",
            str(DRC_REPORT_PATH),
            "--severity-error",
            "--severity-warning",
            "--exit-code-violations",
            "--refill-zones",
            str(PCB_PATH),
        ],
        check=False,
    )
    if result.returncode != 0:
        sys.stderr.write(
            f"DRC reported violations (exit {result.returncode}); see {DRC_REPORT_PATH}\n",
        )
    else:
        sys.stdout.write(f"DRC clean: {DRC_REPORT_PATH}\n")
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
