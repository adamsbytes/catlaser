"""Per-cat profile adaptation for the behavior engine.

Cats develop individual play preferences over sessions. The profile tracks
three tuning knobs -- speed, smoothing, and pattern randomness -- that the
behavior engine applies per-session to tailor laser movement to each cat's
temperament. Adaptation uses exponential moving averages over session metrics,
converging gradually rather than swinging on any single session.

The profile module has no dependency on the state machine or engagement
tracker. The caller extracts the relevant metrics from ``SessionResult``
and passes them to ``adapt_profile`` as scalars.
"""

from __future__ import annotations

import dataclasses
import time
from typing import TYPE_CHECKING, Final

if TYPE_CHECKING:
    import sqlite3


# ---------------------------------------------------------------------------
# Profile
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True, slots=True)
class CatProfile:
    """Per-cat tuning knobs learned from play session history.

    Attributes:
        preferred_speed: Multiplier applied to chase and tease max speeds.
            1.0 is the base config default. Values above 1.0 mean the cat
            prefers faster movement; below 1.0, slower.
        preferred_smoothing: Smoothing factor for chase and tease phases.
            Higher values produce smoother, more predictable laser movement;
            lower values produce more erratic, juke-heavy patterns.
        pattern_randomness: Controls variety in pattern generation (consumed
            by the pattern generator, BUILD step 4). Higher values introduce
            more randomness; lower values favor repeatable patterns.
    """

    preferred_speed: float = 1.0
    preferred_smoothing: float = 0.5
    pattern_randomness: float = 0.5


# ---------------------------------------------------------------------------
# Adaptation config
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True, slots=True)
class AdaptationConfig:
    """Parameters controlling how profiles evolve across sessions.

    Bounds define the allowed range for each knob. The learning rate
    controls how quickly profiles shift toward the signal from a single
    session -- lower values are more conservative, higher are more reactive.
    """

    learning_rate: float = 0.15

    speed_min: float = 0.3
    speed_max: float = 2.0

    smoothing_min: float = 0.1
    smoothing_max: float = 0.9

    randomness_min: float = 0.1
    randomness_max: float = 0.9

    pounce_rate_normalization: float = 0.1

    min_active_time: float = 5.0


_DEFAULT_ADAPTATION: Final[AdaptationConfig] = AdaptationConfig()


# ---------------------------------------------------------------------------
# Adaptation logic
# ---------------------------------------------------------------------------


def adapt_profile(
    profile: CatProfile,
    *,
    engagement_score: float,
    time_on_target: float,
    pounce_rate: float,
    active_play_time: float,
    config: AdaptationConfig = _DEFAULT_ADAPTATION,
) -> CatProfile:
    """Produce an updated profile from session engagement metrics.

    Pure function: takes the current profile and raw session metrics,
    returns a new profile with each knob nudged toward a target derived
    from the session via exponential moving average (EMA).

    Signal mapping:

    - **Speed**: engagement score maps linearly to the speed range.
      High engagement means the cat is keeping up -- try faster next time.
    - **Smoothing**: inverse of time-on-target maps to the smoothing range.
      Low time-on-target means the cat loses track -- increase smoothing.
    - **Randomness**: normalized pounce rate maps to the randomness range.
      High pounce rate means the cat responds to variety -- increase it.

    Returns the profile unchanged if active play time is below
    ``config.min_active_time`` (too short for meaningful signal).

    Args:
        profile: Current cat profile.
        engagement_score: Composite engagement score (0.0--1.0).
        time_on_target: Fraction of active time spent chasing (0.0--1.0).
        pounce_rate: Pounces per second during active play.
        active_play_time: Seconds spent in engagement-tracked states.
        config: Adaptation parameters (bounds, learning rate, thresholds).

    Returns:
        New profile with adapted knobs, or the original if the session
        was too short.
    """
    if active_play_time < config.min_active_time:
        return profile

    alpha = config.learning_rate

    target_speed = config.speed_min + engagement_score * (config.speed_max - config.speed_min)
    new_speed = _ema_clamp(
        profile.preferred_speed,
        target_speed,
        alpha,
        config.speed_min,
        config.speed_max,
    )

    target_smoothing = config.smoothing_min + (1.0 - time_on_target) * (
        config.smoothing_max - config.smoothing_min
    )
    new_smoothing = _ema_clamp(
        profile.preferred_smoothing,
        target_smoothing,
        alpha,
        config.smoothing_min,
        config.smoothing_max,
    )

    normalized_pounce = min(pounce_rate / config.pounce_rate_normalization, 1.0)
    target_randomness = config.randomness_min + normalized_pounce * (
        config.randomness_max - config.randomness_min
    )
    new_randomness = _ema_clamp(
        profile.pattern_randomness,
        target_randomness,
        alpha,
        config.randomness_min,
        config.randomness_max,
    )

    return CatProfile(
        preferred_speed=new_speed,
        preferred_smoothing=new_smoothing,
        pattern_randomness=new_randomness,
    )


def _ema_clamp(
    current: float,
    target: float,
    alpha: float,
    lo: float,
    hi: float,
) -> float:
    """EMA blend of *current* toward *target*, clamped to [*lo*, *hi*]."""
    blended = alpha * target + (1.0 - alpha) * current
    return max(lo, min(hi, blended))


# ---------------------------------------------------------------------------
# SQLite persistence
# ---------------------------------------------------------------------------


def load_profile(conn: sqlite3.Connection, cat_id: str) -> CatProfile:
    """Load a cat's profile from the ``cats`` table.

    Args:
        conn: SQLite connection with ``row_factory = sqlite3.Row``.
        cat_id: Cat identifier.

    Returns:
        The cat's current profile.

    Raises:
        LookupError: If *cat_id* does not exist in the catalog.
    """
    row = conn.execute(
        "SELECT preferred_speed, preferred_smoothing, pattern_randomness "
        "FROM cats WHERE cat_id = ?",
        (cat_id,),
    ).fetchone()
    if row is None:
        msg = f"cat {cat_id} not found in catalog"
        raise LookupError(msg)
    speed: float = row["preferred_speed"]
    smoothing: float = row["preferred_smoothing"]
    randomness: float = row["pattern_randomness"]
    return CatProfile(
        preferred_speed=speed,
        preferred_smoothing=smoothing,
        pattern_randomness=randomness,
    )


def save_profile(
    conn: sqlite3.Connection,
    cat_id: str,
    profile: CatProfile,
) -> None:
    """Write an adapted profile back to the ``cats`` table.

    Updates only the three profile columns and ``updated_at``.

    Args:
        conn: SQLite connection.
        cat_id: Cat identifier (must already exist).
        profile: Updated profile to persist.
    """
    now = int(time.time())
    conn.execute(
        "UPDATE cats "
        "SET preferred_speed = ?, preferred_smoothing = ?, "
        "    pattern_randomness = ?, updated_at = ? "
        "WHERE cat_id = ?",
        (
            profile.preferred_speed,
            profile.preferred_smoothing,
            profile.pattern_randomness,
            now,
            cat_id,
        ),
    )
    conn.commit()
