"""Laser movement pattern generation for behavior engine states.

Produces per-frame (offset_x, offset_y) displacements relative to the
tracked cat's center. The Rust vision daemon adds these offsets to the
cat's bbox center before computing servo angles, so all values are in
normalized frame coordinates (0.0--1.0).

Each behavior state has a distinct movement style:

**Lure** -- gentle Lissajous figure-8 to draw the cat's attention without
fast movement. Higher harmonics blend in as pattern randomness increases.

**Chase** -- velocity-aligned lead that keeps the laser ahead of the cat
plus a lateral weave perpendicular to the direction of travel. Lead
distance scales with cat speed.

**Tease** -- staccato juke pattern: pick a random direction, hold it
briefly, snap to a new one. Occasional freezes (zero offset) add
unpredictability.

Pattern randomness (0.0--1.0) comes from the per-cat profile and controls
how varied the patterns are. Low randomness produces simple, repeatable
patterns; high randomness adds complexity and unpredictability.
"""

from __future__ import annotations

import dataclasses
import math
import random
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from catlaser_brain.behavior.state_machine import CatObservation


@dataclasses.dataclass(frozen=True, slots=True)
class PatternConfig:
    """Tuning parameters for laser movement patterns.

    All amplitudes and distances are in normalized frame coordinates
    (0.0--1.0). Rates are in radians per second. Durations in seconds.
    """

    # -- Lure (figure-8 Lissajous) --
    lure_amplitude: float = 0.06
    lure_phase_rate: float = 0.8

    # -- Chase (velocity lead + lateral weave) --
    chase_lead_scale: float = 0.5
    chase_lead_max: float = 0.12
    chase_lateral_amplitude: float = 0.03
    chase_lateral_rate: float = 1.5

    # -- Tease (staccato juke) --
    tease_juke_duration_min: float = 0.15
    tease_juke_duration_max: float = 0.5
    tease_magnitude_min: float = 0.04
    tease_magnitude_max: float = 0.12
    tease_freeze_probability: float = 0.15
    tease_freeze_duration_min: float = 0.1
    tease_freeze_duration_max: float = 0.3

    # -- Global --
    offset_clamp: float = 0.15


_VELOCITY_EPSILON: float = 1e-4
"""Minimum speed to consider a cat as moving for lead/perpendicular math."""


class PatternGenerator:
    """Generates per-frame laser offsets for each behavior state.

    Maintains internal phase accumulators and juke timers that evolve
    across frames. The generator is pure: randomness comes from an
    injected ``random.Random``, and time advances via explicit method
    calls.

    Call ``reset()`` at the start of each session to clear accumulated
    phase and timer state.

    Args:
        config: Pattern tuning parameters.
        rng: Random number generator for tease juke directions.
    """

    __slots__ = (
        "_config",
        "_freeze_timer",
        "_freezing",
        "_juke_target_x",
        "_juke_target_y",
        "_juke_timer",
        "_phase",
        "_rng",
    )

    def __init__(self, config: PatternConfig, rng: random.Random) -> None:
        self._config = config
        self._rng = rng
        self._phase = 0.0
        self._juke_target_x = 0.0
        self._juke_target_y = 0.0
        self._juke_timer = 0.0
        self._freezing = False
        self._freeze_timer = 0.0

    def reset(self) -> None:
        """Clear all internal state for a new session."""
        self._phase = 0.0
        self._juke_target_x = 0.0
        self._juke_target_y = 0.0
        self._juke_timer = 0.0
        self._freezing = False
        self._freeze_timer = 0.0

    def tick(self, dt: float) -> None:
        """Advance the internal phase accumulator.

        Must be called once per frame before any pattern method.

        Args:
            dt: Seconds since the previous frame.
        """
        self._phase += dt

    def lure(self, randomness: float) -> tuple[float, float]:
        """Compute lure-phase offset: gentle Lissajous figure-8.

        The base pattern traces a figure-8 via ``sin(t)`` / ``sin(2t)``.
        Higher ``randomness`` blends in 3rd and 5th harmonics, producing
        a more complex path with additional direction changes.

        Args:
            randomness: Pattern randomness from the cat profile (0.0--1.0).

        Returns:
            ``(offset_x, offset_y)`` in normalized frame coordinates.
        """
        cfg = self._config
        t = self._phase * cfg.lure_phase_rate

        base_x = math.sin(t) + randomness * 0.3 * math.sin(3.0 * t)
        base_y = math.sin(2.0 * t) * 0.5 + randomness * 0.2 * math.sin(5.0 * t)

        ox = cfg.lure_amplitude * base_x
        oy = cfg.lure_amplitude * base_y

        return self._clamp(ox, oy)

    def chase(
        self,
        cat: CatObservation | None,
        randomness: float,
    ) -> tuple[float, float]:
        """Compute chase-phase offset: velocity lead + lateral weave.

        The lead component places the laser ahead of the cat in its
        direction of travel, scaled by speed and capped at
        ``chase_lead_max``. A sinusoidal lateral weave perpendicular to
        the velocity vector adds visual interest. ``randomness`` scales
        the weave amplitude.

        Args:
            cat: Target cat observation, or ``None`` if absent this frame.
            randomness: Pattern randomness from the cat profile (0.0--1.0).

        Returns:
            ``(offset_x, offset_y)`` in normalized frame coordinates.
        """
        if cat is None:
            return (0.0, 0.0)

        cfg = self._config
        speed = math.hypot(cat.velocity_x, cat.velocity_y)

        if speed > _VELOCITY_EPSILON:
            lead = min(speed * cfg.chase_lead_scale, cfg.chase_lead_max)
            dir_x = cat.velocity_x / speed
            dir_y = cat.velocity_y / speed
            lead_x = dir_x * lead
            lead_y = dir_y * lead
            perp_x = -dir_y
            perp_y = dir_x
        else:
            lead_x = 0.0
            lead_y = 0.0
            perp_x = 1.0
            perp_y = 0.0

        t = self._phase * cfg.chase_lateral_rate
        lat_scale = cfg.chase_lateral_amplitude * (0.5 + 0.5 * randomness)
        lat = math.sin(t) * lat_scale

        ox = lead_x + perp_x * lat
        oy = lead_y + perp_y * lat

        return self._clamp(ox, oy)

    def tease(self, dt: float, randomness: float) -> tuple[float, float]:
        """Compute tease-phase offset: staccato juke pattern.

        Picks a random direction and magnitude, holds it for a brief
        interval, then snaps to a new direction. Between jukes, there is
        a configurable probability of a short freeze (zero offset) that
        adds unpredictability.

        ``randomness`` scales the juke magnitude range and shortens hold
        durations (more erratic at high randomness).

        Args:
            dt: Seconds since the previous frame (for timer management).
            randomness: Pattern randomness from the cat profile (0.0--1.0).

        Returns:
            ``(offset_x, offset_y)`` in normalized frame coordinates.
        """
        cfg = self._config

        if self._freezing:
            self._freeze_timer -= dt
            if self._freeze_timer <= 0.0:
                self._freezing = False
                self._pick_juke(randomness)
            return (0.0, 0.0)

        self._juke_timer -= dt
        if self._juke_timer <= 0.0:
            if self._rng.random() < cfg.tease_freeze_probability:
                self._freezing = True
                self._freeze_timer = self._rng.uniform(
                    cfg.tease_freeze_duration_min,
                    cfg.tease_freeze_duration_max,
                )
                return (0.0, 0.0)
            self._pick_juke(randomness)

        return self._clamp(self._juke_target_x, self._juke_target_y)

    def _pick_juke(self, randomness: float) -> None:
        """Select a new random juke direction and hold duration."""
        cfg = self._config
        angle = self._rng.uniform(0.0, 2.0 * math.pi)
        base_mag = cfg.tease_magnitude_min + randomness * (
            cfg.tease_magnitude_max - cfg.tease_magnitude_min
        )
        mag = base_mag * self._rng.uniform(0.7, 1.3)

        self._juke_target_x = math.cos(angle) * mag
        self._juke_target_y = math.sin(angle) * mag

        max_dur = cfg.tease_juke_duration_max - randomness * 0.5 * (
            cfg.tease_juke_duration_max - cfg.tease_juke_duration_min
        )
        self._juke_timer = self._rng.uniform(
            cfg.tease_juke_duration_min,
            max(cfg.tease_juke_duration_min, max_dur),
        )

    def _clamp(self, ox: float, oy: float) -> tuple[float, float]:
        """Clamp offsets to the configured maximum."""
        limit = self._config.offset_clamp
        return (
            max(-limit, min(limit, ox)),
            max(-limit, min(limit, oy)),
        )
