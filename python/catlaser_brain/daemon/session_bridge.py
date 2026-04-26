"""Bridge between the vision IPC stream and the behavior engine.

Owns the live session lifecycle on the Python side. Translates inbound
:class:`DetectionFrame`, :class:`TrackEvent`, :class:`SessionRequest`,
and :class:`StreamStatus` messages into engine operations and SQLite
writes, and emits outbound :class:`BehaviorCommand`,
:class:`SessionAck`, :class:`IdentityResult`, and :class:`SessionEnd`
frames. Implements :class:`SessionControl` so the app server can
ARM-then-await manual sessions and request graceful stops.

The bridge is intentionally I/O-shaped on inputs (it accepts raw
protobuf messages from the IPC layer) and outputs (it returns proto
messages or send-side effects to the orchestrator). The pure state
machine lives in :class:`BehaviorEngine`; this module is the integration
layer that the orchestrator drives.
"""

from __future__ import annotations

import logging
import random
import time
import uuid
from dataclasses import dataclass
from typing import TYPE_CHECKING

from catlaser_brain.behavior.dispense import finalize_session, next_chute_side
from catlaser_brain.behavior.profile import load_profile
from catlaser_brain.behavior.schedule import (
    ClockReading,
    SessionDecision,
    SessionTrigger,
    SkipReason,
    evaluate_session_request,
)
from catlaser_brain.behavior.state_machine import (
    BehaviorEngine,
    CatObservation,
    Command,
    EngineConfig,
    EngineOutput,
    SessionResult,
    TargetingMode,
)
from catlaser_brain.identity.catalog import CatCatalog, MatchResult
from catlaser_brain.proto.catlaser.detection.v1 import detection_pb2 as det
from catlaser_brain.storage.crud import create_session

if TYPE_CHECKING:
    import sqlite3
    from collections.abc import Callable

    from catlaser_brain.daemon.hopper import HopperSensor

_logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# How long after an app-initiated `start_session()` the bridge will
# auto-accept the next inbound `SessionRequest` from Rust as a manual
# session. Beyond this window the manual arm expires and behaviour
# reverts to schedule-driven gating. Long enough for a cat to wander
# into frame; short enough that an old click does not silently steal
# a future scheduled session.
_MANUAL_ARM_TTL_SEC: float = 30.0


# ---------------------------------------------------------------------------
# Outbound messages
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class OutboundMessages:
    """Frames the orchestrator must ship over IPC after a bridge tick.

    Returned by every bridge method that processes an inbound message.
    The orchestrator iterates these in order and writes them to the
    IPC client; failures kill the connection and trigger reconnect.
    The dataclass is immutable so a partially-built batch never leaks
    if the caller short-circuits on the first send error.
    """

    behavior_commands: tuple[det.BehaviorCommand, ...] = ()
    session_acks: tuple[det.SessionAck, ...] = ()
    identity_results: tuple[det.IdentityResult, ...] = ()
    session_ends: int = 0


# ---------------------------------------------------------------------------
# Active session record
# ---------------------------------------------------------------------------


@dataclass(slots=True)
class _ActiveSession:
    """State retained between session accept and the finalize write.

    The behavior engine owns the targeting state (track ID, engagement,
    pattern). This struct only carries data the engine cannot
    re-derive: the SQLite session_id, the resolved cat_id (initially
    empty, filled in when an :class:`IdentityResult` arrives), the
    chute alternation choice, and the wall-clock start time.
    """

    session_id: str
    cat_id: str
    chute_side: object  # ChuteSide — kept as object to avoid an enum import here
    start_time_epoch: int
    track_id: int


# ---------------------------------------------------------------------------
# App-facing notifications
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class SessionFinalized:
    """Notification that a session ended, ready for app broadcast.

    The orchestrator translates this into both a ``SessionSummary``
    broadcast over the app server and (optionally) an FCM push.
    """

    cat_ids: tuple[str, ...]
    duration_sec: int
    engagement_score: float
    treats_dispensed: int
    pounce_count: int
    ended_at: int


# ---------------------------------------------------------------------------
# Bridge
# ---------------------------------------------------------------------------


class SessionBridge:
    """Implements :class:`SessionControl` and pumps the engine off IPC.

    Lifetime: one instance per daemon. Holds a reference to the SQLite
    connection, the cat catalog, and a freshly-constructed
    :class:`BehaviorEngine`. The orchestrator calls
    :meth:`handle_detection_frame`, :meth:`handle_track_event`,
    :meth:`handle_session_request`, etc. as IPC messages arrive.

    Args:
        conn: SQLite connection from :class:`Database`.
        catalog: Cat re-ID catalog; used to resolve
            :class:`IdentityRequest` events.
        hopper: Hopper sensor read on every :class:`SessionRequest` so
            an empty hopper rejects autonomous play.
        engine_config: Tuning overrides for the behavior engine. Tests
            override timing constants to keep tests fast; production
            uses :class:`EngineConfig`'s defaults.
        rng: Random number generator the engine uses for tease
            scheduling. Tests inject a seeded RNG; production uses a
            fresh :class:`random.Random` so two devices do not share
            the same tease cadence.
        clock: Monotonic clock function. Tests inject a controllable
            clock; production passes :func:`time.monotonic`. Used for
            engine timing decisions.
        wall_clock: Unix-epoch clock function. Tests inject for
            deterministic session timestamps; production passes
            :func:`time.time`. Drives session_id timestamps and the
            schedule evaluator's :class:`ClockReading`.
    """

    __slots__ = (
        "_active",
        "_catalog",
        "_clock",
        "_conn",
        "_engine",
        "_hopper",
        "_manual_arm_until",
        "_pending_finalized",
        "_wall_clock",
    )

    def __init__(  # noqa: PLR0913 — every dependency is distinct and required
        self,
        *,
        conn: sqlite3.Connection,
        catalog: CatCatalog,
        hopper: HopperSensor,
        engine_config: EngineConfig | None = None,
        rng: random.Random | None = None,
        clock: Callable[[], float] = time.monotonic,
        wall_clock: Callable[[], float] = time.time,
    ) -> None:
        self._conn = conn
        self._catalog = catalog
        self._hopper = hopper
        self._engine = BehaviorEngine(
            engine_config if engine_config is not None else EngineConfig(),
            rng if rng is not None else random.Random(),  # noqa: S311 — non-crypto tease cadence
        )
        self._clock: Callable[[], float] = clock
        self._wall_clock: Callable[[], float] = wall_clock
        self._active: _ActiveSession | None = None
        self._manual_arm_until: float = 0.0
        self._pending_finalized: SessionFinalized | None = None

    # -------------------------------------------------------------------
    # SessionControl protocol
    # -------------------------------------------------------------------

    def start_session(self) -> None:
        """App requested a manual session start.

        Arms the next inbound :class:`SessionRequest` to auto-accept
        regardless of schedule / quiet-hours gating. Sessions still
        block on hopper-empty — the user cannot bypass refilling treats.
        The arm expires after :data:`_MANUAL_ARM_TTL_SEC`.
        """
        self._manual_arm_until = self._monotonic() + _MANUAL_ARM_TTL_SEC

    def stop_session(self) -> None:
        """App requested graceful session end.

        Transitions the engine into COOLDOWN. The next
        :meth:`handle_detection_frame` produces the cooldown command.
        Idempotent — stopping a session that is not active is a no-op.
        """
        self._engine.stop_session(self._monotonic())

    # -------------------------------------------------------------------
    # IPC message handlers
    # -------------------------------------------------------------------

    def handle_detection_frame(self, frame: det.DetectionFrame) -> OutboundMessages:
        """Tick the engine on the latest detection frame.

        When a session is active, finds the target track in the frame,
        builds a :class:`CatObservation`, and ticks the engine. The
        resulting :class:`Command` becomes one outbound
        :class:`BehaviorCommand`. When the session ends (engine
        produces a :class:`SessionResult`), finalises the SQLite row
        and queues a ``SessionEnd`` frame for Rust.

        When no session is active, returns an empty batch. The Rust
        autonomous mode handles the laser without Python's input.
        """
        if self._active is None:
            return OutboundMessages()

        cat = _find_target_cat(frame, self._engine.target_track_id)
        output = self._engine.update(cat, self._monotonic())

        if output.session_ended is not None:
            self._finalize(output.session_ended)
            return OutboundMessages(
                behavior_commands=(_command_to_proto(output.command),),
                session_ends=1,
            )

        return OutboundMessages(behavior_commands=(_command_to_proto(output.command),))

    def handle_track_event(self, event: det.TrackEvent) -> OutboundMessages:
        """Dispatch on the oneof variant.

        ``new_track`` is informational (logged only). ``track_lost``
        for the active target transitions the engine to cooldown — the
        next detection frame produces the cooldown command.
        ``identity_request`` resolves the embedding against the
        catalog and queues an :class:`IdentityResult` reply.
        """
        which = event.WhichOneof("event")
        if which == "new_track":
            _logger.debug("vision new_track id=%d", event.new_track.track_id)
            return OutboundMessages()
        if which == "track_lost":
            return self._handle_track_lost(event.track_lost)
        if which == "identity_request":
            return self._handle_identity_request(event.identity_request)
        _logger.warning("track event with no oneof case: %r", event)
        return OutboundMessages()

    def handle_session_request(
        self,
        request: det.SessionRequest,
    ) -> OutboundMessages:
        """Decide whether to start a session and reply with a SessionAck.

        Priority order: an active session blocks new ones (defensive —
        Rust shouldn't request while we're running, but a stale
        request after an IPC reconnect could). Otherwise, manual-armed
        accepts fast-path; otherwise, normal scheduling logic gates on
        hopper / cooldown / quiet hours.
        """
        if self._active is not None:
            return self._reject(SkipReason.COOLDOWN)

        trigger = _trigger_from_proto(request.trigger)
        manual = self._consume_manual_arm()
        decision = (
            SessionDecision(accept=True)
            if manual and not self._hopper.is_empty()
            else evaluate_session_request(
                self._conn,
                trigger,
                hopper_empty=self._hopper.is_empty(),
                clock=self._clock_reading(),
            )
        )

        if not decision.accept:
            return self._reject_decision(decision)

        track_id = request.track_id if request.HasField("track_id") else 0
        if track_id == 0:
            # Rust always supplies a track for CAT_DETECTED requests.
            # A zero target leaves the engine with nothing to follow,
            # so reject defensively rather than starting a stuck session.
            _logger.warning("session request without track_id; rejecting")
            return self._reject(SkipReason.COOLDOWN)

        return self._accept_session(track_id, manual=manual, trigger=trigger)

    def handle_stream_status(self, status: det.StreamStatus) -> None:
        """Log publisher state transitions from Rust.

        The orchestrator's app broadcast layer might surface these to
        the app in a future iteration. For now they live in logs
        only — the app's LiveKit SDK observes its own peer connection
        state and does not need a Python relay.
        """
        _logger.info(
            "stream status: state=%s error=%s",
            det.StreamState.Name(status.state),
            status.error_message,
        )

    def handle_disconnect(self) -> None:
        """Reset session state when the vision IPC connection drops.

        A reconnect has no shared state with the prior session, so
        any in-flight session must be abandoned. The engine is reset
        to IDLE; pending DB rows are left in place (end_time NULL)
        so a future scheduled job can sweep them. Manual arm is also
        cleared because the next reconnect's first SessionRequest
        could be stale.
        """
        if self._active is not None:
            _logger.warning(
                "vision IPC disconnect during active session %s; abandoning",
                self._active.session_id,
            )
            self._active = None
        self._manual_arm_until = 0.0
        # Re-create the engine to drop any stale state. Cheap — the
        # engine has no persistent buffers.
        self._engine = BehaviorEngine(
            self._engine_config_for_reset(),
            random.Random(),  # noqa: S311 — non-crypto tease cadence
        )

    def take_finalized(self) -> SessionFinalized | None:
        """Drain the most recent :class:`SessionFinalized` notification.

        The orchestrator polls this each tick and broadcasts a
        ``SessionSummary`` when present. Cleared once consumed so a
        single session emits exactly one notification.
        """
        finalized = self._pending_finalized
        self._pending_finalized = None
        return finalized

    @property
    def is_active(self) -> bool:
        """Whether a session is currently in progress."""
        return self._active is not None

    @property
    def active_cat_ids(self) -> list[str]:
        """Cat IDs participating in the current session, for ``StatusUpdate``.

        Empty list when no session is active or the cat has not been
        identified yet (its :class:`IdentityRequest` has not arrived
        or returned a match).
        """
        if self._active is None or not self._active.cat_id:
            return []
        return [self._active.cat_id]

    # -------------------------------------------------------------------
    # Internals
    # -------------------------------------------------------------------

    def _monotonic(self) -> float:
        return self._clock()

    def _wall(self) -> int:
        return int(self._wall_clock())

    def _engine_config_for_reset(self) -> EngineConfig:
        # Re-use a default; cat-specific overrides only apply during
        # a session and are restored to defaults at session end.
        return EngineConfig()

    def _consume_manual_arm(self) -> bool:
        if self._manual_arm_until <= self._monotonic():
            self._manual_arm_until = 0.0
            return False
        self._manual_arm_until = 0.0
        return True

    def _clock_reading(self) -> ClockReading:
        epoch = self._wall()
        # Convert epoch seconds to local-wall ISO weekday + minute.
        # Use local time so the schedule UI's "Mon 09:00" lines up
        # with the device's wall clock.
        struct_time = time.localtime(epoch)
        # tm_wday: 0 = Mon. ISO weekday: 1 = Mon.
        iso_weekday = struct_time.tm_wday + 1
        minute_of_day = struct_time.tm_hour * 60 + struct_time.tm_min
        return ClockReading(epoch=epoch, weekday=iso_weekday, minute=minute_of_day)

    def _handle_track_lost(self, lost: det.TrackLost) -> OutboundMessages:
        if self._active is None or lost.track_id != self._active.track_id:
            _logger.debug(
                "track_lost id=%d (not the active target)",
                lost.track_id,
            )
            return OutboundMessages()
        self._engine.on_track_lost(lost.track_id, self._monotonic())
        return OutboundMessages()

    def _handle_identity_request(
        self,
        req: det.IdentityRequest,
    ) -> OutboundMessages:
        try:
            match: MatchResult = self._catalog.match_embedding(
                req.embedding,
                req.confidence,
            )
        except ValueError:
            _logger.exception(
                "identity request rejected (malformed embedding) for track %d",
                req.track_id,
            )
            # Reply with empty cat_id so Rust does not wait forever.
            match = MatchResult(cat_id="", similarity=-1.0)

        if self._active is not None and self._active.track_id == req.track_id and match.cat_id:
            self._active.cat_id = match.cat_id

        result = det.IdentityResult(
            track_id=req.track_id,
            cat_id=match.cat_id,
            similarity=match.similarity,
        )
        return OutboundMessages(identity_results=(result,))

    def _reject(self, reason: SkipReason) -> OutboundMessages:
        ack = det.SessionAck(
            accept=False,
            skip_reason=_skip_reason_to_proto(reason),
        )
        return OutboundMessages(session_acks=(ack,))

    def _reject_decision(self, decision: SessionDecision) -> OutboundMessages:
        # `accept=False` always carries a skip_reason from the evaluator.
        # A missing reason falls back to COOLDOWN (the safest default —
        # Rust treats it as "try again soon").
        reason = decision.skip_reason if decision.skip_reason is not None else SkipReason.COOLDOWN
        return self._reject(reason)

    def _accept_session(
        self,
        track_id: int,
        *,
        manual: bool,
        trigger: SessionTrigger,
    ) -> OutboundMessages:
        session_id = uuid.uuid4().hex
        start_epoch = self._wall()
        chute = next_chute_side(self._conn)
        # Trigger label persisted in SQLite. Manual app-initiated wins
        # over the proto trigger so the history view can distinguish
        # "user clicked play" from "device auto-detected the cat."
        db_trigger = "manual" if manual else _trigger_to_db(trigger)
        create_session(self._conn, session_id, start_epoch, db_trigger)

        profile = None  # Resolved when IdentityRequest arrives.
        self._engine.start_session(
            target_track_id=track_id,
            chute_side=chute,
            now=self._monotonic(),
            profile=profile,
        )
        # Engine.start_session doesn't return None — it emits the
        # initial lure command. We discard that command here because
        # the next DetectionFrame produces a fresh one a few frames
        # later anyway, and emitting the lure on the same tick as the
        # SessionAck would arrive at Rust before its session_state
        # transitions to Active. The session state transition timing
        # is documented in the Rust pipeline.
        # ChuteSide is only imported lazily to avoid an enum import
        # at module load — store as a typed-object reference so the
        # ``_ActiveSession`` dataclass's ``object`` field is honoured.
        active_chute: object = chute
        self._active = _ActiveSession(
            session_id=session_id,
            cat_id="",
            chute_side=active_chute,
            start_time_epoch=start_epoch,
            track_id=track_id,
        )
        ack = det.SessionAck(accept=True)
        _logger.info(
            "session accepted: id=%s trigger=%s track=%d chute=%s",
            session_id,
            db_trigger,
            track_id,
            chute.value,
        )
        return OutboundMessages(session_acks=(ack,))

    def _finalize(self, result: SessionResult) -> None:
        active = self._active
        if active is None:
            _logger.warning("session_ended without an active session; ignoring")
            return

        from catlaser_brain.behavior.state_machine import ChuteSide  # noqa: PLC0415

        chute = active.chute_side
        if not isinstance(chute, ChuteSide):
            _logger.error(
                "session %s active chute is not a ChuteSide; cannot finalize",
                active.session_id,
            )
            self._active = None
            return

        if active.cat_id:
            try:
                # Trigger the catalog cache reload via load_profile so
                # the cat exists check fires before finalize_session
                # touches the DB.
                load_profile(self._conn, active.cat_id)
            except LookupError:
                _logger.warning(
                    "active cat %s missing from catalog; finalising without per-cat update",
                    active.cat_id,
                )
                active.cat_id = ""

        if active.cat_id:
            finalize_session(
                self._conn,
                session_id=active.session_id,
                cat_id=active.cat_id,
                result=result,
                chute_side=chute,
                start_time=active.start_time_epoch,
            )
        else:
            _finalize_anonymous(
                self._conn,
                session_id=active.session_id,
                result=result,
                chute_side=chute,
                start_time=active.start_time_epoch,
                end_time=self._wall(),
            )

        self._pending_finalized = SessionFinalized(
            cat_ids=(active.cat_id,) if active.cat_id else (),
            duration_sec=max(0, self._wall() - active.start_time_epoch),
            engagement_score=result.engagement_score,
            treats_dispensed=result.dispense_rotations,
            pounce_count=result.pounce_count,
            ended_at=self._wall(),
        )
        _logger.info(
            "session finalised: id=%s cat=%s engagement=%.2f treats=%d",
            active.session_id,
            active.cat_id or "<anonymous>",
            result.engagement_score,
            result.dispense_rotations,
        )
        self._active = None


# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------


def _find_target_cat(
    frame: det.DetectionFrame,
    target_track_id: int,
) -> CatObservation | None:
    """Return the :class:`CatObservation` for the target track, if present."""
    if target_track_id == 0:
        return None
    for cat in frame.cats:
        if cat.track_id != target_track_id:
            continue
        # Engine velocities are normalized-frame per second to match the
        # Rust pipeline's outbound DetectionFrame contract.
        return CatObservation(
            center_x=cat.center_x,
            center_y=cat.center_y,
            velocity_x=cat.velocity_x,
            velocity_y=cat.velocity_y,
        )
    return None


def _command_to_proto(command: Command) -> det.BehaviorCommand:
    """Map the engine's :class:`Command` dataclass to the proto wire form."""
    proto_mode = _targeting_mode_to_proto(command.mode)
    return det.BehaviorCommand(
        mode=proto_mode,
        offset_x=command.offset_x,
        offset_y=command.offset_y,
        smoothing=command.smoothing,
        max_speed=command.max_speed,
        laser_on=command.laser_on,
        target_track_id=command.target_track_id,
        lead_target_x=command.lead_target_x,
        lead_target_y=command.lead_target_y,
        dispense_rotations=command.dispense_rotations,
    )


def _targeting_mode_to_proto(mode: TargetingMode) -> det.TargetingMode:
    match mode:
        case TargetingMode.IDLE:
            return det.TARGETING_MODE_IDLE
        case TargetingMode.TRACK:
            return det.TARGETING_MODE_TRACK
        case TargetingMode.LEAD_TO_POINT:
            return det.TARGETING_MODE_LEAD_TO_POINT
        case TargetingMode.DISPENSE:
            return det.TARGETING_MODE_DISPENSE


def _trigger_from_proto(trigger: int) -> SessionTrigger:
    if trigger == det.SESSION_TRIGGER_SCHEDULED:
        return SessionTrigger.SCHEDULED
    return SessionTrigger.CAT_DETECTED


def _trigger_to_db(trigger: SessionTrigger) -> str:
    if trigger is SessionTrigger.SCHEDULED:
        return "scheduled"
    return "cat_detected"


def _skip_reason_to_proto(reason: SkipReason) -> det.SkipReason:
    if reason is SkipReason.COOLDOWN:
        return det.SKIP_REASON_COOLDOWN
    if reason is SkipReason.HOPPER_EMPTY:
        return det.SKIP_REASON_HOPPER_EMPTY
    return det.SKIP_REASON_QUIET_HOURS


def _finalize_anonymous(
    conn: sqlite3.Connection,
    *,
    session_id: str,
    result: SessionResult,
    chute_side: object,
    start_time: int,
    end_time: int,
) -> None:
    """Close a session row when the cat could not be identified.

    Mirrors :func:`finalize_session` minus the per-cat updates and the
    ``session_cats`` link (which would fail the foreign-key check
    against an empty ``cat_id``). The chute alternation row still
    rotates so the next session uses the opposite side.
    """
    from catlaser_brain.behavior.state_machine import ChuteSide  # noqa: PLC0415

    if not isinstance(chute_side, ChuteSide):
        msg = f"chute_side must be ChuteSide, got {type(chute_side).__name__}"
        raise TypeError(msg)

    duration = end_time - start_time
    conn.execute(
        "UPDATE chute_state SET last_side = ?, updated_at = ? WHERE id = 1",
        (chute_side.value, end_time),
    )
    conn.execute(
        "UPDATE sessions "
        "SET end_time = ?, duration_sec = ?, engagement_score = ?, "
        "    treats_dispensed = ?, pounce_count = ? "
        "WHERE session_id = ?",
        (
            end_time,
            duration,
            result.engagement_score,
            result.dispense_rotations,
            result.pounce_count,
            session_id,
        ),
    )
    conn.commit()


# Public API surface: the orchestrator and tests import these names.
__all__ = [
    "EngineOutput",
    "OutboundMessages",
    "SessionBridge",
    "SessionFinalized",
]
