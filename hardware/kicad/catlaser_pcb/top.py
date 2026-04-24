"""Top-level assembly: instantiates every subsystem, emits KiCad project.

Run via ``just kicad-generate``. The output project lands in
``project/catlaser_aio.*`` and is committed to git -- circuit-synth
preserves manual placement and routing on regen via
``preserve_user_components=True`` and ``force_regenerate=False``.
"""

from __future__ import annotations

import sys
from pathlib import Path

from circuit_synth import circuit

from catlaser_pcb.camera_mipi import camera_mipi
from catlaser_pcb.compute_sip import compute_sip
from catlaser_pcb.compute_storage import compute_storage
from catlaser_pcb.hopper_sensor import hopper_sensor
from catlaser_pcb.laser_driver import laser_driver
from catlaser_pcb.mcu_rp2350 import mcu_rp2350
from catlaser_pcb.power import power
from catlaser_pcb.servo_headers import servo_headers
from catlaser_pcb.wifi_rf import wifi_rf

PROJECT_NAME = "catlaser_aio"
PROJECT_DIR = Path(__file__).resolve().parent.parent / "project"


@circuit(name="CatlaserAIO")
def catlaser_aio() -> None:
    """All-in-one production board, top-level assembly."""
    power()
    mcu_rp2350()
    laser_driver()
    servo_headers()
    hopper_sensor()
    compute_sip()
    compute_storage()
    camera_mipi()
    wifi_rf()


def main() -> int:
    """Generate the KiCad project, preserving any manual layout work."""
    board = catlaser_aio()
    PROJECT_DIR.mkdir(parents=True, exist_ok=True)
    result = board.generate_kicad_project(
        project_name=PROJECT_NAME,
        generate_pcb=True,
        force_regenerate=False,
        placement_algorithm="hierarchical",
        update_source_refs=True,
        preserve_user_components=True,
    )
    if not result.get("success", False):
        sys.stderr.write(f"kicad-generate failed: {result.get('error')}\n")
        return 1
    sys.stdout.write(f"generated: {result.get('project_path')}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
