"""Layout-pipeline smoke + invariant tests.

Operates on freshly-created empty BOARDs in memory rather than the
committed ``project/catlaser_aio.kicad_pcb`` so tests run from a clean
checkout without depending on a prior ``just kicad-generate`` /
``just kicad-layout``. Once subsystems are filled in, additional tests
that exercise the committed board can be added alongside.
"""

from __future__ import annotations

import pcbnew

from catlaser_pcb.fab.cpl import (
    JLCPCB_COLUMN_ORDER,
    KICAD_TO_JLCPCB_HEADERS,
    LAYER_NORMALISATION,
)
from catlaser_pcb.layout import (
    board,
    camera_mipi,
    compute_sip,
    compute_storage,
    design_rules,
    hopper_sensor,
    laser_driver,
    mcu_rp2350,
    pours,
    power,
    route,
    servo_headers,
    wifi_rf,
)


def test_pipeline_runs_against_empty_board() -> None:
    """The full layout pipeline runs cleanly against a freshly-created BOARD.

    Stub bodies are no-ops; this test catches structural breakage --
    a misnamed function, a removed module, an import error -- before
    it reaches the live layout step.
    """
    empty = pcbnew.CreateEmptyBoard()
    design_rules.apply(empty)
    board.configure(empty)
    power.place(empty)
    mcu_rp2350.place(empty)
    laser_driver.place(empty)
    servo_headers.place(empty)
    hopper_sensor.place(empty)
    compute_sip.place(empty)
    compute_storage.place(empty)
    camera_mipi.place(empty)
    wifi_rf.place(empty)
    pours.apply(empty)
    route.route(empty)


def test_design_rules_apply_globally() -> None:
    """``design_rules.apply`` writes the documented minima into BOARD_DESIGN_SETTINGS."""
    empty = pcbnew.CreateEmptyBoard()
    design_rules.apply(empty)
    settings = empty.GetDesignSettings()
    assert settings.m_TrackMinWidth == pcbnew.FromMM(design_rules.MIN_TRACK_WIDTH_MM)
    assert settings.m_MinClearance == pcbnew.FromMM(design_rules.MIN_CLEARANCE_MM)
    assert settings.m_ViasMinSize == pcbnew.FromMM(design_rules.MIN_VIA_SIZE_MM)
    assert settings.m_MinThroughDrill == pcbnew.FromMM(design_rules.MIN_THROUGH_DRILL_MM)
    assert settings.m_HoleToHoleMin == pcbnew.FromMM(design_rules.MIN_HOLE_TO_HOLE_MM)
    assert settings.m_HoleClearance == pcbnew.FromMM(design_rules.HOLE_CLEARANCE_MM)
    assert settings.m_CopperEdgeClearance == pcbnew.FromMM(design_rules.COPPER_EDGE_CLEARANCE_MM)


def test_design_rules_apply_is_idempotent() -> None:
    """Applying twice is a no-op against a clean board (regression-safe)."""
    a = pcbnew.CreateEmptyBoard()
    b = pcbnew.CreateEmptyBoard()
    design_rules.apply(a)
    design_rules.apply(b)
    design_rules.apply(b)
    sa = a.GetDesignSettings()
    sb = b.GetDesignSettings()
    assert sa.m_TrackMinWidth == sb.m_TrackMinWidth
    assert sa.m_MinClearance == sb.m_MinClearance
    assert sa.m_ViasMinSize == sb.m_ViasMinSize


def test_jlcpcb_cpl_column_mapping_is_complete() -> None:
    """Every JLCPCB output column has a defined source mapping or layer normalisation."""
    mapped_targets = set(KICAD_TO_JLCPCB_HEADERS.values())
    assert set(JLCPCB_COLUMN_ORDER) == mapped_targets, (
        "JLCPCB_COLUMN_ORDER must exactly match the targets of KICAD_TO_JLCPCB_HEADERS"
    )
    assert LAYER_NORMALISATION == {"top": "Top", "bottom": "Bottom"}
