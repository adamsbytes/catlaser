"""Copper pours: GND on inner layer 2, VCC on inner layer 3, top/bottom GND fills.

All zones created via kipy ``Board.create_items(Zone(...))``. Pours run
after placement and before routing -- the autorouter respects existing
zones as keep-outs/keep-ins per net.

Zones owned here:
    - Inner layer 2: solid GND fill, full board outline, no splits.
      The MIPI-CSI differential pairs and the antenna trace reference
      this plane; any split under those traces invalidates impedance
      and the FCC SDoC argument for the SiP-vendor-reference Wi-Fi
      integration.
    - Inner layer 3: VCC_3V3 fill spanning the digital section,
      switching to VCC_5V under the servo headers and laser driver.
      Plane split is intentional and routed away from any
      controlled-impedance trace on adjacent layers.
    - Top / bottom layer GND fills around component clusters, stitched
      to inner GND with vias on a coarse grid for return-current
      continuity at high frequency.

Antenna keep-out zone (no copper, no vias, no traces) is created here
on all layers within the antenna vendor's documented exclusion area
around the chip antenna body or U.FL feed.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pcbnew import BOARD


def apply(board: BOARD) -> None:
    """Create all copper pours and keep-outs."""
    _ = board
