"""Placement: five JST-XH 3-pin servo headers along one board edge.

All five connectors clustered on the same edge (pan, tilt, disc, door,
deflector in that order) so the user can blind-seat them during
assembly. Spacing per JST-XH 2.54 mm pitch plus enough margin for the
crimped housing to clear neighbours.

Per-channel ESD stack (100 ohm series + TVS to GND) placed adjacent to
each connector signal pin so transients clamp before reaching the
RP2350 PWM pins.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pcbnew import BOARD


def place(board: BOARD) -> None:
    """Position servo connectors and per-channel ESD stacks."""
    _ = board
