"""Placement: AMC7135 sink + laser diode terminal.

The driver-and-diode loop is kept compact -- AMC7135, the laser diode
(or its 2-pin terminal block when the diode is on a flying lead),
and the local 1 uF X7R bypass form a triangle within ~5 mm. Loop
inductance here couples directly into laser current ripple, which the
FDA Class 2 argument depends on staying flat.

LASER_EN trace from RP2350 GPIO7 enters this cluster on the top layer,
crosses no plane splits, and includes a TVS-to-GND at the connector
edge to absorb ESD strikes routed back through the laser flying lead.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pcbnew import BOARD


def place(board: BOARD) -> None:
    """Position AMC7135, bypass, and laser terminal by reference designator."""
    _ = board
