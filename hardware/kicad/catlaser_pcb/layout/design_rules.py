"""Board-wide design rules: minimum trace/clearance/via dimensions.

Applied via ``pcbnew.BOARD.GetDesignSettings()`` so the rules live in
Python alongside everything else, not in the ``.kicad_pro`` file where
they would drift between layout runs.

Defaults are conservative-by-JLCPCB: above their minimum capability
specs for 2-4 layer PCBs at standard pricing tier, with margin so a
rev-1 fab does not fail an extra DRC pass triggered by tolerance
stack-up. Tighten per net-class as bring-up validates the stackup.

Reference values (JLCPCB capability, 2-4 layer, standard tier):
    - min track width / clearance: 5 mil = 0.127 mm (we use 0.15 mm)
    - min via diameter / drill: 0.45 mm / 0.2 mm (we use 0.6 mm / 0.3 mm)
    - hole-to-hole min: 0.5 mm
    - copper-to-edge: 10 mil = 0.254 mm (we use 0.3 mm)
"""

from __future__ import annotations

from typing import TYPE_CHECKING

import pcbnew

if TYPE_CHECKING:
    from pcbnew import BOARD

MIN_TRACK_WIDTH_MM: float = 0.15
MIN_CLEARANCE_MM: float = 0.15
MIN_VIA_SIZE_MM: float = 0.6
MIN_VIA_DRILL_MM: float = 0.3
MIN_THROUGH_DRILL_MM: float = 0.3
MIN_HOLE_TO_HOLE_MM: float = 0.5
COPPER_EDGE_CLEARANCE_MM: float = 0.3
HOLE_CLEARANCE_MM: float = 0.25


def apply(board: BOARD) -> None:
    """Apply the project-wide design rules to ``board``.

    Idempotent -- safe to call on every layout-pipeline run. Net-class
    overrides (controlled-impedance pairs, power-rail track widths)
    are applied separately by ``layout.route``; this function only
    sets the global minimums that gate every other rule.
    """
    settings = board.GetDesignSettings()
    settings.m_TrackMinWidth = pcbnew.FromMM(MIN_TRACK_WIDTH_MM)
    settings.m_MinClearance = pcbnew.FromMM(MIN_CLEARANCE_MM)
    settings.m_ViasMinSize = pcbnew.FromMM(MIN_VIA_SIZE_MM)
    settings.m_MinThroughDrill = pcbnew.FromMM(MIN_THROUGH_DRILL_MM)
    settings.m_HoleToHoleMin = pcbnew.FromMM(MIN_HOLE_TO_HOLE_MM)
    settings.m_HoleClearance = pcbnew.FromMM(HOLE_CLEARANCE_MM)
    settings.m_CopperEdgeClearance = pcbnew.FromMM(COPPER_EDGE_CLEARANCE_MM)
