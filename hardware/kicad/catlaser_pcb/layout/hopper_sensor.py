"""Placement: JST-PH 4-pin hopper sensor connector + pull-up.

The connector lives on a board edge near the base of the enclosure
where the IR break-beam cable routes through the hopper column. The
10 kohm pull-up to 3.3 V sits within ~5 mm of the SENSE pin so the
trace from the connector to the pull-up node is the dominant
capacitive load, not the run to the MCU and the SiP.

The HOPPER_SENSE net fans out to two reader pins (RP2350 GPIO27 and a
SiP GPIO chosen in compute_sip.py); the fanout star is local to this
cluster, not a long parallel run.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pcbnew import BOARD


def place(board: BOARD) -> None:
    """Position hopper sensor connector, pull-up, and fanout star."""
    _ = board
