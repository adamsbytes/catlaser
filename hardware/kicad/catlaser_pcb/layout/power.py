"""Placement: USB-C receptacle, charger IC, supercap, 3.3 V regulator.

Cluster geometry:
    - USB-C receptacle on the board edge, oriented so the cable exits
      at the back of the enclosure.
    - Charger IC (MCP73871-class) within ~10 mm of the USB-C VBUS pin
      to keep the inrush-limited input loop short.
    - 10 F / 5.5 V supercap on the 5 V output of the charger; bulk
      footprint (radial leaded or large SMT can) placed where it fits
      under the enclosure base without conflicting with hopper geometry.
    - 3.3 V LDO/buck downstream of the supercap, output cluster near
      the RP2350 and the SiP digital rail entry points.

VBUS divider (200 K / 100 K) per constants.rs lives here on the way to
RP2350 ADC0 / GPIO26.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pcbnew import BOARD


def place(board: BOARD) -> None:
    """Position power-subsystem footprints by reference designator."""
    _ = board
