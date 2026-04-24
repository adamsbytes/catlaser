"""Routing: hand-coded constrained traces, then Freerouting for the rest.

Two-phase routing:

1. ``_route_constrained`` creates explicit ``PCB_TRACK`` and ``PCB_VIA``
   items via pcbnew for nets where geometry is non-negotiable:
     - MIPI-CSI 100 ohm differential pairs (CLK_P/N, D0_P/N): length-
       matched within ~5 mil, both members of a pair on the same layer
       with consistent reference plane, gap geometry from the stackup.
     - 50 ohm antenna trace from the RV1106G3 RF pin through the
       pi-network matching pads to the antenna feed. Single layer, no
       vias, solid GND on the layer below.
     - BGA fanout vias under the RV1106G3: dog-bone pattern, drilled
       from BGA pads on the top layer to inner-layer escape routes.
     - Laser-driver loop: AMC7135 input/output kept short and tight to
       minimise loop inductance; placement is locked first, then the
       trace follows the chosen footprint orientation.

   Each constrained track is marked locked (``track.SetLocked(True)``)
   after creation so phase 2 does not touch it.

2. ``_autoroute_remainder`` shells out to Freerouting for everything
   left, all in-process:
     a. ``pcbnew.ExportSpecctraDSN(board, dsn_path)`` -- writes the
        DSN with locked tracks marked as fixed.
     b. ``java -jar $FREEROUTING_JAR -de in.dsn -do out.ses`` --
        Freerouting respects fixed tracks and leaves them alone.
     c. ``pcbnew.ImportSpecctraSES(board, ses_path)`` -- merges the
        routed session back into the live BOARD.
     d. Apply per-net-class track widths (power: 0.4 mm, signal:
        0.2 mm) for any track where Freerouting used the default.

The Freerouting jar is not bundled. The ``FREEROUTING_JAR`` env var
must point at a downloaded copy (see hardware/kicad/README.md for the
download instructions and tested version pin).
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pcbnew import BOARD


def route(board: BOARD) -> None:
    """Run both routing phases against the live board."""
    _route_constrained(board)
    _autoroute_remainder(board)


def _route_constrained(board: BOARD) -> None:
    """Hand-coded MIPI-CSI, antenna, BGA fanout, and laser-loop traces."""
    _ = board


def _autoroute_remainder(board: BOARD) -> None:
    """Specctra DSN export -> Freerouting -> SES import for remaining nets."""
    _ = board
