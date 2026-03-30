"""Dispense orchestration for play session finalization.

Coordinates chute alternation (SQLite), session recording, cat stats
updates, and profile adaptation after the behavior engine completes a
play session. All session-end database writes happen here -- the state
machine remains pure.
"""

from __future__ import annotations

import dataclasses
import time
from typing import TYPE_CHECKING

from catlaser_brain.behavior.profile import adapt_profile, load_profile
from catlaser_brain.behavior.state_machine import ChuteSide

if TYPE_CHECKING:
    import sqlite3

    from catlaser_brain.behavior.state_machine import SessionResult


def next_chute_side(conn: sqlite3.Connection) -> ChuteSide:
    """Determine the next chute side from the alternation state.

    Reads the last-used side from ``chute_state`` and returns the
    opposite. The table is seeded with ``'left'`` on database creation,
    so the first session always dispenses to the right.

    Args:
        conn: SQLite connection with ``row_factory = sqlite3.Row``.

    Returns:
        The opposite of the last-used chute side.
    """
    row = conn.execute(
        "SELECT last_side FROM chute_state WHERE id = 1",
    ).fetchone()
    if row is None:
        msg = "chute_state row missing -- database not initialized"
        raise RuntimeError(msg)
    last_side: str = row["last_side"]
    if last_side == "left":
        return ChuteSide.RIGHT
    return ChuteSide.LEFT


@dataclasses.dataclass(frozen=True, slots=True)
class DispenseRecord:
    """Summary of a completed dispense for IPC and push notifications.

    Returned by ``finalize_session`` for the caller to build
    ``SessionEnd`` IPC messages and app push notifications.

    Attributes:
        chute_side: Which chute exit treats were dispensed from.
        tier: Engagement tier (0, 1, or 2).
        rotations: Disc rotation count (3, 5, or 7).
    """

    chute_side: ChuteSide
    tier: int
    rotations: int


def finalize_session(
    conn: sqlite3.Connection,
    *,
    session_id: str,
    cat_id: str,
    result: SessionResult,
    chute_side: ChuteSide,
    start_time: int,
) -> DispenseRecord:
    """Persist all session-end state after the behavior engine completes.

    Performs all writes in a single implicit transaction, committed
    atomically at the end:

    1. Updates ``chute_state`` to record the used side for alternation.
    2. Links the session to the cat via ``session_cats``.
    3. Closes the ``sessions`` row with end time, duration, engagement
       score, treats dispensed, and pounce count.
    4. Increments the cat's ``total_sessions``, ``total_play_time_sec``,
       and ``total_treats`` counters, and writes the adapted behavior
       profile.

    Profile adaptation is computed from the session's engagement metrics
    via ``adapt_profile``. Short sessions (below the minimum active time
    threshold) leave the profile unchanged.

    Args:
        conn: SQLite connection.
        session_id: Session row identifier (must already exist).
        cat_id: Cat identifier for stats and profile update.
        result: Session result from the behavior engine.
        chute_side: Which chute side was used for this session.
        start_time: Unix timestamp when the session started.

    Returns:
        A summary record for the caller to build IPC/push messages.
    """
    now = int(time.time())
    duration = now - start_time
    play_time_sec = round(result.active_play_time)

    profile = load_profile(conn, cat_id)
    adapted = adapt_profile(
        profile,
        engagement_score=result.engagement_score,
        time_on_target=result.time_on_target,
        pounce_rate=result.pounce_rate,
        active_play_time=result.active_play_time,
    )

    conn.execute(
        "UPDATE chute_state SET last_side = ?, updated_at = ? WHERE id = 1",
        (chute_side.value, now),
    )

    conn.execute(
        "INSERT INTO session_cats (session_id, cat_id) VALUES (?, ?)",
        (session_id, cat_id),
    )

    conn.execute(
        "UPDATE sessions "
        "SET end_time = ?, duration_sec = ?, engagement_score = ?, "
        "    treats_dispensed = ?, pounce_count = ? "
        "WHERE session_id = ?",
        (
            now,
            duration,
            result.engagement_score,
            result.dispense_rotations,
            result.pounce_count,
            session_id,
        ),
    )

    conn.execute(
        "UPDATE cats "
        "SET total_sessions = total_sessions + 1, "
        "    total_play_time_sec = total_play_time_sec + ?, "
        "    total_treats = total_treats + ?, "
        "    preferred_speed = ?, preferred_smoothing = ?, "
        "    pattern_randomness = ?, updated_at = ? "
        "WHERE cat_id = ?",
        (
            play_time_sec,
            result.dispense_rotations,
            adapted.preferred_speed,
            adapted.preferred_smoothing,
            adapted.pattern_randomness,
            now,
            cat_id,
        ),
    )

    conn.commit()

    return DispenseRecord(
        chute_side=chute_side,
        tier=result.dispense_tier,
        rotations=result.dispense_rotations,
    )
