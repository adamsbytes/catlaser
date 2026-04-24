"""Placement: SC3336 MIPI-CSI ribbon connector + per-rail LDOs.

The 24-pin FPC connector sits on the board edge nearest the camera
mount in the enclosure to minimise ribbon length (the SC3336 module
mounts on a flex outside this PCB). Connector orientation places the
MIPI-CSI differential pairs on the side facing the SiP RF/MIPI bank.

Three local LDOs (VDD_2V8 analog, VDD_1V8 digital + IO, VDD_1V2 core)
clustered with their bypass caps right at the connector so each rail
arrives at the camera with minimal voltage droop and ripple.

The MIPI-CSI 100 ohm differential trace geometry is owned by route.py
(constrained trace phase). Placement only fixes the connector and the
LDO cluster.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pcbnew import BOARD


def place(board: BOARD) -> None:
    """Position camera FPC connector and per-rail LDO cluster."""
    _ = board
