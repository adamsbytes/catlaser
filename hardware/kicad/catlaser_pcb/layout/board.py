"""Board-level layout: outline, layer stackup, mounting holes, origin.

Owned here:
    - Edge.Cuts polygon defining the physical board outline. Drawn to
      match the enclosure mount pattern (top module of the pear-shaped
      housing per ARCHITECTURE.md). Dimensions in millimetres.
    - Layer stackup: 4 copper layers minimum (signal / GND / VCC /
      signal). MIPI-CSI 100 ohm differential and 50 ohm antenna trace
      depend on this stackup; impedance calculations target a specific
      dielectric thickness, copper weight, and trace geometry that the
      stackup pins down.
    - Mounting holes: M3 plated, position locked to the enclosure 3D
      print. Connected to GND via thermal spokes for chassis ESD.
    - Auxiliary origin and grid origin, set so kicad-cli pcb export
      gerbers produces output the JLCPCB house-format pipeline accepts
      without manual realignment.

This module runs first in the layout pipeline -- subsystem placement
modules assume the outline exists when they pick coordinates.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pcbnew import BOARD


def configure(board: BOARD) -> None:
    """Set board outline, stackup, mounting holes, and origins."""
    _ = board
