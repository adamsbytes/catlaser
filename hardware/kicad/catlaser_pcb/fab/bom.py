"""JLCPCB BOM generator.

Wraps ``kicad-cli sch export bom`` with the column layout, grouping,
and reference formatting JLCPCB's assembly intake expects.

Each ``Component`` in the schematic is expected to carry an ``LCSC``
custom field with the LCSC part number (or empty for do-not-fit
parts). The schematic's ``Reference`` and ``Value`` fields supply the
designator and comment columns; the assigned ``Footprint`` supplies
the footprint column.

JLCPCB columns (current intake spec):
    Comment, Designator, Footprint, LCSC Part #
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from catlaser_pcb._cli import kicad_cli_path

PROJECT_DIR = Path(__file__).resolve().parents[2] / "project"
SCH_PATH = PROJECT_DIR / "catlaser_aio.kicad_sch"
OUTPUT_DIR = PROJECT_DIR / "output"
OUTPUT_PATH = OUTPUT_DIR / "catlaser_aio-bom-jlcpcb.csv"


def main() -> int:
    """Emit a JLCPCB-format BOM CSV."""
    if not SCH_PATH.exists():
        sys.stderr.write(f"missing {SCH_PATH}; run `just kicad-generate` first\n")
        return 1
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(  # noqa: S603 -- args are static, no shell, no user input
        [
            kicad_cli_path(),
            "sch",
            "export",
            "bom",
            "--output",
            str(OUTPUT_PATH),
            "--fields",
            "Value,Reference,Footprint,LCSC",
            "--labels",
            "Comment,Designator,Footprint,LCSC Part #",
            "--group-by",
            "Value,Footprint,LCSC",
            "--ref-delimiter",
            ",",
            "--ref-range-delimiter",
            "",
            "--exclude-dnp",
            str(SCH_PATH),
        ],
        check=False,
    )
    if result.returncode != 0:
        sys.stderr.write(f"kicad-cli sch export bom failed (exit {result.returncode})\n")
        return result.returncode
    sys.stdout.write(f"BOM written: {OUTPUT_PATH}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
