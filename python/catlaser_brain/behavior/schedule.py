"""Session scheduling for the behavior engine.

Reads auto-play schedule entries from SQLite and decides whether to accept
or skip incoming ``SessionRequest`` messages from the Rust vision daemon.

Schedule entries define time windows during which autonomous play is allowed.
Outside these windows, cat-detected sessions are rejected as quiet hours.
Scheduled sessions (where Rust already determined it's time) bypass the
quiet hours check but are still gated by hopper status and cooldown.

The decision logic is pure: all inputs (time, schedule, state) are injected.
A higher-level convenience function reads from SQLite and delegates to the
pure evaluator.
"""

from __future__ import annotations

import dataclasses
import enum
import json
from typing import TYPE_CHECKING, Final

if TYPE_CHECKING:
    import sqlite3


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------


class SkipReason(enum.Enum):
    """Reasons to skip a session request.

    Values correspond to ``SkipReason`` in detection.proto. The caller
    maps these to the protobuf enum when building ``SessionAck``.
    """

    COOLDOWN = "cooldown"
    HOPPER_EMPTY = "hopper_empty"
    QUIET_HOURS = "quiet_hours"


class SessionTrigger(enum.Enum):
    """Why Rust initiated a session request.

    Maps to ``SessionTrigger`` in detection.proto.
    """

    SCHEDULED = "scheduled"
    CAT_DETECTED = "cat_detected"


# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True, slots=True)
class ScheduleEntry:
    """A single auto-play schedule window.

    Attributes:
        entry_id: Unique identifier.
        start_minute: Start time as minutes from midnight (0--1439).
        duration_min: Window duration in minutes (positive).
        days: ISO weekday numbers (1=Monday through 7=Sunday) on which
            this entry is active. Empty means every day.
        enabled: Whether this entry is active.
    """

    entry_id: str
    start_minute: int
    duration_min: int
    days: frozenset[int]
    enabled: bool


@dataclasses.dataclass(frozen=True, slots=True)
class SessionDecision:
    """Result of evaluating a session request.

    Attributes:
        accept: Whether to start the session.
        skip_reason: Set when *accept* is ``False``.
    """

    accept: bool
    skip_reason: SkipReason | None = None


@dataclasses.dataclass(frozen=True, slots=True)
class ClockReading:
    """Snapshot of the current wall clock for schedule evaluation.

    Groups the three time components needed by the evaluator so callers
    extract them once and pass a single object.

    Attributes:
        epoch: Current unix epoch seconds.
        weekday: ISO weekday (1=Monday through 7=Sunday).
        minute: Minutes since midnight (0--1439).
    """

    epoch: int
    weekday: int
    minute: int


@dataclasses.dataclass(frozen=True, slots=True)
class ScheduleConfig:
    """Session scheduling parameters.

    Attributes:
        session_cooldown_sec: Minimum seconds between a session ending
            and the next session starting. Prevents rapid re-triggering.
    """

    session_cooldown_sec: float = 300.0


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_ACCEPT: Final[SessionDecision] = SessionDecision(accept=True)

_MINUTES_PER_DAY: Final[int] = 1440

_DEFAULT_CONFIG: Final[ScheduleConfig] = ScheduleConfig()


# ---------------------------------------------------------------------------
# Schedule loading
# ---------------------------------------------------------------------------


def load_schedule(conn: sqlite3.Connection) -> list[ScheduleEntry]:
    """Load all enabled schedule entries from SQLite.

    Args:
        conn: SQLite connection with ``row_factory = sqlite3.Row``.

    Returns:
        Enabled schedule entries.
    """
    rows = conn.execute(
        "SELECT entry_id, start_minute, duration_min, days, enabled "
        "FROM schedule_entries WHERE enabled = 1",
    ).fetchall()
    return [_row_to_entry(row) for row in rows]


def _row_to_entry(row: sqlite3.Row) -> ScheduleEntry:
    """Convert a SQLite row to a ScheduleEntry."""
    days_raw: str = row["days"]
    days: list[int] = json.loads(days_raw)
    return ScheduleEntry(
        entry_id=row["entry_id"],
        start_minute=row["start_minute"],
        duration_min=row["duration_min"],
        days=frozenset(days),
        enabled=bool(row["enabled"]),
    )


def last_session_end_time(conn: sqlite3.Connection) -> int | None:
    """Read the most recent session end timestamp.

    Args:
        conn: SQLite connection with ``row_factory = sqlite3.Row``.

    Returns:
        Unix epoch seconds of the last completed session end, or
        ``None`` if no completed sessions exist.
    """
    row = conn.execute(
        "SELECT MAX(end_time) AS last_end FROM sessions WHERE end_time IS NOT NULL",
    ).fetchone()
    if row is None or row["last_end"] is None:
        return None
    result: int = row["last_end"]
    return result


# ---------------------------------------------------------------------------
# Window checking
# ---------------------------------------------------------------------------


def is_within_window(
    entry: ScheduleEntry,
    iso_weekday: int,
    minute_of_day: int,
) -> bool:
    """Check if a time falls within a schedule entry's window.

    Handles midnight-crossing windows correctly. A window starting at
    23:00 with a 120-minute duration spans to 01:00 the next day. The
    day-of-week check applies to the day on which the window *started*:
    the pre-midnight portion checks today, the post-midnight overflow
    checks yesterday.

    Args:
        entry: Schedule entry to check.
        iso_weekday: ISO weekday of the time being checked
            (1=Monday through 7=Sunday).
        minute_of_day: Minutes since midnight (0--1439).

    Returns:
        ``True`` if the time falls within the entry's window.
    """
    end_minute = entry.start_minute + entry.duration_min

    if end_minute <= _MINUTES_PER_DAY:
        # Same-day window.
        if entry.days and iso_weekday not in entry.days:
            return False
        return entry.start_minute <= minute_of_day < end_minute

    # Crosses midnight.
    # Pre-midnight portion: start_minute <= minute_of_day < 1440.
    if minute_of_day >= entry.start_minute:
        return not entry.days or iso_weekday in entry.days

    # Post-midnight overflow: 0 <= minute_of_day < overflow.
    overflow = end_minute - _MINUTES_PER_DAY
    if minute_of_day < overflow:
        yesterday = 7 if iso_weekday == 1 else iso_weekday - 1
        return not entry.days or yesterday in entry.days

    return False


def is_quiet_hours(
    schedule: list[ScheduleEntry],
    iso_weekday: int,
    minute_of_day: int,
) -> bool:
    """Check whether the current time is outside all schedule windows.

    When no enabled schedule entries exist, there are no quiet hours
    and the device is always active.

    Args:
        schedule: Enabled schedule entries.
        iso_weekday: ISO weekday (1=Monday through 7=Sunday).
        minute_of_day: Minutes since midnight (0--1439).

    Returns:
        ``True`` if in quiet hours (outside all windows).
    """
    if not schedule:
        return False
    return not any(is_within_window(entry, iso_weekday, minute_of_day) for entry in schedule)


# ---------------------------------------------------------------------------
# Session evaluation (pure)
# ---------------------------------------------------------------------------


def evaluate_session(
    trigger: SessionTrigger,
    *,
    schedule: list[ScheduleEntry],
    hopper_empty: bool,
    last_session_ended_at: int | None,
    clock: ClockReading,
    config: ScheduleConfig = _DEFAULT_CONFIG,
) -> SessionDecision:
    """Decide whether to accept or skip a session request.

    Checks are evaluated in priority order:

    1. **Hopper empty** -- blocks all sessions regardless of trigger.
    2. **Cooldown** -- prevents rapid re-triggering after a recent session.
    3. **Quiet hours** -- cat-detected sessions only; scheduled sessions
       bypass this check since Rust already determined it's time.

    Args:
        trigger: Why the session was requested.
        schedule: Enabled schedule entries from SQLite.
        hopper_empty: Whether the treat hopper is empty.
        last_session_ended_at: Unix epoch of last session end, or ``None``
            if no completed sessions exist.
        clock: Current wall clock snapshot.
        config: Scheduling parameters.

    Returns:
        Decision to accept or skip with reason.
    """
    if hopper_empty:
        return SessionDecision(accept=False, skip_reason=SkipReason.HOPPER_EMPTY)

    if (
        last_session_ended_at is not None
        and clock.epoch - last_session_ended_at < config.session_cooldown_sec
    ):
        return SessionDecision(accept=False, skip_reason=SkipReason.COOLDOWN)

    if trigger is SessionTrigger.CAT_DETECTED and is_quiet_hours(
        schedule,
        clock.weekday,
        clock.minute,
    ):
        return SessionDecision(accept=False, skip_reason=SkipReason.QUIET_HOURS)

    return _ACCEPT


# ---------------------------------------------------------------------------
# Convenience: evaluate with DB reads
# ---------------------------------------------------------------------------


def evaluate_session_request(
    conn: sqlite3.Connection,
    trigger: SessionTrigger,
    *,
    hopper_empty: bool,
    clock: ClockReading,
    config: ScheduleConfig = _DEFAULT_CONFIG,
) -> SessionDecision:
    """Load schedule state from SQLite and evaluate a session request.

    Combines :func:`load_schedule`, :func:`last_session_end_time`, and
    :func:`evaluate_session` into a single call for the IPC handler.

    Args:
        conn: SQLite connection with ``row_factory = sqlite3.Row``.
        trigger: Why the session was requested.
        hopper_empty: Whether the treat hopper is empty.
        clock: Current wall clock snapshot.
        config: Scheduling parameters.

    Returns:
        Decision to accept or skip with reason.
    """
    schedule = load_schedule(conn)
    ended_at = last_session_end_time(conn)
    return evaluate_session(
        trigger,
        schedule=schedule,
        hopper_empty=hopper_empty,
        last_session_ended_at=ended_at,
        clock=clock,
        config=config,
    )
