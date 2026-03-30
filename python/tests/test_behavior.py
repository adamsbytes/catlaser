"""Tests for the behavior engine state machine."""

from __future__ import annotations

import random

import pytest

from catlaser_brain.behavior.engagement import EngagementConfig
from catlaser_brain.behavior.profile import CatProfile
from catlaser_brain.behavior.state_machine import (
    DISPENSE_ROTATIONS,
    BehaviorEngine,
    CatObservation,
    ChuteSide,
    EngineConfig,
    EngineOutput,
    SessionResult,
    State,
    TargetingMode,
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Config with deterministic (non-random) tease/duration intervals and short
# durations so tests don't need large time jumps.
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
    """Cat with velocity above the default engagement threshold."""
    return _cat(vx=0.1, vy=0.0)


def _fast_cat() -> CatObservation:
    """Cat with velocity above the default pounce threshold."""
    return _cat(vx=0.2, vy=0.15)


def _advance(
    engine: BehaviorEngine,
    cat: CatObservation | None,
    start: float,
    duration: float,
    fps: float = 15.0,
) -> EngineOutput:
    """Advance the engine through *duration* seconds at given fps."""
    dt = 1.0 / fps
    t = start
    end = start + duration
    output = engine.update(cat, t)
    while t + dt <= end:
        t += dt
        output = engine.update(cat, t)
    return output


def _run_to_chase(engine: BehaviorEngine, t: float = 0.0) -> float:
    """Start a session and advance past LURE into CHASE. Returns current time."""
    engine.start_session(1, ChuteSide.LEFT, t)
    # Advance past lure_min_duration with an engaged cat.
    t += _FAST_CONFIG.lure_min_duration + 0.1
    engine.update(_engaged_cat(), t)
    assert engine.state is State.CHASE
    return t


def _run_to_cooldown(engine: BehaviorEngine, t: float = 0.0) -> float:
    """Run to CHASE then trigger stop_session to get to COOLDOWN."""
    t = _run_to_chase(engine, t)
    engine.stop_session(t)
    assert engine.state is State.COOLDOWN
    return t


def _run_to_dispense(engine: BehaviorEngine, t: float = 0.0) -> float:
    """Run to COOLDOWN then advance past cooldown_timeout to DISPENSE."""
    t = _run_to_cooldown(engine, t)
    t += _FAST_CONFIG.cooldown_timeout + 0.1
    engine.update(None, t)
    assert engine.state is State.DISPENSE
    return t


# ---------------------------------------------------------------------------
# Start session
# ---------------------------------------------------------------------------


class TestStartSession:
    def test_transitions_to_lure(self):
        e = _engine()
        output = e.start_session(1, ChuteSide.LEFT, 0.0)
        assert e.state is State.LURE
        assert output.command.mode is TargetingMode.TRACK
        assert output.command.laser_on is True
        assert output.session_ended is None

    def test_stores_target_track_id(self):
        e = _engine()
        e.start_session(42, ChuteSide.RIGHT, 0.0)
        assert e.target_track_id == 42
        assert e.state is State.LURE

    def test_raises_if_session_active(self):
        e = _engine()
        e.start_session(1, ChuteSide.LEFT, 0.0)
        with pytest.raises(RuntimeError, match="cannot start session"):
            e.start_session(2, ChuteSide.RIGHT, 1.0)

    def test_lure_command_parameters(self):
        e = _engine()
        output = e.start_session(7, ChuteSide.LEFT, 0.0)
        cmd = output.command
        assert cmd.smoothing == _FAST_CONFIG.lure_smoothing
        assert cmd.max_speed == _FAST_CONFIG.lure_max_speed
        assert cmd.target_track_id == 7


# ---------------------------------------------------------------------------
# Lure transitions
# ---------------------------------------------------------------------------


class TestLureTransitions:
    def test_to_chase_on_engagement(self):
        e = _engine()
        e.start_session(1, ChuteSide.LEFT, 0.0)
        # Before min duration: no transition even with engagement.
        e.update(_engaged_cat(), 0.5)
        assert e.state is State.LURE
        # After min duration with engaged cat: transition.
        t = _FAST_CONFIG.lure_min_duration + 0.1
        e.update(_engaged_cat(), t)
        assert e.state is State.CHASE

    def test_no_transition_below_velocity_threshold(self):
        e = _engine()
        e.start_session(1, ChuteSide.LEFT, 0.0)
        slow_cat = _cat(vx=0.01, vy=0.0)
        t = _FAST_CONFIG.lure_min_duration + 0.1
        e.update(slow_cat, t)
        assert e.state is State.LURE

    def test_to_chase_on_max_duration(self):
        e = _engine()
        e.start_session(1, ChuteSide.LEFT, 0.0)
        # Advance past max lure with a stationary cat.
        t = _FAST_CONFIG.lure_max_duration + 0.1
        e.update(_cat(), t)
        assert e.state is State.CHASE

    def test_no_transition_without_cat(self):
        e = _engine()
        e.start_session(1, ChuteSide.LEFT, 0.0)
        # After min duration but no cat observation.
        t = _FAST_CONFIG.lure_min_duration + 0.1
        e.update(None, t)
        assert e.state is State.LURE

    def test_engagement_requires_min_duration(self):
        e = _engine()
        e.start_session(1, ChuteSide.LEFT, 0.0)
        # Fast cat but before min duration.
        e.update(_fast_cat(), 0.5)
        assert e.state is State.LURE


# ---------------------------------------------------------------------------
# Chase transitions
# ---------------------------------------------------------------------------


class TestChaseTransitions:
    def test_to_tease_after_interval(self):
        e = _engine()
        t = _run_to_chase(e)
        # Advance past chase_min_before_tease + tease interval.
        t += _FAST_CONFIG.chase_tease_interval_min + 0.1
        e.update(_engaged_cat(), t)
        assert e.state is State.TEASE

    def test_no_tease_before_min_chase(self):
        e = _engine()
        t = _run_to_chase(e)
        # The tease interval (3.0) > min_before_tease (2.0), but verify
        # that at exactly min_before_tease we haven't transitioned yet
        # (the interval hasn't elapsed).
        t += _FAST_CONFIG.chase_min_before_tease
        e.update(_engaged_cat(), t)
        # With interval=3.0 and min=2.0, at t+2.0 we haven't reached interval.
        assert e.state is State.CHASE

    def test_chase_command_parameters(self):
        e = _engine()
        t = _run_to_chase(e)
        output = e.update(_engaged_cat(), t + 0.1)
        cmd = output.command
        assert cmd.mode is TargetingMode.TRACK
        assert cmd.smoothing == _FAST_CONFIG.chase_smoothing
        assert cmd.max_speed == _FAST_CONFIG.chase_max_speed
        assert cmd.laser_on is True
        assert cmd.target_track_id == 1


# ---------------------------------------------------------------------------
# Tease transitions
# ---------------------------------------------------------------------------


class TestTeaseTransitions:
    def test_to_chase_after_duration(self):
        e = _engine()
        t = _run_to_chase(e)
        # Advance to trigger tease.
        t += _FAST_CONFIG.chase_tease_interval_min + 0.1
        e.update(_engaged_cat(), t)
        assert e.state is State.TEASE
        # Advance past tease duration.
        t += _FAST_CONFIG.tease_duration_max + 0.1
        e.update(_engaged_cat(), t)
        assert e.state is State.CHASE

    def test_tease_command_parameters(self):
        e = _engine()
        t = _run_to_chase(e)
        t += _FAST_CONFIG.chase_tease_interval_min + 0.1
        output = e.update(_engaged_cat(), t)
        assert e.state is State.TEASE
        cmd = output.command
        assert cmd.mode is TargetingMode.TRACK
        assert cmd.smoothing == _FAST_CONFIG.tease_smoothing
        assert cmd.max_speed == _FAST_CONFIG.tease_max_speed
        assert cmd.laser_on is True

    def test_multiple_chase_tease_cycles(self):
        e = _engine()
        t = _run_to_chase(e)
        for _ in range(3):
            # Chase → Tease.
            t += _FAST_CONFIG.chase_tease_interval_min + 0.1
            e.update(_engaged_cat(), t)
            assert e.state is State.TEASE
            # Tease → Chase.
            t += _FAST_CONFIG.tease_duration_max + 0.1
            e.update(_engaged_cat(), t)
            assert e.state is State.CHASE


# ---------------------------------------------------------------------------
# Session timeout
# ---------------------------------------------------------------------------


class TestSessionTimeout:
    def test_chase_to_cooldown_on_timeout(self):
        e = _engine()
        t = _run_to_chase(e)
        t = _FAST_CONFIG.session_timeout + 0.1
        e.update(_engaged_cat(), t)
        assert e.state is State.COOLDOWN

    def test_lure_to_cooldown_on_timeout(self):
        e = _engine()
        e.start_session(1, ChuteSide.LEFT, 0.0)
        # Don't trigger engagement; wait for session timeout.
        t = _FAST_CONFIG.session_timeout + 0.1
        e.update(None, t)
        assert e.state is State.COOLDOWN

    def test_tease_to_cooldown_on_timeout(self):
        e = _engine()
        t = _run_to_chase(e)
        # Get into tease.
        t += _FAST_CONFIG.chase_tease_interval_min + 0.1
        e.update(_engaged_cat(), t)
        assert e.state is State.TEASE
        # Jump to session timeout.
        t = _FAST_CONFIG.session_timeout + 0.1
        e.update(_engaged_cat(), t)
        assert e.state is State.COOLDOWN


# ---------------------------------------------------------------------------
# Stop session
# ---------------------------------------------------------------------------


class TestStopSession:
    def test_from_chase(self):
        e = _engine()
        t = _run_to_chase(e)
        output = e.stop_session(t)
        assert e.state is State.COOLDOWN
        assert output.command.mode is TargetingMode.LEAD_TO_POINT
        assert output.command.laser_on is True

    def test_from_lure(self):
        e = _engine()
        e.start_session(1, ChuteSide.LEFT, 0.0)
        e.stop_session(1.0)
        assert e.state is State.COOLDOWN

    def test_from_tease(self):
        e = _engine()
        t = _run_to_chase(e)
        t += _FAST_CONFIG.chase_tease_interval_min + 0.1
        e.update(_engaged_cat(), t)
        assert e.state is State.TEASE
        e.stop_session(t)
        assert e.state is State.COOLDOWN

    def test_noop_from_cooldown(self):
        e = _engine()
        t = _run_to_cooldown(e)
        e.stop_session(t + 1.0)
        assert e.state is State.COOLDOWN

    def test_noop_from_dispense(self):
        e = _engine()
        t = _run_to_dispense(e)
        e.stop_session(t + 0.5)
        assert e.state is State.DISPENSE

    def test_noop_from_idle(self):
        e = _engine()
        output = e.stop_session(0.0)
        assert e.state is State.IDLE
        assert output.command.mode is TargetingMode.IDLE


# ---------------------------------------------------------------------------
# Track loss
# ---------------------------------------------------------------------------


class TestTrackLoss:
    def test_target_lost_from_chase(self):
        e = _engine()
        t = _run_to_chase(e)
        e.on_track_lost(1, t)
        assert e.state is State.COOLDOWN

    def test_target_lost_from_lure(self):
        e = _engine()
        e.start_session(1, ChuteSide.LEFT, 0.0)
        e.on_track_lost(1, 1.0)
        assert e.state is State.COOLDOWN

    def test_non_target_track_ignored(self):
        e = _engine()
        t = _run_to_chase(e)
        e.on_track_lost(999, t)
        assert e.state is State.CHASE

    def test_track_lost_from_cooldown_noop(self):
        e = _engine()
        t = _run_to_cooldown(e)
        e.on_track_lost(1, t + 1.0)
        assert e.state is State.COOLDOWN

    def test_track_lost_from_dispense_noop(self):
        e = _engine()
        t = _run_to_dispense(e)
        e.on_track_lost(1, t + 0.5)
        assert e.state is State.DISPENSE

    def test_absence_timeout_triggers_cooldown(self):
        e = _engine()
        t = _run_to_chase(e)
        # Cat disappears from frames.
        t += 0.1
        e.update(None, t)
        assert e.state is State.CHASE
        # Advance past track_lost_timeout.
        t += _FAST_CONFIG.track_lost_timeout + 0.1
        e.update(None, t)
        assert e.state is State.COOLDOWN

    def test_absence_timeout_resets_on_cat_return(self):
        # Use a config where tease won't fire during this test.
        cfg = EngineConfig(
            lure_min_duration=1.0,
            lure_engagement_velocity=0.05,
            chase_tease_interval_min=100.0,
            chase_tease_interval_max=100.0,
            track_lost_timeout=2.0,
            session_timeout=60.0,
        )
        e = _engine(config=cfg)
        e.start_session(1, ChuteSide.LEFT, 0.0)
        t = cfg.lure_min_duration + 0.1
        e.update(_engaged_cat(), t)
        assert e.state is State.CHASE
        # Cat disappears.
        t += 0.1
        e.update(None, t)
        # Cat returns before timeout.
        t += cfg.track_lost_timeout - 0.5
        e.update(_engaged_cat(), t)
        assert e.state is State.CHASE
        # Now disappears again: timeout counts from NEW disappearance.
        t += 0.1
        e.update(None, t)
        t += cfg.track_lost_timeout - 0.5
        e.update(None, t)
        assert e.state is State.CHASE


# ---------------------------------------------------------------------------
# Cooldown transitions
# ---------------------------------------------------------------------------


class TestCooldownTransitions:
    def test_to_dispense_on_timeout(self):
        e = _engine()
        t = _run_to_cooldown(e)
        t += _FAST_CONFIG.cooldown_timeout + 0.1
        e.update(None, t)
        assert e.state is State.DISPENSE

    def test_to_dispense_on_cat_arrival(self):
        cfg = _FAST_CONFIG
        e = _engine(config=cfg)
        t = _run_to_cooldown(e)
        # Cat arrives near the left chute target.
        near_chute = _cat(
            cx=cfg.chute_left_x,
            cy=cfg.chute_left_y,
        )
        t += 0.1
        e.update(near_chute, t)
        assert e.state is State.DISPENSE

    def test_cooldown_command_has_lead_target(self):
        cfg = _FAST_CONFIG
        e = _engine(config=cfg)
        t = _run_to_cooldown(e)
        output = e.update(None, t + 0.1)
        cmd = output.command
        assert cmd.mode is TargetingMode.LEAD_TO_POINT
        assert cmd.lead_target_x == cfg.chute_left_x
        assert cmd.lead_target_y == cfg.chute_left_y
        assert cmd.laser_on is True

    def test_no_dispense_if_cat_far_from_chute(self):
        e = _engine()
        t = _run_to_cooldown(e)
        # Cat is far from chute.
        far_cat = _cat(cx=0.1, cy=0.1)
        t += 0.1
        e.update(far_cat, t)
        assert e.state is State.COOLDOWN


# ---------------------------------------------------------------------------
# Dispense transitions
# ---------------------------------------------------------------------------


class TestDispenseTransitions:
    def test_to_idle_after_duration(self):
        e = _engine()
        t = _run_to_dispense(e)
        t += _FAST_CONFIG.dispense_duration + 0.1
        output = e.update(None, t)
        assert e.state is State.IDLE
        assert output.session_ended is not None

    def test_dispense_command(self):
        cfg = _FAST_CONFIG
        e = _engine(config=cfg)
        t = _run_to_dispense(e)
        output = e.update(None, t + 0.1)
        cmd = output.command
        assert cmd.mode is TargetingMode.DISPENSE
        assert cmd.laser_on is False
        assert cmd.dispense_rotations in (3, 5, 7)
        assert cmd.lead_target_x == cfg.chute_left_x
        assert cmd.lead_target_y == cfg.chute_left_y

    def test_dispense_command_right_chute(self):
        cfg = _FAST_CONFIG
        e = _engine(config=cfg)
        e.start_session(1, ChuteSide.RIGHT, 0.0)
        t = cfg.lure_min_duration + 0.1
        e.update(_engaged_cat(), t)
        assert e.state is State.CHASE
        e.stop_session(t)
        assert e.state is State.COOLDOWN
        t += cfg.cooldown_timeout + 0.1
        e.update(None, t)
        assert e.state is State.DISPENSE
        output = e.update(None, t + 0.1)
        cmd = output.command
        assert cmd.mode is TargetingMode.DISPENSE
        assert cmd.lead_target_x == cfg.chute_right_x
        assert cmd.lead_target_y == cfg.chute_right_y

    def test_session_ended_only_on_final_transition(self):
        e = _engine()
        t = _run_to_dispense(e)
        # Mid-dispense: no session_ended.
        output = e.update(None, t + 0.1)
        assert output.session_ended is None
        # After duration: session_ended present.
        t += _FAST_CONFIG.dispense_duration + 0.1
        output = e.update(None, t)
        assert output.session_ended is not None

    def test_session_result_fields(self):
        e = _engine()
        t = _run_to_dispense(e)
        t += _FAST_CONFIG.dispense_duration + 0.1
        output = e.update(None, t)
        result = output.session_ended
        assert result is not None
        assert isinstance(result, SessionResult)
        assert result.dispense_tier in (0, 1, 2)
        assert result.dispense_rotations == DISPENSE_ROTATIONS[result.dispense_tier]
        assert result.engagement_score >= 0.0
        assert result.active_play_time >= 0.0
        assert result.avg_velocity >= 0.0
        assert result.pounce_count >= 0
        assert result.pounce_rate >= 0.0
        assert 0.0 <= result.time_on_target <= 1.0


# ---------------------------------------------------------------------------
# Idle behavior
# ---------------------------------------------------------------------------


class TestIdleBehavior:
    def test_update_returns_idle(self):
        e = _engine()
        output = e.update(_engaged_cat(), 1.0)
        assert output.command.mode is TargetingMode.IDLE
        assert output.command.laser_on is False
        assert output.session_ended is None

    def test_idle_after_session_completes(self):
        e = _engine()
        t = _run_to_dispense(e)
        t += _FAST_CONFIG.dispense_duration + 0.1
        e.update(None, t)
        assert e.state is State.IDLE
        assert e.target_track_id == 0

    def test_can_start_new_session_after_completion(self):
        e = _engine()
        t = _run_to_dispense(e)
        t += _FAST_CONFIG.dispense_duration + 0.1
        e.update(None, t)
        assert e.state is State.IDLE
        # Start a fresh session.
        t += 1.0
        e.start_session(99, ChuteSide.RIGHT, t)
        assert e.state is State.LURE
        assert e.target_track_id == 99


# ---------------------------------------------------------------------------
# Chute side
# ---------------------------------------------------------------------------


class TestChuteSide:
    def test_left_chute_target(self):
        cfg = _FAST_CONFIG
        e = _engine(config=cfg)
        e.start_session(1, ChuteSide.LEFT, 0.0)
        e.stop_session(1.0)
        output = e.update(None, 1.1)
        assert output.command.lead_target_x == cfg.chute_left_x
        assert output.command.lead_target_y == cfg.chute_left_y

    def test_right_chute_target(self):
        cfg = _FAST_CONFIG
        e = _engine(config=cfg)
        e.start_session(1, ChuteSide.RIGHT, 0.0)
        e.stop_session(1.0)
        output = e.update(None, 1.1)
        assert output.command.lead_target_x == cfg.chute_right_x
        assert output.command.lead_target_y == cfg.chute_right_y


# ---------------------------------------------------------------------------
# Engagement and dispense tiers
# ---------------------------------------------------------------------------


class TestEngagement:
    def test_no_engagement_gives_tier_zero(self):
        e = _engine()
        # Go through lure → cooldown → dispense without any chase frames.
        e.start_session(1, ChuteSide.LEFT, 0.0)
        e.stop_session(0.5)
        assert e.state is State.COOLDOWN
        t = 0.5 + _FAST_CONFIG.cooldown_timeout + 0.1
        e.update(None, t)
        assert e.state is State.DISPENSE
        t += _FAST_CONFIG.dispense_duration + 0.1
        output = e.update(None, t)
        result = output.session_ended
        assert result is not None
        assert result.dispense_tier == 0
        assert result.dispense_rotations == 3

    def test_low_engagement_gives_tier_zero(self):
        cfg = EngineConfig(
            lure_min_duration=0.0,
            lure_engagement_velocity=0.0,
            chase_tease_interval_min=100.0,
            chase_tease_interval_max=100.0,
            cooldown_timeout=1.0,
            dispense_duration=0.5,
            session_timeout=60.0,
            track_lost_timeout=10.0,
            engagement=EngagementConfig(
                velocity_normalization=0.2,
                pounce_velocity_threshold=0.15,
            ),
        )
        e = _engine(config=cfg)
        e.start_session(1, ChuteSide.LEFT, 0.0)
        # Trigger lure → chase.
        e.update(_cat(vx=0.01), 0.1)
        assert e.state is State.CHASE
        # Simulate low-velocity chase frames for 2 seconds.
        slow = _cat(vx=0.02, vy=0.0)
        _advance(e, slow, 0.2, 2.0)
        e.stop_session(2.5)
        # Run through cooldown + dispense.
        t = 2.5 + cfg.cooldown_timeout + 0.1
        e.update(None, t)
        t += cfg.dispense_duration + 0.1
        output = e.update(None, t)
        result = output.session_ended
        assert result is not None
        assert result.dispense_tier == 0
        assert result.dispense_rotations == 3

    def test_high_engagement_gives_tier_two(self):
        cfg = EngineConfig(
            lure_min_duration=0.0,
            lure_engagement_velocity=0.0,
            chase_tease_interval_min=100.0,
            chase_tease_interval_max=100.0,
            cooldown_timeout=1.0,
            dispense_duration=0.5,
            session_timeout=60.0,
            track_lost_timeout=10.0,
            engagement=EngagementConfig(
                velocity_normalization=0.2,
                pounce_velocity_threshold=0.15,
                pounce_rate_normalization=1.0,
            ),
        )
        e = _engine(config=cfg)
        e.start_session(1, ChuteSide.LEFT, 0.0)
        e.update(_cat(vx=0.1), 0.1)
        assert e.state is State.CHASE
        # Simulate high-velocity chase frames with pounces.
        fast = _cat(vx=0.3, vy=0.2)
        _advance(e, fast, 0.2, 5.0)
        e.stop_session(5.5)
        t = 5.5 + cfg.cooldown_timeout + 0.1
        e.update(None, t)
        t += cfg.dispense_duration + 0.1
        output = e.update(None, t)
        result = output.session_ended
        assert result is not None
        assert result.dispense_tier == 2
        assert result.dispense_rotations == 7

    def test_medium_engagement_gives_tier_one(self):
        cfg = EngineConfig(
            lure_min_duration=0.0,
            lure_engagement_velocity=0.0,
            chase_tease_interval_min=100.0,
            chase_tease_interval_max=100.0,
            cooldown_timeout=1.0,
            dispense_duration=0.5,
            session_timeout=60.0,
            track_lost_timeout=10.0,
            engagement=EngagementConfig(
                velocity_normalization=0.2,
                pounce_velocity_threshold=0.15,
                pounce_rate_normalization=1.0,
            ),
        )
        e = _engine(config=cfg)
        e.start_session(1, ChuteSide.LEFT, 0.0)
        e.update(_cat(vx=0.1), 0.1)
        assert e.state is State.CHASE
        # vel: 0.12/0.2 = 0.6 * 0.4 = 0.24
        # pounce: 0.12 < 0.15, no pounces = 0
        # time_on_target: 0.12 > 0.03, ratio 1.0 * 0.3 = 0.30
        # total = 0.54, clears tier_low (0.33) but not tier_high (0.66)
        moderate = _cat(vx=0.12, vy=0.0)
        _advance(e, moderate, 0.2, 5.0)
        e.stop_session(5.5)
        t = 5.5 + cfg.cooldown_timeout + 0.1
        e.update(None, t)
        t += cfg.dispense_duration + 0.1
        output = e.update(None, t)
        result = output.session_ended
        assert result is not None
        assert result.dispense_tier == 1
        assert result.dispense_rotations == 5

    def test_engagement_not_tracked_during_lure(self):
        cfg = EngineConfig(
            lure_min_duration=5.0,
            lure_max_duration=10.0,
            lure_engagement_velocity=100.0,
            cooldown_timeout=1.0,
            dispense_duration=0.5,
            session_timeout=60.0,
            track_lost_timeout=10.0,
        )
        e = _engine(config=cfg)
        e.start_session(1, ChuteSide.LEFT, 0.0)
        # High-velocity cat during lure (engagement_velocity set impossibly
        # high so we stay in lure).
        fast = _cat(vx=0.5, vy=0.5)
        _advance(e, fast, 0.1, 4.0)
        assert e.state is State.LURE
        e.stop_session(4.5)
        # Complete session.
        t = 4.5 + cfg.cooldown_timeout + 0.1
        e.update(None, t)
        t += cfg.dispense_duration + 0.1
        output = e.update(None, t)
        result = output.session_ended
        assert result is not None
        # No engagement was tracked during lure.
        assert result.active_play_time == 0.0
        assert result.engagement_score == 0.0
        assert result.avg_velocity == 0.0
        assert result.pounce_count == 0
        assert result.time_on_target == 0.0

    def test_engagement_score_bounded_zero_to_one(self):
        cfg = EngineConfig(
            lure_min_duration=0.0,
            lure_engagement_velocity=0.0,
            chase_tease_interval_min=100.0,
            chase_tease_interval_max=100.0,
            cooldown_timeout=1.0,
            dispense_duration=0.5,
            session_timeout=60.0,
            track_lost_timeout=10.0,
        )
        e = _engine(config=cfg)
        e.start_session(1, ChuteSide.LEFT, 0.0)
        e.update(_cat(vx=0.1), 0.1)
        # Extremely fast cat: score should still be <= 1.0.
        extreme = _cat(vx=10.0, vy=10.0)
        _advance(e, extreme, 0.2, 3.0)
        e.stop_session(3.5)
        t = 3.5 + cfg.cooldown_timeout + 0.1
        e.update(None, t)
        t += cfg.dispense_duration + 0.1
        output = e.update(None, t)
        result = output.session_ended
        assert result is not None
        assert 0.0 <= result.engagement_score <= 1.0


# ---------------------------------------------------------------------------
# Full session lifecycle
# ---------------------------------------------------------------------------


class TestFullSessionLifecycle:
    def test_complete_session(self):
        """IDLE -> LURE -> CHASE -> TEASE -> CHASE -> COOLDOWN -> DISPENSE -> IDLE."""
        cfg = _FAST_CONFIG
        e = _engine(config=cfg)

        # IDLE.
        assert e.state is State.IDLE

        # Start -> LURE.
        t = 0.0
        e.start_session(1, ChuteSide.LEFT, t)
        assert e.state is State.LURE

        # Engage -> CHASE.
        t += cfg.lure_min_duration + 0.1
        e.update(_engaged_cat(), t)
        assert e.state is State.CHASE

        # Wait for tease -> TEASE.
        t += cfg.chase_tease_interval_min + 0.1
        e.update(_engaged_cat(), t)
        assert e.state is State.TEASE

        # Tease ends -> CHASE.
        t += cfg.tease_duration_max + 0.1
        e.update(_engaged_cat(), t)
        assert e.state is State.CHASE

        # Stop -> COOLDOWN.
        e.stop_session(t)
        assert e.state is State.COOLDOWN

        # Cooldown timeout -> DISPENSE.
        t += cfg.cooldown_timeout + 0.1
        e.update(None, t)
        assert e.state is State.DISPENSE

        # Dispense timeout -> IDLE with SessionResult.
        t += cfg.dispense_duration + 0.1
        output = e.update(None, t)
        assert e.state is State.IDLE
        assert output.session_ended is not None
        assert output.command.mode is TargetingMode.IDLE
        assert output.command.laser_on is False

    def test_session_ended_not_present_mid_session(self):
        e = _engine()
        e.start_session(1, ChuteSide.LEFT, 0.0)
        for t_val in [0.1, 0.5, 1.0]:
            output = e.update(_engaged_cat(), t_val)
            assert output.session_ended is None

    def test_two_consecutive_sessions(self):
        e = _engine()
        # First session.
        t = _run_to_dispense(e)
        t += _FAST_CONFIG.dispense_duration + 0.1
        output1 = e.update(None, t)
        assert output1.session_ended is not None
        assert e.state is State.IDLE

        # Second session.
        t += 1.0
        e.start_session(2, ChuteSide.RIGHT, t)
        assert e.state is State.LURE
        assert e.target_track_id == 2
        t += _FAST_CONFIG.lure_min_duration + 0.1
        e.update(_engaged_cat(), t)
        assert e.state is State.CHASE

    def test_track_lost_still_dispenses(self):
        """Even when the cat disappears, the session ends gracefully with treats."""
        e = _engine()
        t = _run_to_chase(e)
        e.on_track_lost(1, t)
        assert e.state is State.COOLDOWN
        t += _FAST_CONFIG.cooldown_timeout + 0.1
        e.update(None, t)
        assert e.state is State.DISPENSE
        t += _FAST_CONFIG.dispense_duration + 0.1
        output = e.update(None, t)
        assert output.session_ended is not None
        assert output.session_ended.dispense_rotations in (3, 5, 7)


# ---------------------------------------------------------------------------
# Pattern offsets
# ---------------------------------------------------------------------------


class TestPatternOffsets:
    def test_lure_commands_have_offsets(self):
        e = _engine()
        e.start_session(1, ChuteSide.LEFT, 0.0)
        has_offset = False
        t = 0.0
        for _ in range(30):
            t += 1.0 / 15.0
            output = e.update(_cat(), t)
            if abs(output.command.offset_x) > 1e-6 or abs(output.command.offset_y) > 1e-6:
                has_offset = True
                break
        assert has_offset

    def test_chase_leads_in_velocity_direction(self):
        e = _engine()
        t = _run_to_chase(e)
        cat = _cat(vx=0.2, vy=0.0)
        t += 1.0 / 15.0
        output = e.update(cat, t)
        assert output.command.offset_x > 0.0

    def test_cooldown_commands_zero_offsets(self):
        e = _engine()
        t = _run_to_cooldown(e)
        t += 0.1
        output = e.update(None, t)
        assert output.command.offset_x == 0.0
        assert output.command.offset_y == 0.0

    def test_dispense_commands_zero_offsets(self):
        e = _engine()
        t = _run_to_dispense(e)
        t += 0.1
        output = e.update(None, t)
        assert output.command.offset_x == 0.0
        assert output.command.offset_y == 0.0

    def test_offsets_bounded(self):
        e = _engine()
        e.start_session(1, ChuteSide.LEFT, 0.0)
        t = 0.0
        for _ in range(200):
            t += 1.0 / 15.0
            output = e.update(_engaged_cat(), t)
            assert abs(output.command.offset_x) <= 0.15
            assert abs(output.command.offset_y) <= 0.15

    def test_offsets_reset_between_sessions(self):
        e = _engine()
        t = _run_to_dispense(e)
        t += _FAST_CONFIG.dispense_duration + 0.1
        e.update(None, t)
        assert e.state is State.IDLE

        t += 1.0
        output = e.start_session(2, ChuteSide.RIGHT, t)
        assert output.command.offset_x == 0.0
        assert output.command.offset_y == 0.0

    def test_profile_randomness_affects_offsets(self):
        profile_low = CatProfile(pattern_randomness=0.0)
        profile_high = CatProfile(pattern_randomness=1.0)

        e_low = _engine()
        e_high = _engine()

        e_low.start_session(1, ChuteSide.LEFT, 0.0, profile=profile_low)
        e_high.start_session(1, ChuteSide.LEFT, 0.0, profile=profile_high)

        t = _FAST_CONFIG.lure_min_duration + 0.1
        e_low.update(_engaged_cat(), t)
        e_high.update(_engaged_cat(), t)

        offsets_low: list[tuple[float, float]] = []
        offsets_high: list[tuple[float, float]] = []
        for _ in range(100):
            t += 1.0 / 15.0
            out_low = e_low.update(_engaged_cat(), t)
            out_high = e_high.update(_engaged_cat(), t)
            offsets_low.append((out_low.command.offset_x, out_low.command.offset_y))
            offsets_high.append((out_high.command.offset_x, out_high.command.offset_y))

        assert offsets_low != offsets_high
