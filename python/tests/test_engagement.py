"""Tests for the engagement tracking module."""

from __future__ import annotations

from catlaser_brain.behavior.engagement import (
    EngagementConfig,
    EngagementSnapshot,
    EngagementTracker,
)

_DEFAULT_DT: float = 1.0 / 15.0

_TOLERANCE: float = 1e-9


def _tracker(config: EngagementConfig | None = None) -> EngagementTracker:
    return EngagementTracker(config or EngagementConfig())


def _close(a: float, b: float, *, tol: float = _TOLERANCE) -> bool:
    return abs(a - b) <= tol


# ---------------------------------------------------------------------------
# Pounce detection
# ---------------------------------------------------------------------------


class TestPounceDetection:
    def test_single_burst_counts_once(self):
        t = _tracker()
        for _ in range(30):
            t.update(0.20, _DEFAULT_DT)
        assert t.pounce_count == 1

    def test_no_pounce_below_threshold(self):
        t = _tracker()
        for _ in range(30):
            t.update(0.10, _DEFAULT_DT)
        assert t.pounce_count == 0

    def test_multiple_distinct_bursts(self):
        t = _tracker()
        for _ in range(10):
            t.update(0.20, _DEFAULT_DT)
        for _ in range(10):
            t.update(0.05, _DEFAULT_DT)
        for _ in range(10):
            t.update(0.20, _DEFAULT_DT)
        assert t.pounce_count == 2

    def test_hysteresis_prevents_double_count(self):
        t = _tracker()
        for _ in range(5):
            t.update(0.20, _DEFAULT_DT)
        # Speed drops but stays above reset threshold (0.15 * 0.5 = 0.075).
        for _ in range(5):
            t.update(0.10, _DEFAULT_DT)
        for _ in range(5):
            t.update(0.20, _DEFAULT_DT)
        assert t.pounce_count == 1

    def test_exact_threshold_counts_pounce(self):
        t = _tracker()
        t.update(0.15, _DEFAULT_DT)
        assert t.pounce_count == 1

    def test_exact_reset_threshold_does_not_reset(self):
        t = _tracker()
        t.update(0.20, _DEFAULT_DT)
        assert t.pounce_count == 1
        # Exactly at reset threshold (0.15 * 0.5 = 0.075): not strictly below.
        t.update(0.075, _DEFAULT_DT)
        t.update(0.20, _DEFAULT_DT)
        assert t.pounce_count == 1

    def test_below_reset_threshold_allows_new_pounce(self):
        t = _tracker()
        t.update(0.20, _DEFAULT_DT)
        assert t.pounce_count == 1
        t.update(0.074, _DEFAULT_DT)
        t.update(0.20, _DEFAULT_DT)
        assert t.pounce_count == 2

    def test_rapid_oscillation_near_threshold(self):
        t = _tracker()
        for _ in range(20):
            t.update(0.16, _DEFAULT_DT)
            t.update(0.14, _DEFAULT_DT)
        assert t.pounce_count == 1

    def test_three_clean_pounces(self):
        t = _tracker()
        for _ in range(3):
            for _ in range(2):
                t.update(0.25, _DEFAULT_DT)
            for _ in range(2):
                t.update(0.03, _DEFAULT_DT)
        assert t.pounce_count == 3


# ---------------------------------------------------------------------------
# Time-on-target
# ---------------------------------------------------------------------------


class TestTimeOnTarget:
    def test_all_time_on_target(self):
        t = _tracker()
        for _ in range(30):
            t.update(0.10, _DEFAULT_DT)
        assert _close(t.time_on_target, 1.0)

    def test_no_time_on_target(self):
        t = _tracker()
        for _ in range(30):
            t.update(0.01, _DEFAULT_DT)
        assert _close(t.time_on_target, 0.0)

    def test_partial_time_on_target(self):
        t = _tracker()
        for _ in range(15):
            t.update(0.10, _DEFAULT_DT)
        for _ in range(15):
            t.update(0.01, _DEFAULT_DT)
        assert _close(t.time_on_target, 0.5, tol=1e-6)

    def test_exact_threshold_counts(self):
        t = _tracker()
        t.update(0.03, _DEFAULT_DT)
        assert _close(t.time_on_target, 1.0)

    def test_zero_active_time(self):
        t = _tracker()
        assert t.time_on_target == 0.0


# ---------------------------------------------------------------------------
# Velocity
# ---------------------------------------------------------------------------


class TestVelocity:
    def test_average_velocity(self):
        t = _tracker()
        t.update(0.10, _DEFAULT_DT)
        t.update(0.20, _DEFAULT_DT)
        t.update(0.30, _DEFAULT_DT)
        assert _close(t.avg_velocity, 0.20, tol=1e-6)

    def test_zero_frames(self):
        t = _tracker()
        assert t.avg_velocity == 0.0

    def test_ema_seeded_with_first_value(self):
        t = _tracker()
        t.update(0.50, _DEFAULT_DT)
        assert t.velocity_ema == 0.50

    def test_ema_adapts_gradually(self):
        cfg = EngagementConfig(velocity_ema_alpha=0.1)
        t = _tracker(cfg)
        t.update(0.50, _DEFAULT_DT)
        t.update(0.0, _DEFAULT_DT)
        assert _close(t.velocity_ema, 0.45, tol=1e-6)
        t.update(0.0, _DEFAULT_DT)
        assert _close(t.velocity_ema, 0.405, tol=1e-6)

    def test_ema_converges_to_constant(self):
        cfg = EngagementConfig(velocity_ema_alpha=0.5)
        t = _tracker(cfg)
        for _ in range(100):
            t.update(0.10, _DEFAULT_DT)
        assert _close(t.velocity_ema, 0.10, tol=1e-6)

    def test_active_time_accumulates(self):
        t = _tracker()
        t.update(0.10, 0.5)
        t.update(0.10, 0.3)
        assert _close(t.active_time, 0.8)


# ---------------------------------------------------------------------------
# Pounce rate
# ---------------------------------------------------------------------------


class TestPounceRate:
    def test_rate_per_second(self):
        t = _tracker()
        for _ in range(15):
            t.update(0.20, _DEFAULT_DT)
        for _ in range(7):
            t.update(0.05, _DEFAULT_DT)
        for _ in range(8):
            t.update(0.20, _DEFAULT_DT)
        assert t.pounce_count == 2
        assert _close(t.pounce_rate, 2.0 / t.active_time)

    def test_zero_with_insufficient_time(self):
        t = _tracker()
        t.update(0.20, 0.5)
        assert t.pounce_count == 1
        assert t.pounce_rate == 0.0


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------


class TestScoring:
    def test_zero_with_no_data(self):
        t = _tracker()
        assert t.score == 0.0

    def test_zero_with_insufficient_time(self):
        t = _tracker()
        t.update(0.50, 0.5)
        assert t.score == 0.0

    def test_velocity_only(self):
        cfg = EngagementConfig(
            velocity_weight=1.0,
            pounce_weight=0.0,
            time_on_target_weight=0.0,
            velocity_normalization=0.2,
            on_target_velocity_threshold=100.0,
        )
        t = _tracker(cfg)
        for _ in range(30):
            t.update(0.10, _DEFAULT_DT)
        assert _close(t.score, 0.5, tol=1e-6)

    def test_pounce_only(self):
        cfg = EngagementConfig(
            velocity_weight=0.0,
            pounce_weight=1.0,
            time_on_target_weight=0.0,
            pounce_rate_normalization=0.5,
            pounce_velocity_threshold=0.15,
            pounce_reset_factor=0.5,
        )
        t = _tracker(cfg)
        # Burst above threshold, then drop below reset.
        for _ in range(15):
            t.update(0.20, _DEFAULT_DT)
        for _ in range(15):
            t.update(0.05, _DEFAULT_DT)
        assert t.pounce_count == 1
        # 1 pounce over ~2s, rate ~0.5, normalized by 0.5 = ~1.0
        assert _close(t.score, min(t.pounce_rate / 0.5, 1.0))

    def test_time_on_target_only(self):
        cfg = EngagementConfig(
            velocity_weight=0.0,
            pounce_weight=0.0,
            time_on_target_weight=1.0,
            on_target_velocity_threshold=0.05,
        )
        t = _tracker(cfg)
        for _ in range(15):
            t.update(0.10, _DEFAULT_DT)
        for _ in range(15):
            t.update(0.01, _DEFAULT_DT)
        assert _close(t.score, 0.5, tol=1e-6)

    def test_weighted_combination(self):
        cfg = EngagementConfig(
            velocity_weight=0.4,
            pounce_weight=0.3,
            time_on_target_weight=0.3,
            velocity_normalization=0.2,
            pounce_rate_normalization=1.0,
            on_target_velocity_threshold=0.05,
            pounce_velocity_threshold=0.15,
            pounce_reset_factor=0.5,
        )
        t = _tracker(cfg)
        # 15 frames fast (pounce + on-target), 15 frames idle.
        for _ in range(15):
            t.update(0.20, _DEFAULT_DT)
        for _ in range(15):
            t.update(0.02, _DEFAULT_DT)

        assert _close(t.avg_velocity, 0.11, tol=0.001)
        assert t.pounce_count == 1
        assert _close(t.time_on_target, 0.5, tol=0.01)

        # Expected: vel component 0.22, pounce component ~0.15,
        # time-on-target component 0.15, total ~0.52
        assert _close(t.score, 0.52, tol=0.03)

    def test_bounded_zero_to_one(self):
        t = _tracker()
        for _ in range(30):
            t.update(10.0, _DEFAULT_DT)
        assert 0.0 <= t.score <= 1.0

    def test_default_weights_sum_to_one(self):
        cfg = EngagementConfig()
        total = cfg.velocity_weight + cfg.pounce_weight + cfg.time_on_target_weight
        assert _close(total, 1.0)


# ---------------------------------------------------------------------------
# Tier
# ---------------------------------------------------------------------------


class TestTier:
    def _tier_config(self) -> EngagementConfig:
        return EngagementConfig(
            velocity_weight=1.0,
            pounce_weight=0.0,
            time_on_target_weight=0.0,
            velocity_normalization=1.0,
        )

    def test_tier_zero(self):
        t = _tracker(self._tier_config())
        for _ in range(30):
            t.update(0.10, _DEFAULT_DT)
        assert t.tier == 0

    def test_tier_one(self):
        t = _tracker(self._tier_config())
        for _ in range(30):
            t.update(0.50, _DEFAULT_DT)
        assert t.tier == 1

    def test_tier_two(self):
        t = _tracker(self._tier_config())
        for _ in range(30):
            t.update(0.80, _DEFAULT_DT)
        assert t.tier == 2

    def test_low_boundary_inclusive(self):
        t = _tracker(self._tier_config())
        for _ in range(30):
            t.update(0.33, _DEFAULT_DT)
        assert t.tier == 1

    def test_high_boundary_inclusive(self):
        t = _tracker(self._tier_config())
        for _ in range(30):
            t.update(0.66, _DEFAULT_DT)
        assert t.tier == 2

    def test_no_data(self):
        t = _tracker()
        assert t.tier == 0


# ---------------------------------------------------------------------------
# Snapshot
# ---------------------------------------------------------------------------


class TestSnapshot:
    def test_captures_all_fields(self):
        t = _tracker()
        for _ in range(30):
            t.update(0.10, _DEFAULT_DT)
        snap = t.snapshot()
        assert isinstance(snap, EngagementSnapshot)
        assert snap.avg_velocity == t.avg_velocity
        assert snap.velocity_ema == t.velocity_ema
        assert snap.pounce_count == t.pounce_count
        assert snap.pounce_rate == t.pounce_rate
        assert snap.time_on_target == t.time_on_target
        assert snap.active_time == t.active_time
        assert snap.score == t.score
        assert snap.tier == t.tier

    def test_snapshot_independent_of_subsequent_updates(self):
        t = _tracker()
        for _ in range(15):
            t.update(0.10, _DEFAULT_DT)
        snap = t.snapshot()
        vel_before = snap.avg_velocity
        for _ in range(15):
            t.update(0.50, _DEFAULT_DT)
        assert snap.avg_velocity == vel_before
        assert t.avg_velocity != vel_before
