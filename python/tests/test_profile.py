"""Tests for per-cat profile adaptation."""

from __future__ import annotations

import random
import sqlite3
import time
from collections.abc import Iterator
from pathlib import Path

import pytest

from catlaser_brain.behavior.profile import (
    AdaptationConfig,
    CatProfile,
    adapt_profile,
    load_profile,
    save_profile,
)
from catlaser_brain.behavior.state_machine import (
    BehaviorEngine,
    CatObservation,
    ChuteSide,
    EngineConfig,
    State,
    apply_profile,
)
from catlaser_brain.storage.db import Database

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_TOLERANCE: float = 1e-9

_FAST_CONFIG = EngineConfig(
    lure_min_duration=1.0,
    lure_max_duration=5.0,
    lure_engagement_velocity=0.05,
    chase_min_before_tease=2.0,
    chase_tease_interval_min=3.0,
    chase_tease_interval_max=3.0,
    tease_duration_min=1.0,
    tease_duration_max=1.0,
    cooldown_timeout=5.0,
    cooldown_arrival_tolerance=0.05,
    dispense_duration=1.0,
    session_timeout=60.0,
    track_lost_timeout=2.0,
)


def _close(a: float, b: float, *, tol: float = _TOLERANCE) -> bool:
    return abs(a - b) <= tol


def _engine(config: EngineConfig = _FAST_CONFIG, seed: int = 42) -> BehaviorEngine:
    return BehaviorEngine(config, random.Random(seed))  # noqa: S311


def _cat(
    cx: float = 0.5,
    cy: float = 0.5,
    vx: float = 0.0,
    vy: float = 0.0,
) -> CatObservation:
    return CatObservation(center_x=cx, center_y=cy, velocity_x=vx, velocity_y=vy)


def _engaged_cat() -> CatObservation:
    return _cat(vx=0.1, vy=0.0)


@pytest.fixture
def conn(tmp_path: Path) -> Iterator[sqlite3.Connection]:
    db = Database.connect(tmp_path / "test.db")
    yield db.conn
    db.close()


def _insert_cat(
    conn: sqlite3.Connection,
    cat_id: str = "cat-1",
    *,
    preferred_speed: float = 1.0,
    preferred_smoothing: float = 0.5,
    pattern_randomness: float = 0.5,
) -> None:
    now = int(time.time())
    conn.execute(
        "INSERT INTO cats "
        "(cat_id, name, thumbnail, preferred_speed, preferred_smoothing, "
        "pattern_randomness, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (
            cat_id,
            "TestCat",
            b"\xff\xd8test",
            preferred_speed,
            preferred_smoothing,
            pattern_randomness,
            now,
            now,
        ),
    )
    conn.commit()


# ---------------------------------------------------------------------------
# adapt_profile -- direction tests
# ---------------------------------------------------------------------------


class TestAdaptProfileDirection:
    def test_high_engagement_increases_speed(self):
        profile = CatProfile()
        adapted = adapt_profile(
            profile,
            engagement_score=0.9,
            time_on_target=0.5,
            pounce_rate=0.05,
            active_play_time=30.0,
        )
        assert adapted.preferred_speed > profile.preferred_speed

    def test_low_engagement_decreases_speed(self):
        profile = CatProfile()
        adapted = adapt_profile(
            profile,
            engagement_score=0.1,
            time_on_target=0.5,
            pounce_rate=0.05,
            active_play_time=30.0,
        )
        assert adapted.preferred_speed < profile.preferred_speed

    def test_low_time_on_target_increases_smoothing(self):
        profile = CatProfile()
        adapted = adapt_profile(
            profile,
            engagement_score=0.5,
            time_on_target=0.1,
            pounce_rate=0.05,
            active_play_time=30.0,
        )
        assert adapted.preferred_smoothing > profile.preferred_smoothing

    def test_high_time_on_target_decreases_smoothing(self):
        profile = CatProfile()
        adapted = adapt_profile(
            profile,
            engagement_score=0.5,
            time_on_target=0.9,
            pounce_rate=0.05,
            active_play_time=30.0,
        )
        assert adapted.preferred_smoothing < profile.preferred_smoothing

    def test_high_pounce_rate_increases_randomness(self):
        profile = CatProfile()
        adapted = adapt_profile(
            profile,
            engagement_score=0.5,
            time_on_target=0.5,
            pounce_rate=0.15,
            active_play_time=30.0,
        )
        assert adapted.pattern_randomness > profile.pattern_randomness

    def test_low_pounce_rate_decreases_randomness(self):
        profile = CatProfile()
        adapted = adapt_profile(
            profile,
            engagement_score=0.5,
            time_on_target=0.5,
            pounce_rate=0.0,
            active_play_time=30.0,
        )
        assert adapted.pattern_randomness < profile.pattern_randomness


# ---------------------------------------------------------------------------
# adapt_profile -- neutral inputs
# ---------------------------------------------------------------------------


class TestAdaptProfileNeutral:
    def test_neutral_smoothing_unchanged(self):
        profile = CatProfile()
        adapted = adapt_profile(
            profile,
            engagement_score=0.5,
            time_on_target=0.5,
            pounce_rate=0.05,
            active_play_time=30.0,
        )
        assert _close(adapted.preferred_smoothing, 0.5)

    def test_neutral_randomness_unchanged(self):
        profile = CatProfile()
        adapted = adapt_profile(
            profile,
            engagement_score=0.5,
            time_on_target=0.5,
            pounce_rate=0.05,
            active_play_time=30.0,
        )
        assert _close(adapted.pattern_randomness, 0.5)


# ---------------------------------------------------------------------------
# adapt_profile -- bounds and clamping
# ---------------------------------------------------------------------------


class TestAdaptProfileBounds:
    def test_short_session_returns_unchanged(self):
        profile = CatProfile(
            preferred_speed=1.5,
            preferred_smoothing=0.7,
            pattern_randomness=0.8,
        )
        adapted = adapt_profile(
            profile,
            engagement_score=0.9,
            time_on_target=0.9,
            pounce_rate=0.2,
            active_play_time=2.0,
        )
        assert adapted is profile

    def test_speed_clamped_to_max(self):
        profile = CatProfile(preferred_speed=1.95)
        adapted = adapt_profile(
            profile,
            engagement_score=1.0,
            time_on_target=0.5,
            pounce_rate=0.05,
            active_play_time=30.0,
        )
        assert adapted.preferred_speed <= 2.0

    def test_speed_clamped_to_min(self):
        profile = CatProfile(preferred_speed=0.35)
        adapted = adapt_profile(
            profile,
            engagement_score=0.0,
            time_on_target=0.5,
            pounce_rate=0.05,
            active_play_time=30.0,
        )
        assert adapted.preferred_speed >= 0.3

    def test_smoothing_clamped_to_bounds(self):
        cfg = AdaptationConfig(smoothing_min=0.1, smoothing_max=0.9)
        high = adapt_profile(
            CatProfile(preferred_smoothing=0.88),
            engagement_score=0.5,
            time_on_target=0.0,
            pounce_rate=0.05,
            active_play_time=30.0,
            config=cfg,
        )
        assert high.preferred_smoothing <= 0.9
        low = adapt_profile(
            CatProfile(preferred_smoothing=0.12),
            engagement_score=0.5,
            time_on_target=1.0,
            pounce_rate=0.05,
            active_play_time=30.0,
            config=cfg,
        )
        assert low.preferred_smoothing >= 0.1

    def test_randomness_clamped_to_bounds(self):
        cfg = AdaptationConfig(randomness_min=0.1, randomness_max=0.9)
        high = adapt_profile(
            CatProfile(pattern_randomness=0.88),
            engagement_score=0.5,
            time_on_target=0.5,
            pounce_rate=1.0,
            active_play_time=30.0,
            config=cfg,
        )
        assert high.pattern_randomness <= 0.9
        low = adapt_profile(
            CatProfile(pattern_randomness=0.12),
            engagement_score=0.5,
            time_on_target=0.5,
            pounce_rate=0.0,
            active_play_time=30.0,
            config=cfg,
        )
        assert low.pattern_randomness >= 0.1

    def test_pounce_rate_above_normalization_capped(self):
        profile = CatProfile()
        high_pounce = adapt_profile(
            profile,
            engagement_score=0.5,
            time_on_target=0.5,
            pounce_rate=1.0,
            active_play_time=30.0,
        )
        at_normalization = adapt_profile(
            profile,
            engagement_score=0.5,
            time_on_target=0.5,
            pounce_rate=0.1,
            active_play_time=30.0,
        )
        assert _close(
            high_pounce.pattern_randomness,
            at_normalization.pattern_randomness,
        )


# ---------------------------------------------------------------------------
# adapt_profile -- convergence and stability
# ---------------------------------------------------------------------------


class TestAdaptProfileConvergence:
    def test_convergence_high_engagement(self):
        profile = CatProfile()
        for _ in range(100):
            profile = adapt_profile(
                profile,
                engagement_score=0.95,
                time_on_target=0.5,
                pounce_rate=0.05,
                active_play_time=30.0,
            )
        assert profile.preferred_speed > 1.8

    def test_convergence_low_engagement(self):
        profile = CatProfile()
        for _ in range(100):
            profile = adapt_profile(
                profile,
                engagement_score=0.05,
                time_on_target=0.5,
                pounce_rate=0.05,
                active_play_time=30.0,
            )
        assert profile.preferred_speed < 0.5

    def test_stability_alternating_sessions(self):
        profile = CatProfile()
        for _ in range(50):
            profile = adapt_profile(
                profile,
                engagement_score=0.9,
                time_on_target=0.9,
                pounce_rate=0.15,
                active_play_time=30.0,
            )
            profile = adapt_profile(
                profile,
                engagement_score=0.1,
                time_on_target=0.1,
                pounce_rate=0.0,
                active_play_time=30.0,
            )
        # After many alternating sessions, the profile settles near the
        # middle of each range rather than oscillating to extremes.
        assert 0.7 < profile.preferred_speed < 1.5
        assert 0.3 < profile.preferred_smoothing < 0.7
        assert 0.3 < profile.pattern_randomness < 0.7

    def test_learning_rate_controls_adaptation_speed(self):
        fast_cfg = AdaptationConfig(learning_rate=0.5)
        slow_cfg = AdaptationConfig(learning_rate=0.05)
        profile = CatProfile()
        fast_adapted = adapt_profile(
            profile,
            engagement_score=0.9,
            time_on_target=0.5,
            pounce_rate=0.05,
            active_play_time=30.0,
            config=fast_cfg,
        )
        slow_adapted = adapt_profile(
            profile,
            engagement_score=0.9,
            time_on_target=0.5,
            pounce_rate=0.05,
            active_play_time=30.0,
            config=slow_cfg,
        )
        fast_delta = abs(fast_adapted.preferred_speed - profile.preferred_speed)
        slow_delta = abs(slow_adapted.preferred_speed - profile.preferred_speed)
        assert fast_delta > slow_delta


# ---------------------------------------------------------------------------
# apply_profile
# ---------------------------------------------------------------------------


class TestApplyProfile:
    def test_default_profile_preserves_config(self):
        config = EngineConfig()
        result = apply_profile(config, CatProfile())
        assert result.chase_max_speed == config.chase_max_speed
        assert result.tease_max_speed == config.tease_max_speed
        assert result.chase_smoothing == config.chase_smoothing
        assert _close(result.tease_smoothing, config.tease_smoothing)

    def test_speed_multiplier_scales_chase_and_tease(self):
        config = EngineConfig()
        profile = CatProfile(preferred_speed=1.5)
        result = apply_profile(config, profile)
        assert _close(result.chase_max_speed, config.chase_max_speed * 1.5)
        assert _close(result.tease_max_speed, config.tease_max_speed * 1.5)

    def test_smoothing_overrides_chase(self):
        config = EngineConfig()
        profile = CatProfile(preferred_smoothing=0.7)
        result = apply_profile(config, profile)
        assert result.chase_smoothing == 0.7

    def test_tease_ratio_maintained(self):
        config = EngineConfig(chase_smoothing=0.5, tease_smoothing=0.3)
        profile = CatProfile(preferred_smoothing=0.8)
        result = apply_profile(config, profile)
        original_ratio = config.tease_smoothing / config.chase_smoothing
        assert _close(result.tease_smoothing, 0.8 * original_ratio)

    def test_lure_parameters_unchanged(self):
        config = EngineConfig()
        profile = CatProfile(preferred_speed=2.0, preferred_smoothing=0.9)
        result = apply_profile(config, profile)
        assert result.lure_max_speed == config.lure_max_speed
        assert result.lure_smoothing == config.lure_smoothing

    def test_cooldown_parameters_unchanged(self):
        config = EngineConfig()
        profile = CatProfile(preferred_speed=2.0, preferred_smoothing=0.9)
        result = apply_profile(config, profile)
        assert result.cooldown_max_speed == config.cooldown_max_speed
        assert result.cooldown_smoothing == config.cooldown_smoothing

    def test_session_timeout_unchanged(self):
        config = EngineConfig()
        profile = CatProfile(preferred_speed=2.0)
        result = apply_profile(config, profile)
        assert result.session_timeout == config.session_timeout

    def test_engagement_config_unchanged(self):
        config = EngineConfig()
        profile = CatProfile(preferred_speed=2.0, preferred_smoothing=0.9)
        result = apply_profile(config, profile)
        assert result.engagement == config.engagement


# ---------------------------------------------------------------------------
# SQLite persistence
# ---------------------------------------------------------------------------


class TestProfilePersistence:
    def test_load_default_profile(self, conn: sqlite3.Connection):
        _insert_cat(conn)
        profile = load_profile(conn, "cat-1")
        assert profile.preferred_speed == 1.0
        assert profile.preferred_smoothing == 0.5
        assert profile.pattern_randomness == 0.5

    def test_save_and_load_round_trip(self, conn: sqlite3.Connection):
        _insert_cat(conn)
        profile = CatProfile(
            preferred_speed=1.35,
            preferred_smoothing=0.72,
            pattern_randomness=0.61,
        )
        save_profile(conn, "cat-1", profile)
        loaded = load_profile(conn, "cat-1")
        assert _close(loaded.preferred_speed, 1.35)
        assert _close(loaded.preferred_smoothing, 0.72)
        assert _close(loaded.pattern_randomness, 0.61)

    def test_save_updates_timestamp(self, conn: sqlite3.Connection):
        _insert_cat(conn)
        before: int = conn.execute(
            "SELECT updated_at FROM cats WHERE cat_id = ?",
            ("cat-1",),
        ).fetchone()[0]
        save_profile(conn, "cat-1", CatProfile(preferred_speed=1.5))
        after: int = conn.execute(
            "SELECT updated_at FROM cats WHERE cat_id = ?",
            ("cat-1",),
        ).fetchone()[0]
        assert after >= before

    def test_load_nonexistent_cat_raises(self, conn: sqlite3.Connection):
        with pytest.raises(LookupError, match="not found"):
            load_profile(conn, "nonexistent")

    def test_load_custom_profile(self, conn: sqlite3.Connection):
        _insert_cat(
            conn,
            preferred_speed=1.8,
            preferred_smoothing=0.3,
            pattern_randomness=0.9,
        )
        profile = load_profile(conn, "cat-1")
        assert _close(profile.preferred_speed, 1.8)
        assert _close(profile.preferred_smoothing, 0.3)
        assert _close(profile.pattern_randomness, 0.9)


# ---------------------------------------------------------------------------
# Engine integration
# ---------------------------------------------------------------------------


class TestEngineIntegration:
    def test_profile_affects_chase_command(self):
        profile = CatProfile(preferred_speed=1.5, preferred_smoothing=0.7)
        e = _engine()
        e.start_session(1, ChuteSide.LEFT, 0.0, profile=profile)
        t = _FAST_CONFIG.lure_min_duration + 0.1
        output = e.update(_engaged_cat(), t)
        assert e.state is State.CHASE
        cmd = output.command
        assert _close(cmd.max_speed, _FAST_CONFIG.chase_max_speed * 1.5)
        assert cmd.smoothing == 0.7

    def test_profile_affects_tease_command(self):
        profile = CatProfile(preferred_speed=1.5, preferred_smoothing=0.7)
        e = _engine()
        e.start_session(1, ChuteSide.LEFT, 0.0, profile=profile)
        t = _FAST_CONFIG.lure_min_duration + 0.1
        e.update(_engaged_cat(), t)
        assert e.state is State.CHASE
        t += _FAST_CONFIG.chase_tease_interval_min + 0.1
        output = e.update(_engaged_cat(), t)
        assert e.state is State.TEASE
        cmd = output.command
        assert _close(cmd.max_speed, _FAST_CONFIG.tease_max_speed * 1.5)
        tease_ratio = _FAST_CONFIG.tease_smoothing / _FAST_CONFIG.chase_smoothing
        assert _close(cmd.smoothing, 0.7 * tease_ratio)

    def test_no_profile_uses_base_config(self):
        e = _engine()
        e.start_session(1, ChuteSide.LEFT, 0.0)
        t = _FAST_CONFIG.lure_min_duration + 0.1
        output = e.update(_engaged_cat(), t)
        assert e.state is State.CHASE
        cmd = output.command
        assert cmd.max_speed == _FAST_CONFIG.chase_max_speed
        assert cmd.smoothing == _FAST_CONFIG.chase_smoothing

    def test_config_resets_after_session(self):
        profile = CatProfile(preferred_speed=2.0, preferred_smoothing=0.9)
        cfg = _FAST_CONFIG
        e = _engine(config=cfg)
        # First session with profile.
        t = 0.0
        e.start_session(1, ChuteSide.LEFT, t, profile=profile)
        t += cfg.lure_min_duration + 0.1
        e.update(_engaged_cat(), t)
        e.stop_session(t)
        t += cfg.cooldown_timeout + 0.1
        e.update(None, t)
        t += cfg.dispense_duration + 0.1
        output = e.update(None, t)
        assert e.state is State.IDLE
        assert output.session_ended is not None
        # Second session without profile -- base config restored.
        t += 1.0
        e.start_session(2, ChuteSide.RIGHT, t)
        t += cfg.lure_min_duration + 0.1
        output = e.update(_engaged_cat(), t)
        assert e.state is State.CHASE
        cmd = output.command
        assert cmd.max_speed == cfg.chase_max_speed
        assert cmd.smoothing == cfg.chase_smoothing

    def test_lure_command_unaffected_by_profile(self):
        profile = CatProfile(preferred_speed=2.0, preferred_smoothing=0.9)
        e = _engine()
        output = e.start_session(1, ChuteSide.LEFT, 0.0, profile=profile)
        cmd = output.command
        assert cmd.smoothing == _FAST_CONFIG.lure_smoothing
        assert cmd.max_speed == _FAST_CONFIG.lure_max_speed
