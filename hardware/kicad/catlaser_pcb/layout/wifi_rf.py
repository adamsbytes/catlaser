"""Placement: chip antenna or U.FL connector + pi-network matching pads.

Antenna corner of the board, isolated from the digital section by the
SiP body. Antenna keep-out zone (declared in pours.py) surrounds the
antenna body or U.FL feed per vendor datasheet -- no copper, no vias,
no traces.

Pi-network matching pads (3 components: series-shunt-series) placed in
a straight line between the SiP RF pin and the antenna feed point.
Default-populate per the antenna vendor's reference; values get
trimmed during EVT after a VNA sweep of the assembled board.

The 50 ohm trace from the SiP RF pin through the matching network to
the antenna feed is owned by route.py (constrained trace phase).
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pcbnew import BOARD


def place(board: BOARD) -> None:
    """Position antenna and matching network footprints."""
    _ = board
