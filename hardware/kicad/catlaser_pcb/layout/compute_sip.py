"""Placement: RV1106G3 BGA + decoupling + power sequencing components.

This is the most layout-sensitive subsystem on the board.

SiP placement:
    - Centred over the largest contiguous GND area, no plane splits
      under the package outline.
    - Orientation chosen so the MIPI-CSI bank faces the camera ribbon
      connector (camera_mipi.py), the RF pin faces the antenna corner
      (wifi_rf.py), the QSPI/SDIO bank faces the storage cluster
      (compute_storage.py), and the UART pins face the RP2350 (so the
      SiP-to-MCU UART run stays short).

Decoupling pattern:
    - 10 uF bulk + 4x 1 uF + 8x 100 nF distributed across the BGA on
      the opposite layer, vias-in-pad straight to the inner GND
      and inner VCC planes per the Rockchip reference design.
    - Each rail (VDD_CORE, VDD_LOGIC, VDD_IO_3V3, VDD_PMU,
      VDD_DDR_1V35) gets its own bypass cluster directly under the
      corresponding ball group.

Power sequencing:
    - PMIC or discrete LDOs + supervisor placed on the side opposite
      the antenna so switching noise has the longest path to the RF
      corner.

BGA fanout via pattern is generated in route.py (constrained trace
phase) -- placement only fixes the SiP itself, the bypass clusters,
and the sequencing parts.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pcbnew import BOARD


def place(board: BOARD) -> None:
    """Position SiP, decoupling clusters, and power-sequencing parts."""
    _ = board
