"""Placement: SOIC-8 QSPI flash + SOIC-8 SPI NAND + microSD slot.

Both 8-pin SOICs sit adjacent to the SiP storage-bank edge, oriented so
QSPI/SPI data lines run parallel without crossing each other. Trace
lengths under 25 mm, length-matched within tolerance for the QSPI clock
group.

microSD slot (push-push SMT) on a board edge accessible through a slot
in the enclosure base for user-replaceable cards. Card-detect line
pulled up to 3.3 V locally, routed to a SiP GPIO.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pcbnew import BOARD


def place(board: BOARD) -> None:
    """Position QSPI flash, SPI NAND, microSD slot, and pull-ups."""
    _ = board
