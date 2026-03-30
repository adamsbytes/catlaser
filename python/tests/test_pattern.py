"""Tests for the laser movement pattern generator."""

from __future__ import annotations

import itertools
import math
import random

from catlaser_brain.behavior.pattern import PatternConfig, PatternGenerator
from catlaser_brain.behavior.state_machine import CatObservation

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_DEFAULT_CONFIG = PatternConfig()

_DT: float = 1.0 / 15.0


def _gen(config: PatternConfig = _DEFAULT_CONFIG, seed: int = 42) -> PatternGenerator:
    return PatternGenerator(config, random.Random(seed))  # noqa: S311


def _cat(vx: float = 0.0, vy: float = 0.0) -> CatObservation:
    return CatObservation(center_x=0.5, center_y=0.5, velocity_x=vx, velocity_y=vy)


def _direction_changes(values: list[float]) -> int:
    changes = 0
    prev_d = 0.0
    for a, b in itertools.pairwise(values):
        d = b - a
        if prev_d * d < 0:
            changes += 1
        prev_d = d
    return changes


# ---------------------------------------------------------------------------
# Lure
# ---------------------------------------------------------------------------


class TestLure:
    def test_bounded_offsets(self):
        g = _gen()
        limit = _DEFAULT_CONFIG.offset_clamp
        for i in range(300):
            g.tick(_DT)
            ox, oy = g.lure(0.5)
            assert -limit <= ox <= limit, f"frame {i}: ox={ox}"
            assert -limit <= oy <= limit, f"frame {i}: oy={oy}"

    def test_produces_nonzero_offsets(self):
        g = _gen()
        has_nonzero = False
        for _ in range(100):
            g.tick(_DT)
            ox, oy = g.lure(0.5)
            if abs(ox) > 1e-6 or abs(oy) > 1e-6:
                has_nonzero = True
                break
        assert has_nonzero

    def test_figure_eight_y_oscillates_faster(self):
        g = _gen()
        xs: list[float] = []
        ys: list[float] = []
        for _ in range(200):
            g.tick(_DT)
            ox, oy = g.lure(0.0)
            xs.append(ox)
            ys.append(oy)
        x_crossings = sum(1 for a, b in itertools.pairwise(xs) if a * b < 0)
        y_crossings = sum(1 for a, b in itertools.pairwise(ys) if a * b < 0)
        assert y_crossings > x_crossings

    def test_zero_dt_produces_zero_at_origin(self):
        g = _gen()
        g.tick(0.0)
        ox, oy = g.lure(0.0)
        assert abs(ox) < 1e-9
        assert abs(oy) < 1e-9

    def test_high_randomness_adds_harmonics(self):
        g_low = _gen(seed=42)
        g_high = _gen(seed=42)

        xs_low: list[float] = []
        xs_high: list[float] = []
        for _ in range(200):
            g_low.tick(_DT)
            g_high.tick(_DT)
            ox_low, _ = g_low.lure(0.0)
            ox_high, _ = g_high.lure(1.0)
            xs_low.append(ox_low)
            xs_high.append(ox_high)

        assert _direction_changes(xs_high) > _direction_changes(xs_low)

    def test_amplitude_scales_with_config(self):
        small = PatternConfig(lure_amplitude=0.02)
        large = PatternConfig(lure_amplitude=0.10)
        g_small = _gen(config=small)
        g_large = _gen(config=large)

        max_small = 0.0
        max_large = 0.0
        for _ in range(200):
            g_small.tick(_DT)
            g_large.tick(_DT)
            ox_s, oy_s = g_small.lure(0.5)
            ox_l, oy_l = g_large.lure(0.5)
            max_small = max(max_small, abs(ox_s), abs(oy_s))
            max_large = max(max_large, abs(ox_l), abs(oy_l))

        assert max_large > max_small


# ---------------------------------------------------------------------------
# Chase
# ---------------------------------------------------------------------------


class TestChase:
    def test_zero_velocity_near_zero_offset(self):
        g = _gen()
        g.tick(0.0)
        ox, oy = g.chase(_cat(vx=0.0, vy=0.0), 0.5)
        assert abs(ox) < 0.01
        assert abs(oy) < 0.01

    def test_positive_x_velocity_positive_lead(self):
        g = _gen()
        g.tick(0.0)
        ox, _ = g.chase(_cat(vx=0.2, vy=0.0), 0.5)
        assert ox > 0.0

    def test_negative_x_velocity_negative_lead(self):
        g = _gen()
        g.tick(0.0)
        ox, _ = g.chase(_cat(vx=-0.2, vy=0.0), 0.5)
        assert ox < 0.0

    def test_positive_y_velocity_positive_lead(self):
        g = _gen()
        g.tick(0.0)
        _, oy = g.chase(_cat(vx=0.0, vy=0.2), 0.5)
        assert oy > 0.0

    def test_diagonal_velocity_leads_diagonally(self):
        g = _gen()
        g.tick(0.0)
        ox, oy = g.chase(_cat(vx=0.2, vy=0.2), 0.5)
        assert ox > 0.0
        assert oy > 0.0

    def test_lead_capped_at_max(self):
        cfg = _DEFAULT_CONFIG
        g = _gen(config=cfg)
        g.tick(0.0)
        ox, _ = g.chase(_cat(vx=10.0, vy=0.0), 0.5)
        assert abs(ox) <= cfg.chase_lead_max + 1e-6

    def test_none_cat_returns_zero(self):
        g = _gen()
        g.tick(1.0)
        ox, oy = g.chase(None, 0.5)
        assert ox == 0.0
        assert oy == 0.0

    def test_lateral_weave_produces_perpendicular_offset(self):
        g = _gen()
        cat = _cat(vx=0.1, vy=0.0)
        y_values: list[float] = []
        for _ in range(100):
            g.tick(_DT)
            _, oy = g.chase(cat, 1.0)
            y_values.append(oy)
        assert any(y > 0.001 for y in y_values)
        assert any(y < -0.001 for y in y_values)

    def test_bounded_offsets(self):
        g = _gen()
        limit = _DEFAULT_CONFIG.offset_clamp
        cat = _cat(vx=0.3, vy=0.2)
        for i in range(300):
            g.tick(_DT)
            ox, oy = g.chase(cat, 1.0)
            assert -limit <= ox <= limit, f"frame {i}: ox={ox}"
            assert -limit <= oy <= limit, f"frame {i}: oy={oy}"

    def test_randomness_scales_lateral_amplitude(self):
        g_low = _gen(seed=42)
        g_high = _gen(seed=42)
        cat = _cat(vx=0.1, vy=0.0)

        max_y_low = 0.0
        max_y_high = 0.0
        for _ in range(200):
            g_low.tick(_DT)
            g_high.tick(_DT)
            _, oy_low = g_low.chase(cat, 0.0)
            _, oy_high = g_high.chase(cat, 1.0)
            max_y_low = max(max_y_low, abs(oy_low))
            max_y_high = max(max_y_high, abs(oy_high))

        assert max_y_high > max_y_low


# ---------------------------------------------------------------------------
# Tease
# ---------------------------------------------------------------------------


class TestTease:
    def test_bounded_offsets(self):
        g = _gen()
        limit = _DEFAULT_CONFIG.offset_clamp
        for i in range(500):
            g.tick(_DT)
            ox, oy = g.tease(_DT, 0.5)
            assert -limit <= ox <= limit, f"frame {i}: ox={ox}"
            assert -limit <= oy <= limit, f"frame {i}: oy={oy}"

    def test_produces_nonzero_offsets(self):
        g = _gen()
        has_nonzero = False
        for _ in range(100):
            g.tick(_DT)
            ox, oy = g.tease(_DT, 0.5)
            if abs(ox) > 1e-6 or abs(oy) > 1e-6:
                has_nonzero = True
                break
        assert has_nonzero

    def test_direction_changes(self):
        g = _gen()
        xs: list[float] = []
        for _ in range(200):
            g.tick(_DT)
            ox, _ = g.tease(_DT, 0.5)
            xs.append(ox)

        x_sign_changes = sum(1 for a, b in itertools.pairwise(xs) if a * b < 0)
        assert x_sign_changes > 0

    def test_can_freeze(self):
        cfg = PatternConfig(tease_freeze_probability=0.5)
        g = _gen(config=cfg)
        freeze_count = 0
        for _ in range(500):
            g.tick(_DT)
            ox, oy = g.tease(_DT, 0.5)
            if abs(ox) < 1e-9 and abs(oy) < 1e-9:
                freeze_count += 1
        assert freeze_count > 0

    def test_higher_randomness_larger_magnitude(self):
        g_low = _gen(seed=42)
        g_high = _gen(seed=42)

        max_mag_low = 0.0
        max_mag_high = 0.0
        for _ in range(500):
            g_low.tick(_DT)
            g_high.tick(_DT)
            ox_l, oy_l = g_low.tease(_DT, 0.0)
            ox_h, oy_h = g_high.tease(_DT, 1.0)
            max_mag_low = max(max_mag_low, math.hypot(ox_l, oy_l))
            max_mag_high = max(max_mag_high, math.hypot(ox_h, oy_h))

        assert max_mag_high > max_mag_low

    def test_no_freeze_with_zero_probability(self):
        cfg = PatternConfig(tease_freeze_probability=0.0)
        g = _gen(config=cfg)
        zero_count = 0
        for _ in range(200):
            g.tick(_DT)
            ox, oy = g.tease(_DT, 0.5)
            if abs(ox) < 1e-9 and abs(oy) < 1e-9:
                zero_count += 1
        # Without freeze, zero offsets should not appear after initial pick.
        assert zero_count == 0


# ---------------------------------------------------------------------------
# Reset
# ---------------------------------------------------------------------------


class TestReset:
    def test_reset_clears_phase(self):
        g = _gen()
        for _ in range(100):
            g.tick(_DT)
            g.lure(0.5)

        g.reset()
        g.tick(0.0)
        ox, oy = g.lure(0.0)
        assert abs(ox) < 1e-9
        assert abs(oy) < 1e-9

    def test_reset_clears_juke_state(self):
        g = _gen()
        for _ in range(50):
            g.tick(_DT)
            g.tease(_DT, 0.5)

        g.reset()
        g.tick(_DT)
        ox, oy = g.tease(_DT, 0.5)
        assert isinstance(ox, float)
        assert isinstance(oy, float)


# ---------------------------------------------------------------------------
# Clamp
# ---------------------------------------------------------------------------


class TestClamp:
    def test_large_amplitude_clamped(self):
        cfg = PatternConfig(lure_amplitude=1.0, offset_clamp=0.05)
        g = _gen(config=cfg)
        for _ in range(200):
            g.tick(_DT)
            ox, oy = g.lure(1.0)
            assert -0.05 <= ox <= 0.05
            assert -0.05 <= oy <= 0.05

    def test_large_lead_clamped(self):
        cfg = PatternConfig(chase_lead_max=1.0, offset_clamp=0.05)
        g = _gen(config=cfg)
        g.tick(0.0)
        ox, oy = g.chase(_cat(vx=10.0, vy=0.0), 0.5)
        assert -0.05 <= ox <= 0.05
        assert -0.05 <= oy <= 0.05

    def test_large_juke_clamped(self):
        cfg = PatternConfig(
            tease_magnitude_min=0.5,
            tease_magnitude_max=1.0,
            offset_clamp=0.05,
        )
        g = _gen(config=cfg)
        for _ in range(100):
            g.tick(_DT)
            ox, oy = g.tease(_DT, 1.0)
            assert -0.05 <= ox <= 0.05
            assert -0.05 <= oy <= 0.05
