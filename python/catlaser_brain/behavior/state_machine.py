"""Behavior engine state machine for play session management.

Drives the laser through five play phases -- lure, chase, tease, cooldown,
dispense -- producing targeting commands for the Rust vision daemon. The
state machine is pure: time is injected, no I/O, no database access. The
caller translates between IPC protobuf messages and engine types.
"""

from __future__ import annotations

import dataclasses
import enum
import math
import random
from typing import TYPE_CHECKING, Final

from catlaser_brain.behavior.engagement import EngagementConfig, EngagementTracker
from catlaser_brain.behavior.pattern import PatternConfig, PatternGenerator

if TYPE_CHECKING:
    from catlaser_brain.behavior.profile import CatProfile

# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------


class State(enum.Enum):
    """Behavior engine play states."""

    IDLE = "idle"
    LURE = "lure"
    CHASE = "chase"
    TEASE = "tease"
    COOLDOWN = "cooldown"
    DISPENSE = "dispense"


class ChuteSide(enum.Enum):
    """Treat dispenser chute exit side."""

    LEFT = "left"
    RIGHT = "right"


class TargetingMode(enum.Enum):
    """Laser targeting modes sent to the Rust vision daemon.

    Maps 1:1 to ``TargetingMode`` in detection.proto.
    """

    IDLE = "idle"
    TRACK = "track"
    LEAD_TO_POINT = "lead_to_point"
    DISPENSE = "dispense"


# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True, slots=True)
class CatObservation:
    """Position and velocity of the target cat from a DetectionFrame.

    All values are in normalized frame coordinates (0.0--1.0).
    """

    center_x: float
    center_y: float
    velocity_x: float
    velocity_y: float


@dataclasses.dataclass(frozen=True, slots=True)
class Command:
    """Targeting command for the Rust vision daemon.

    Fields mirror ``BehaviorCommand`` in detection.proto. The caller
    constructs the protobuf message from this dataclass.
    """

    mode: TargetingMode
    offset_x: float = 0.0
    offset_y: float = 0.0
    smoothing: float = 0.5
    max_speed: float = 0.5
    laser_on: bool = False
    target_track_id: int = 0
    lead_target_x: float = 0.0
    lead_target_y: float = 0.0
    dispense_rotations: int = 0


@dataclasses.dataclass(frozen=True, slots=True)
class SessionResult:
    """Summary emitted when a play session completes.

    The caller records this to SQLite and sends ``SessionEnd`` over IPC.
    """

    engagement_score: float
    dispense_tier: int
    dispense_rotations: int
    active_play_time: float
    avg_velocity: float
    pounce_count: int
    pounce_rate: float
    time_on_target: float


@dataclasses.dataclass(frozen=True, slots=True)
class EngineOutput:
    """Output from each state machine update.

    Attributes:
        command: Targeting command to send to Rust.
        session_ended: Set on the DISPENSE-to-IDLE transition. ``None``
            while the session is active or when idle.
    """

    command: Command
    session_ended: SessionResult | None = None


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DISPENSE_ROTATIONS: Final[tuple[int, int, int]] = (3, 5, 7)
"""Treat disc rotation counts indexed by engagement tier (0, 1, 2)."""


def _lerp(a: float, b: float, t: float) -> float:
    """Linear interpolation from *a* to *b* by factor *t* in [0, 1]."""
    return a + (b - a) * t


_IDLE_COMMAND: Final[Command] = Command(mode=TargetingMode.IDLE)

_IDLE_OUTPUT: Final[EngineOutput] = EngineOutput(command=_IDLE_COMMAND)

_ACTIVE_PLAY_STATES: Final[frozenset[State]] = frozenset(
    {
        State.LURE,
        State.CHASE,
        State.TEASE,
    }
)
"""States representing active play before cooldown/dispense."""

_ENGAGEMENT_STATES: Final[frozenset[State]] = frozenset(
    {
        State.CHASE,
        State.TEASE,
    }
)
"""States in which engagement metrics are accumulated."""


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True, slots=True)
class EngineConfig:
    """Tuning parameters for the behavior engine state machine.

    All durations are in seconds. Speed and smoothing values are in
    normalized units matching the ``BehaviorCommand`` proto fields.
    Per-cat profile adaptation (BUILD step 3) overrides a subset of
    these at session start.
    """

    # -- Lure phase --
    lure_min_duration: float = 2.0
    lure_max_duration: float = 15.0
    lure_smoothing: float = 0.8
    lure_max_speed: float = 0.15
    lure_engagement_velocity: float = 0.05

    # -- Chase phase --
    chase_smoothing: float = 0.5
    chase_max_speed: float = 0.5
    chase_min_before_tease: float = 5.0
    chase_tease_interval_min: float = 8.0
    chase_tease_interval_max: float = 15.0

    # -- Tease phase --
    tease_duration_min: float = 2.0
    tease_duration_max: float = 4.0
    tease_smoothing: float = 0.3
    tease_max_speed: float = 0.7

    # -- Cooldown phase --
    cooldown_decel_duration: float = 3.0
    cooldown_timeout: float = 15.0
    cooldown_smoothing: float = 0.9
    cooldown_max_speed: float = 0.1
    cooldown_arrival_tolerance: float = 0.05

    # -- Dispense phase --
    dispense_duration: float = 3.0

    # -- Session limits --
    session_timeout: float = 300.0

    # -- Track loss --
    track_lost_timeout: float = 5.0

    # -- Chute exit targets (normalized coords near device base) --
    chute_left_x: float = 0.3
    chute_left_y: float = 0.9
    chute_right_x: float = 0.7
    chute_right_y: float = 0.9

    # -- Engagement tracking --
    engagement: EngagementConfig = dataclasses.field(
        default_factory=EngagementConfig,
    )

    # -- Pattern generation --
    pattern: PatternConfig = dataclasses.field(
        default_factory=PatternConfig,
    )
    pattern_randomness: float = 0.5


# ---------------------------------------------------------------------------
# Profile application
# ---------------------------------------------------------------------------


def apply_profile(config: EngineConfig, profile: CatProfile) -> EngineConfig:
    """Overlay a cat's learned preferences onto the base engine config.

    Speed is multiplicative: ``preferred_speed`` scales chase and tease
    max speeds. Smoothing is a direct override: ``preferred_smoothing``
    replaces chase smoothing, and tease smoothing is scaled to maintain
    its original ratio relative to chase smoothing.

    Lure, cooldown, and dispense parameters are unaffected.

    Args:
        config: Base engine configuration.
        profile: Per-cat profile to apply.

    Returns:
        New config with profile-adjusted fields.
    """
    tease_chase_ratio = config.tease_smoothing / config.chase_smoothing
    return dataclasses.replace(
        config,
        chase_max_speed=config.chase_max_speed * profile.preferred_speed,
        tease_max_speed=config.tease_max_speed * profile.preferred_speed,
        chase_smoothing=profile.preferred_smoothing,
        tease_smoothing=profile.preferred_smoothing * tease_chase_ratio,
        pattern_randomness=profile.pattern_randomness,
    )


# ---------------------------------------------------------------------------
# Internal mutable state
# ---------------------------------------------------------------------------


@dataclasses.dataclass(slots=True)
class _SessionState:
    engagement: EngagementTracker
    session_start: float = 0.0
    state_entered_at: float = 0.0
    target_track_id: int = 0
    chute_side: ChuteSide = ChuteSide.LEFT
    target_absent_since: float | None = None
    next_tease_at: float = 0.0
    tease_ends_at: float = 0.0
    last_update_time: float = 0.0
    dispense_tier: int = 0
    dispense_rotations: int = 0
    offset_x: float = 0.0
    offset_y: float = 0.0
    pre_cooldown_speed: float = 0.0
    pre_cooldown_smoothing: float = 0.0
    pre_cooldown_offset_x: float = 0.0
    pre_cooldown_offset_y: float = 0.0


# ---------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------


class BehaviorEngine:
    """Play session state machine.

    Pure state machine driving laser behavior through five play phases:
    lure, chase, tease, cooldown, dispense. Time is injected via the
    ``now`` parameter, randomness via an injected ``random.Random``
    instance, and no I/O occurs. The caller handles IPC translation and
    database writes.

    Args:
        config: Tuning parameters for all phases.
        rng: Random number generator for tease interval scheduling.
    """

    __slots__ = ("_base_config", "_config", "_pattern", "_rng", "_session", "_state")

    def __init__(self, config: EngineConfig, rng: random.Random) -> None:
        self._base_config = config
        self._config = config
        self._rng = rng
        self._pattern = PatternGenerator(
            config.pattern,
            random.Random(rng.getrandbits(64)),  # noqa: S311
        )
        self._state = State.IDLE
        self._session = _SessionState(
            engagement=EngagementTracker(config.engagement),
        )

    @property
    def state(self) -> State:
        """Current behavior engine state."""
        return self._state

    @property
    def target_track_id(self) -> int:
        """Track ID of the current target cat. Zero when idle."""
        return self._session.target_track_id

    # -------------------------------------------------------------------
    # Public API
    # -------------------------------------------------------------------

    def start_session(
        self,
        target_track_id: int,
        chute_side: ChuteSide,
        now: float,
        *,
        profile: CatProfile | None = None,
    ) -> EngineOutput:
        """Begin a new play session targeting a specific cat track.

        If a cat profile is provided, the engine applies it to the base
        config for the duration of the session. The base config is
        restored when the session ends.

        Args:
            target_track_id: SORT tracker ID to follow.
            chute_side: Which chute to lead the cat toward at session end.
            now: Monotonic timestamp in seconds.
            profile: Per-cat profile to apply for this session. ``None``
                uses the base engine config unmodified.

        Returns:
            Initial lure-phase command.

        Raises:
            RuntimeError: If a session is already active.
        """
        if self._state is not State.IDLE:
            msg = f"cannot start session: engine is in {self._state.value} state"
            raise RuntimeError(msg)

        self._config = (
            apply_profile(self._base_config, profile) if profile is not None else self._base_config
        )

        self._session = _SessionState(
            engagement=EngagementTracker(self._config.engagement),
            session_start=now,
            state_entered_at=now,
            target_track_id=target_track_id,
            chute_side=chute_side,
            last_update_time=now,
        )
        self._state = State.LURE
        self._pattern.reset()

        return EngineOutput(command=self._make_command())

    def stop_session(self, now: float) -> EngineOutput:
        """Request graceful session end (app-triggered or timeout).

        Transitions to COOLDOWN if in an active play state. No-op if
        already in COOLDOWN, DISPENSE, or IDLE.

        Args:
            now: Monotonic timestamp in seconds.

        Returns:
            Command for the resulting state.
        """
        if self._state in _ACTIVE_PLAY_STATES:
            self._begin_cooldown(now)
        return EngineOutput(command=self._make_command())

    def update(self, cat: CatObservation | None, now: float) -> EngineOutput:
        """Process a detection frame tick.

        Called at frame rate (~15 FPS). Updates engagement metrics and
        evaluates state transitions based on timing and cat behavior.

        Args:
            cat: Target cat observation, or ``None`` if the target track
                was not present in this frame.
            now: Monotonic timestamp in seconds.

        Returns:
            Command for the current (possibly transitioned) state.
        """
        if self._state is State.IDLE:
            return _IDLE_OUTPUT

        s = self._session
        dt = now - s.last_update_time
        s.last_update_time = now

        self._track_presence(cat, now)

        pre_tick_state = self._state
        if self._state in _ENGAGEMENT_STATES and cat is not None:
            self._update_engagement(cat, dt)

        if self._check_session_limits(now):
            return EngineOutput(command=self._make_command())

        tick_result = self._dispatch_tick(cat, now)
        if tick_result is not None:
            return tick_result

        # Accumulate engagement for the frame that transitioned us into
        # an engagement state (e.g. lure -> chase). The pre-tick check
        # above saw the old state and skipped; now the new state qualifies.
        if (
            pre_tick_state not in _ENGAGEMENT_STATES
            and self._state in _ENGAGEMENT_STATES
            and cat is not None
        ):
            self._update_engagement(cat, dt)

        self._compute_pattern_offsets(cat, dt)

        return EngineOutput(command=self._make_command())

    def on_track_lost(self, track_id: int, now: float) -> EngineOutput:
        """Handle a definitive track loss event from the SORT tracker.

        If the lost track is the current target and the engine is in an
        active play state, transitions to COOLDOWN for graceful session
        end with treat dispensing.

        Args:
            track_id: The track that was lost.
            now: Monotonic timestamp in seconds.

        Returns:
            Command for the resulting state.
        """
        if track_id == self._session.target_track_id and self._state in _ACTIVE_PLAY_STATES:
            self._begin_cooldown(now)

        return EngineOutput(command=self._make_command())

    # -------------------------------------------------------------------
    # Update helpers (extracted to keep update() under C901 threshold)
    # -------------------------------------------------------------------

    def _track_presence(
        self,
        cat: CatObservation | None,
        now: float,
    ) -> None:
        s = self._session
        if cat is not None:
            s.target_absent_since = None
        elif s.target_absent_since is None:
            s.target_absent_since = now

    def _check_session_limits(self, now: float) -> bool:
        s = self._session
        if (
            self._state in _ACTIVE_PLAY_STATES
            and now - s.session_start >= self._config.session_timeout
        ):
            self._begin_cooldown(now)
            return True
        if (
            self._state in _ACTIVE_PLAY_STATES
            and s.target_absent_since is not None
            and now - s.target_absent_since >= self._config.track_lost_timeout
        ):
            self._begin_cooldown(now)
            return True
        return False

    def _dispatch_tick(
        self,
        cat: CatObservation | None,
        now: float,
    ) -> EngineOutput | None:
        match self._state:
            case State.LURE:
                self._tick_lure(cat, now)
            case State.CHASE:
                self._tick_chase(now)
            case State.TEASE:
                self._tick_tease(now)
            case State.COOLDOWN:
                return self._tick_cooldown(cat, now)
            case State.DISPENSE:
                return self._tick_dispense(now)
            case State.IDLE:
                pass
        return None

    def _compute_pattern_offsets(self, cat: CatObservation | None, dt: float) -> None:
        s = self._session
        if self._state not in _ACTIVE_PLAY_STATES:
            s.offset_x = 0.0
            s.offset_y = 0.0
            return
        self._pattern.tick(dt)
        randomness = self._config.pattern_randomness
        if self._state is State.LURE:
            s.offset_x, s.offset_y = self._pattern.lure(randomness)
        elif self._state is State.CHASE:
            s.offset_x, s.offset_y = self._pattern.chase(cat, randomness)
        else:
            s.offset_x, s.offset_y = self._pattern.tease(dt, randomness)

    # -------------------------------------------------------------------
    # State transitions
    # -------------------------------------------------------------------

    def _transition(self, new_state: State, now: float) -> None:
        self._state = new_state
        self._session.state_entered_at = now

    def _begin_cooldown(self, now: float) -> None:
        tier = self._session.engagement.tier
        self._session.dispense_tier = tier
        self._session.dispense_rotations = DISPENSE_ROTATIONS[tier]

        s = self._session
        s.pre_cooldown_offset_x = s.offset_x
        s.pre_cooldown_offset_y = s.offset_y

        cfg = self._config
        if self._state is State.CHASE:
            s.pre_cooldown_speed = cfg.chase_max_speed
            s.pre_cooldown_smoothing = cfg.chase_smoothing
        elif self._state is State.TEASE:
            s.pre_cooldown_speed = cfg.tease_max_speed
            s.pre_cooldown_smoothing = cfg.tease_smoothing
        else:
            s.pre_cooldown_speed = cfg.lure_max_speed
            s.pre_cooldown_smoothing = cfg.lure_smoothing

        self._transition(State.COOLDOWN, now)

    def _begin_chase(self, now: float) -> None:
        self._transition(State.CHASE, now)
        self._schedule_next_tease(now)

    def _schedule_next_tease(self, now: float) -> None:
        cfg = self._config
        interval = self._rng.uniform(
            cfg.chase_tease_interval_min,
            cfg.chase_tease_interval_max,
        )
        self._session.next_tease_at = now + interval

    # -------------------------------------------------------------------
    # Per-state tick logic
    # -------------------------------------------------------------------

    def _tick_lure(self, cat: CatObservation | None, now: float) -> None:
        time_in_lure = now - self._session.state_entered_at
        cfg = self._config

        if time_in_lure >= cfg.lure_max_duration:
            self._begin_chase(now)
            return

        if time_in_lure >= cfg.lure_min_duration and cat is not None:
            speed = math.hypot(cat.velocity_x, cat.velocity_y)
            if speed >= cfg.lure_engagement_velocity:
                self._begin_chase(now)

    def _tick_chase(self, now: float) -> None:
        time_in_chase = now - self._session.state_entered_at
        cfg = self._config

        if time_in_chase >= cfg.chase_min_before_tease and now >= self._session.next_tease_at:
            duration = self._rng.uniform(
                cfg.tease_duration_min,
                cfg.tease_duration_max,
            )
            self._session.tease_ends_at = now + duration
            self._transition(State.TEASE, now)

    def _tick_tease(self, now: float) -> None:
        if now >= self._session.tease_ends_at:
            self._begin_chase(now)

    def _tick_cooldown(
        self,
        cat: CatObservation | None,
        now: float,
    ) -> EngineOutput:
        time_in_cooldown = now - self._session.state_entered_at

        if time_in_cooldown >= self._config.cooldown_timeout:
            self._transition(State.DISPENSE, now)
            return EngineOutput(command=self._make_command())

        if cat is not None:
            tx, ty = self._chute_target()
            distance = math.hypot(cat.center_x - tx, cat.center_y - ty)
            if distance <= self._config.cooldown_arrival_tolerance:
                self._transition(State.DISPENSE, now)
                return EngineOutput(command=self._make_command())

        return EngineOutput(command=self._make_command())

    def _tick_dispense(self, now: float) -> EngineOutput:
        if now - self._session.state_entered_at >= self._config.dispense_duration:
            s = self._session
            snap = s.engagement.snapshot()
            result = SessionResult(
                engagement_score=snap.score,
                dispense_tier=s.dispense_tier,
                dispense_rotations=s.dispense_rotations,
                active_play_time=snap.active_time,
                avg_velocity=snap.avg_velocity,
                pounce_count=snap.pounce_count,
                pounce_rate=snap.pounce_rate,
                time_on_target=snap.time_on_target,
            )
            self._config = self._base_config
            self._state = State.IDLE
            self._session = _SessionState(
                engagement=EngagementTracker(self._config.engagement),
            )
            return EngineOutput(command=_IDLE_COMMAND, session_ended=result)

        return EngineOutput(command=self._make_command())

    # -------------------------------------------------------------------
    # Command construction
    # -------------------------------------------------------------------

    def _make_command(self) -> Command:
        match self._state:
            case State.IDLE:
                return _IDLE_COMMAND
            case State.LURE:
                return Command(
                    mode=TargetingMode.TRACK,
                    offset_x=self._session.offset_x,
                    offset_y=self._session.offset_y,
                    smoothing=self._config.lure_smoothing,
                    max_speed=self._config.lure_max_speed,
                    laser_on=True,
                    target_track_id=self._session.target_track_id,
                )
            case State.CHASE:
                return Command(
                    mode=TargetingMode.TRACK,
                    offset_x=self._session.offset_x,
                    offset_y=self._session.offset_y,
                    smoothing=self._config.chase_smoothing,
                    max_speed=self._config.chase_max_speed,
                    laser_on=True,
                    target_track_id=self._session.target_track_id,
                )
            case State.TEASE:
                return Command(
                    mode=TargetingMode.TRACK,
                    offset_x=self._session.offset_x,
                    offset_y=self._session.offset_y,
                    smoothing=self._config.tease_smoothing,
                    max_speed=self._config.tease_max_speed,
                    laser_on=True,
                    target_track_id=self._session.target_track_id,
                )
            case State.COOLDOWN:
                return self._cooldown_command()
            case State.DISPENSE:
                tx, ty = self._chute_target()
                return Command(
                    mode=TargetingMode.DISPENSE,
                    laser_on=False,
                    dispense_rotations=self._session.dispense_rotations,
                    lead_target_x=tx,
                    lead_target_y=ty,
                )

    def _chute_target(self) -> tuple[float, float]:
        cfg = self._config
        if self._session.chute_side is ChuteSide.LEFT:
            return cfg.chute_left_x, cfg.chute_left_y
        return cfg.chute_right_x, cfg.chute_right_y

    def _cooldown_command(self) -> Command:
        """Build the command for the current cooldown sub-phase.

        Deceleration (``t < cooldown_decel_duration``): TRACK mode with
        speed and smoothing linearly interpolated from the pre-cooldown
        values to the cooldown targets.

        Lead (``t >= cooldown_decel_duration``): LEAD_TO_POINT mode at
        final cooldown speed/smoothing, guiding the laser toward the
        selected chute exit.
        """
        s = self._session
        cfg = self._config
        time_in_cooldown = max(s.last_update_time - s.state_entered_at, 0.0)

        if cfg.cooldown_decel_duration > 0.0:
            decel_progress = min(time_in_cooldown / cfg.cooldown_decel_duration, 1.0)
        else:
            decel_progress = 1.0

        if decel_progress < 1.0:
            speed = _lerp(s.pre_cooldown_speed, cfg.cooldown_max_speed, decel_progress)
            smoothing = _lerp(s.pre_cooldown_smoothing, cfg.cooldown_smoothing, decel_progress)
            offset_x = _lerp(s.pre_cooldown_offset_x, 0.0, decel_progress)
            offset_y = _lerp(s.pre_cooldown_offset_y, 0.0, decel_progress)
            return Command(
                mode=TargetingMode.TRACK,
                offset_x=offset_x,
                offset_y=offset_y,
                smoothing=smoothing,
                max_speed=speed,
                laser_on=True,
                target_track_id=s.target_track_id,
            )

        tx, ty = self._chute_target()
        return Command(
            mode=TargetingMode.LEAD_TO_POINT,
            smoothing=cfg.cooldown_smoothing,
            max_speed=cfg.cooldown_max_speed,
            laser_on=True,
            target_track_id=s.target_track_id,
            lead_target_x=tx,
            lead_target_y=ty,
        )

    # -------------------------------------------------------------------
    # Engagement scoring
    # -------------------------------------------------------------------

    def _update_engagement(self, cat: CatObservation, dt: float) -> None:
        speed = math.hypot(cat.velocity_x, cat.velocity_y)
        self._session.engagement.update(speed, dt)
