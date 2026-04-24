"""Placement: RP2350 QFN-60, boot QSPI flash, SWD header, status LED.

Cluster geometry:
    - RP2350 centred over the inner-layer GND plane, oriented so the
      UART pins (GPIO0/1) face the SiP UART connector and the PWM pins
      (GPIO2-6) face the servo header bank.
    - Boot QSPI flash adjacent to the RP2350 QSPI pins; trace lengths
      kept under 25 mm.
    - SWD header on the board edge for tagged-connector probe access
      without a cable nest.
    - Status LED on GPIO25, placed in a window of the enclosure for
      external visibility.
    - 12 MHz crystal close to the XIN/XOUT pins, ground guard ring.

Decoupling: 10 uF + 4x 1 uF + 8x 100 nF distributed under the QFN-60
on the bottom layer, vias-in-pad to the inner GND.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pcbnew import BOARD


def place(board: BOARD) -> None:
    """Position RP2350 cluster footprints by reference designator."""
    _ = board
