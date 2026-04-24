"""JLCPCB CPL (Component Placement List) generator.

KiCad's ``pcb export pos`` produces CSV with columns
``Ref,Val,Package,PosX,PosY,Rot,Side``. JLCPCB's intake wants
``Designator,Mid X,Mid Y,Layer,Rotation``. Same data, different headers
(plus column reduction). This script runs the export and rewrites the
header row in place; data rows pass through unchanged.

Layer naming: KiCad emits ``top``/``bottom``; JLCPCB accepts ``Top``
or ``T``, ``Bottom`` or ``B``. We normalise to ``Top``/``Bottom``
matching JLCPCB's documentation example.
"""

from __future__ import annotations

import csv
import subprocess
import sys
from pathlib import Path

from catlaser_pcb._cli import kicad_cli_path

PROJECT_DIR = Path(__file__).resolve().parents[2] / "project"
PCB_PATH = PROJECT_DIR / "catlaser_aio.kicad_pcb"
OUTPUT_DIR = PROJECT_DIR / "output"
RAW_PATH = OUTPUT_DIR / "catlaser_aio-pos.csv"
OUTPUT_PATH = OUTPUT_DIR / "catlaser_aio-cpl-jlcpcb.csv"

KICAD_TO_JLCPCB_HEADERS: dict[str, str] = {
    "Ref": "Designator",
    "PosX": "Mid X",
    "PosY": "Mid Y",
    "Side": "Layer",
    "Rot": "Rotation",
}
JLCPCB_COLUMN_ORDER: tuple[str, ...] = ("Designator", "Mid X", "Mid Y", "Layer", "Rotation")
LAYER_NORMALISATION: dict[str, str] = {"top": "Top", "bottom": "Bottom"}


def main() -> int:
    """Emit a JLCPCB-format CPL CSV."""
    if not PCB_PATH.exists():
        sys.stderr.write(f"missing {PCB_PATH}; run `just kicad-layout` first\n")
        return 1
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(  # noqa: S603 -- static args, no shell, no user input
        [
            kicad_cli_path(),
            "pcb",
            "export",
            "pos",
            "--output",
            str(RAW_PATH),
            "--side",
            "both",
            "--format",
            "csv",
            "--units",
            "mm",
            "--use-drill-file-origin",
            "--exclude-dnp",
            str(PCB_PATH),
        ],
        check=False,
    )
    if result.returncode != 0:
        sys.stderr.write(f"kicad-cli pcb export pos failed (exit {result.returncode})\n")
        return result.returncode
    _transform(RAW_PATH, OUTPUT_PATH)
    sys.stdout.write(f"CPL written: {OUTPUT_PATH}\n")
    return 0


def _transform(src: Path, dst: Path) -> None:
    """Rename headers and re-order columns to JLCPCB's intake spec."""
    with src.open(newline="", encoding="utf-8") as fp_in:
        reader = csv.DictReader(fp_in)
        rows: list[dict[str, str]] = []
        for raw_row in reader:
            renamed = {KICAD_TO_JLCPCB_HEADERS.get(k, k): v for k, v in raw_row.items()}
            renamed["Layer"] = LAYER_NORMALISATION.get(renamed["Layer"], renamed["Layer"])
            rows.append({col: renamed[col] for col in JLCPCB_COLUMN_ORDER})
    with dst.open("w", newline="", encoding="utf-8") as fp_out:
        writer = csv.DictWriter(fp_out, fieldnames=list(JLCPCB_COLUMN_ORDER))
        writer.writeheader()
        writer.writerows(rows)


if __name__ == "__main__":
    sys.exit(main())
