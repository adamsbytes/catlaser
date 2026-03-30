"""Engagement tracking for play sessions.

Tracks cat velocity, pounce events, and time-on-target to produce a
real-time engagement signal and end-of-session scoring. The tracker is
pure: time is injected via ``dt``, no I/O, no database access.
"""

from __future__ import annotations

import dataclasses


@dataclasses.dataclass(frozen=True, slots=True)
class EngagementConfig:
    """Tuning parameters for engagement tracking and scoring.

    Extracted from the behavior engine so that per-cat profile adaptation
    can override engagement thresholds independently of state machine
    timing parameters.
    """

    # -- Pounce detection --
    pounce_velocity_threshold: float = 0.15
    pounce_reset_factor: float = 0.5

    # -- Time-on-target --
    on_target_velocity_threshold: float = 0.03

    # -- Velocity EMA --
    velocity_ema_alpha: float = 0.1

    # -- Scoring normalization --
    velocity_normalization: float = 0.2
    pounce_rate_normalization: float = 0.1

    # -- Scoring weights --
    velocity_weight: float = 0.4
    pounce_weight: float = 0.3
    time_on_target_weight: float = 0.3

    # -- Tier thresholds --
    tier_low_threshold: float = 0.33
    tier_high_threshold: float = 0.66


@dataclasses.dataclass(frozen=True, slots=True)
class EngagementSnapshot:
    """Frozen snapshot of engagement metrics at a point in time.

    Produced by ``EngagementTracker.snapshot()`` for session results and
    per-cat profile storage.
    """

    avg_velocity: float
    velocity_ema: float
    pounce_count: int
    pounce_rate: float
    time_on_target: float
    active_time: float
    score: float
    tier: int


class EngagementTracker:
    """Accumulates engagement metrics from per-frame cat speed observations.

    Tracks three independent signals:

    **Velocity** -- cumulative average for end-of-session scoring, plus an
    exponential moving average for real-time engagement level.

    **Pounce detection** -- rising-edge state machine with hysteresis.
    A pounce is counted when speed crosses *above* the velocity threshold.
    The speed must then drop below ``threshold * reset_factor`` before
    another pounce can be counted, preventing a single sustained burst
    from registering as multiple events.

    **Time-on-target** -- fraction of active play time during which the
    cat's speed exceeds a minimum engagement threshold, distinguishing
    active chasing from idle presence in frame.

    Args:
        config: Engagement tracking parameters and scoring weights.
    """

    __slots__ = (
        "_active_frames",
        "_active_time",
        "_config",
        "_on_target_time",
        "_pounce_count",
        "_pouncing",
        "_velocity_ema",
        "_velocity_sum",
    )

    def __init__(self, config: EngagementConfig) -> None:
        self._config = config
        self._velocity_sum = 0.0
        self._velocity_ema = 0.0
        self._pounce_count = 0
        self._pouncing = False
        self._active_frames = 0
        self._active_time = 0.0
        self._on_target_time = 0.0

    def update(self, speed: float, dt: float) -> None:
        """Process one frame of cat speed data.

        Args:
            speed: Cat speed in normalized units per second
                (``math.hypot(velocity_x, velocity_y)``).
            dt: Time elapsed since the previous update, in seconds.
        """
        cfg = self._config

        self._velocity_sum += speed
        self._active_frames += 1
        self._active_time += dt

        if self._active_frames == 1:
            self._velocity_ema = speed
        else:
            alpha = cfg.velocity_ema_alpha
            self._velocity_ema = alpha * speed + (1.0 - alpha) * self._velocity_ema

        if self._pouncing:
            if speed < cfg.pounce_velocity_threshold * cfg.pounce_reset_factor:
                self._pouncing = False
        elif speed >= cfg.pounce_velocity_threshold:
            self._pounce_count += 1
            self._pouncing = True

        if speed >= cfg.on_target_velocity_threshold:
            self._on_target_time += dt

    @property
    def avg_velocity(self) -> float:
        """Session average cat speed (normalized units/sec)."""
        if self._active_frames == 0:
            return 0.0
        return self._velocity_sum / self._active_frames

    @property
    def velocity_ema(self) -> float:
        """Exponential moving average of cat speed for real-time signal."""
        return self._velocity_ema

    @property
    def pounce_count(self) -> int:
        """Number of discrete pounce events detected this session."""
        return self._pounce_count

    @property
    def pounce_rate(self) -> float:
        """Pounces per second over active play time."""
        if self._active_time < 1.0:
            return 0.0
        return self._pounce_count / self._active_time

    @property
    def time_on_target(self) -> float:
        """Fraction of active time spent actively chasing (0.0--1.0)."""
        if self._active_time <= 0.0:
            return 0.0
        return self._on_target_time / self._active_time

    @property
    def active_time(self) -> float:
        """Total time in seconds spent in engagement-tracked states."""
        return self._active_time

    @property
    def score(self) -> float:
        """Composite engagement score (0.0--1.0).

        Weighted combination of normalized velocity, pounce rate, and
        time-on-target. Returns 0.0 if insufficient data has been
        accumulated (fewer than 1 second of active time).
        """
        cfg = self._config
        if self._active_frames == 0 or self._active_time < 1.0:
            return 0.0

        vel_score = min(self.avg_velocity / cfg.velocity_normalization, 1.0)
        pounce_score = min(self.pounce_rate / cfg.pounce_rate_normalization, 1.0)
        tot_score = self.time_on_target

        return (
            cfg.velocity_weight * vel_score
            + cfg.pounce_weight * pounce_score
            + cfg.time_on_target_weight * tot_score
        )

    @property
    def tier(self) -> int:
        """Dispense tier (0, 1, or 2) derived from the engagement score."""
        s = self.score
        cfg = self._config
        if s >= cfg.tier_high_threshold:
            return 2
        if s >= cfg.tier_low_threshold:
            return 1
        return 0

    def snapshot(self) -> EngagementSnapshot:
        """Capture a frozen snapshot of all current metrics."""
        return EngagementSnapshot(
            avg_velocity=self.avg_velocity,
            velocity_ema=self.velocity_ema,
            pounce_count=self.pounce_count,
            pounce_rate=self.pounce_rate,
            time_on_target=self.time_on_target,
            active_time=self.active_time,
            score=self.score,
            tier=self.tier,
        )
