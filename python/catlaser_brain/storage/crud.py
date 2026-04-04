"""CRUD operations for the app API layer.

Provides typed data access for cat profiles, play sessions, schedule
entries, and pending cat identifications. These functions serve the
app-to-device API handlers (``app.proto``) and complement the
domain-specific data access in :mod:`~catlaser_brain.identity.catalog`,
:mod:`~catlaser_brain.behavior.profile`,
:mod:`~catlaser_brain.behavior.schedule`, and
:mod:`~catlaser_brain.behavior.dispense`.
"""

from __future__ import annotations

import dataclasses
import json
import time
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import sqlite3


# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True, slots=True)
class CatRow:
    """Cat profile with all stored fields.

    Maps to ``CatProfile`` in app.proto for the app API layer.
    """

    cat_id: str
    name: str
    thumbnail: bytes
    preferred_speed: float
    preferred_smoothing: float
    pattern_randomness: float
    total_sessions: int
    total_play_time_sec: int
    total_treats: int
    created_at: int
    updated_at: int


@dataclasses.dataclass(frozen=True, slots=True)
class SessionRow:
    """Completed play session with associated cat IDs.

    Maps to ``PlaySession`` in app.proto. Only completed sessions
    (``end_time IS NOT NULL``) are returned by :func:`get_play_history`.
    """

    session_id: str
    start_time: int
    end_time: int
    cat_ids: tuple[str, ...]
    duration_sec: int
    engagement_score: float
    treats_dispensed: int
    pounce_count: int
    trigger: str


@dataclasses.dataclass(frozen=True, slots=True)
class ScheduleEntryRow:
    """Auto-play schedule entry for the app API.

    Maps to ``ScheduleEntry`` in app.proto. Days are ISO weekday
    numbers (1=Monday through 7=Sunday); an empty tuple means every day.
    """

    entry_id: str
    start_minute: int
    duration_min: int
    days: tuple[int, ...]
    enabled: bool


@dataclasses.dataclass(frozen=True, slots=True)
class PendingCatRow:
    """Detected cat awaiting user naming via the app.

    Maps to ``NewCatDetected`` in app.proto.
    """

    track_id_hint: int
    thumbnail: bytes
    confidence: float
    embedding: bytes | None
    detected_at: int


# ---------------------------------------------------------------------------
# Cat profile CRUD
# ---------------------------------------------------------------------------

_CAT_COLUMNS: str = (
    "cat_id, name, thumbnail, preferred_speed, preferred_smoothing, "
    "pattern_randomness, total_sessions, total_play_time_sec, total_treats, "
    "created_at, updated_at"
)


def get_cat(conn: sqlite3.Connection, cat_id: str) -> CatRow | None:
    """Fetch a single cat profile by ID.

    Args:
        conn: SQLite connection with ``row_factory = sqlite3.Row``.
        cat_id: Cat identifier.

    Returns:
        The cat's profile, or ``None`` if not found.
    """
    row = conn.execute(
        f"SELECT {_CAT_COLUMNS} FROM cats WHERE cat_id = ?",  # noqa: S608
        (cat_id,),
    ).fetchone()
    if row is None:
        return None
    return _row_to_cat(row)


def list_cats(conn: sqlite3.Connection) -> list[CatRow]:
    """List all cat profiles ordered by creation time.

    Args:
        conn: SQLite connection with ``row_factory = sqlite3.Row``.

    Returns:
        All cat profiles, oldest first.
    """
    rows = conn.execute(
        f"SELECT {_CAT_COLUMNS} FROM cats ORDER BY created_at",  # noqa: S608
    ).fetchall()
    return [_row_to_cat(row) for row in rows]


def update_cat(
    conn: sqlite3.Connection,
    cat_id: str,
    *,
    name: str | None = None,
    thumbnail: bytes | None = None,
) -> None:
    """Update user-editable cat fields.

    Only provided (non-``None``) fields are changed. The ``updated_at``
    timestamp is always refreshed.

    Args:
        conn: SQLite connection.
        cat_id: Cat identifier (must exist).
        name: New display name, or ``None`` to keep current.
        thumbnail: New JPEG thumbnail, or ``None`` to keep current.

    Raises:
        LookupError: If *cat_id* does not exist.
    """
    now = int(time.time())
    result = conn.execute(
        "UPDATE cats "
        "SET name = COALESCE(?, name), thumbnail = COALESCE(?, thumbnail), "
        "    updated_at = ? "
        "WHERE cat_id = ?",
        (name, thumbnail, now, cat_id),
    )
    if result.rowcount == 0:
        msg = f"cat {cat_id} not found"
        raise LookupError(msg)
    conn.commit()


def delete_cat(conn: sqlite3.Connection, cat_id: str) -> None:
    """Delete a cat and all associated data.

    Cascading foreign keys remove related rows in ``cat_embeddings``
    and ``session_cats``. Idempotent: no error if the cat does not exist.

    Args:
        conn: SQLite connection.
        cat_id: Cat identifier.
    """
    conn.execute("DELETE FROM cats WHERE cat_id = ?", (cat_id,))
    conn.commit()


def _row_to_cat(row: sqlite3.Row) -> CatRow:
    """Convert a SQLite row to a CatRow."""
    return CatRow(
        cat_id=row["cat_id"],
        name=row["name"],
        thumbnail=row["thumbnail"],
        preferred_speed=row["preferred_speed"],
        preferred_smoothing=row["preferred_smoothing"],
        pattern_randomness=row["pattern_randomness"],
        total_sessions=row["total_sessions"],
        total_play_time_sec=row["total_play_time_sec"],
        total_treats=row["total_treats"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


# ---------------------------------------------------------------------------
# Session CRUD
# ---------------------------------------------------------------------------


def create_session(
    conn: sqlite3.Connection,
    session_id: str,
    start_time: int,
    trigger: str,
) -> None:
    """Insert an open session row at session start.

    The session is initially incomplete (``end_time`` is ``NULL``).
    It is closed by :func:`~catlaser_brain.behavior.dispense.finalize_session`
    when the behavior engine completes the play session.

    Args:
        conn: SQLite connection.
        session_id: Unique session identifier.
        start_time: Unix epoch seconds when the session started.
        trigger: How the session was initiated
            (``'scheduled'``, ``'cat_detected'``, or ``'manual'``).
    """
    conn.execute(
        "INSERT INTO sessions (session_id, start_time, trigger) VALUES (?, ?, ?)",
        (session_id, start_time, trigger),
    )
    conn.commit()


def get_play_history(
    conn: sqlite3.Connection,
    start_time: int,
    end_time: int,
) -> list[SessionRow]:
    """Query completed sessions within a time range.

    Returns only sessions where ``end_time IS NOT NULL`` and
    ``start_time`` falls within the inclusive range [*start_time*,
    *end_time*]. Each session includes its associated cat IDs from
    the ``session_cats`` junction table.

    Args:
        conn: SQLite connection with ``row_factory = sqlite3.Row``.
        start_time: Range start (epoch seconds, inclusive).
        end_time: Range end (epoch seconds, inclusive).

    Returns:
        Completed sessions within the range, oldest first.
    """
    rows = conn.execute(
        "SELECT s.session_id, s.start_time, s.end_time, s.duration_sec, "
        "s.engagement_score, s.treats_dispensed, s.pounce_count, s.trigger, "
        "GROUP_CONCAT(sc.cat_id) AS cat_ids "
        "FROM sessions s "
        "LEFT JOIN session_cats sc ON s.session_id = sc.session_id "
        "WHERE s.end_time IS NOT NULL "
        "AND s.start_time >= ? AND s.start_time <= ? "
        "GROUP BY s.session_id "
        "ORDER BY s.start_time",
        (start_time, end_time),
    ).fetchall()
    return [_row_to_session(row) for row in rows]


def _row_to_session(row: sqlite3.Row) -> SessionRow:
    """Convert a grouped SQLite row to a SessionRow."""
    cat_ids_raw: str | None = row["cat_ids"]
    cat_ids = tuple(cat_ids_raw.split(",")) if cat_ids_raw else ()
    return SessionRow(
        session_id=row["session_id"],
        start_time=row["start_time"],
        end_time=row["end_time"],
        cat_ids=cat_ids,
        duration_sec=row["duration_sec"],
        engagement_score=row["engagement_score"],
        treats_dispensed=row["treats_dispensed"],
        pounce_count=row["pounce_count"],
        trigger=row["trigger"],
    )


# ---------------------------------------------------------------------------
# Schedule CRUD
# ---------------------------------------------------------------------------


def list_schedule(conn: sqlite3.Connection) -> list[ScheduleEntryRow]:
    """List all schedule entries (enabled and disabled).

    Unlike :func:`~catlaser_brain.behavior.schedule.load_schedule` which
    returns only enabled entries for the behavior engine, this returns
    all entries for the app UI to display and manage.

    Args:
        conn: SQLite connection with ``row_factory = sqlite3.Row``.

    Returns:
        All schedule entries, ordered by start time.
    """
    rows = conn.execute(
        "SELECT entry_id, start_minute, duration_min, days, enabled "
        "FROM schedule_entries ORDER BY start_minute",
    ).fetchall()
    return [_row_to_schedule_entry(row) for row in rows]


def set_schedule(
    conn: sqlite3.Connection,
    entries: list[ScheduleEntryRow],
) -> None:
    """Atomically replace all schedule entries.

    Deletes all existing entries and inserts the provided list in a
    single transaction. Matches ``SetScheduleRequest`` semantics in
    app.proto: the app always sends the full schedule.

    Args:
        conn: SQLite connection.
        entries: Complete schedule to store.
    """
    conn.execute("DELETE FROM schedule_entries")
    for entry in entries:
        conn.execute(
            "INSERT INTO schedule_entries "
            "(entry_id, start_minute, duration_min, days, enabled) "
            "VALUES (?, ?, ?, ?, ?)",
            (
                entry.entry_id,
                entry.start_minute,
                entry.duration_min,
                json.dumps(list(entry.days)),
                int(entry.enabled),
            ),
        )
    conn.commit()


def _row_to_schedule_entry(row: sqlite3.Row) -> ScheduleEntryRow:
    """Convert a SQLite row to a ScheduleEntryRow."""
    days_json: str = row["days"]
    days: list[int] = json.loads(days_json)
    return ScheduleEntryRow(
        entry_id=row["entry_id"],
        start_minute=row["start_minute"],
        duration_min=row["duration_min"],
        days=tuple(days),
        enabled=bool(row["enabled"]),
    )


# ---------------------------------------------------------------------------
# Pending cat CRUD
# ---------------------------------------------------------------------------


def store_pending_cat(
    conn: sqlite3.Connection,
    track_id_hint: int,
    thumbnail: bytes,
    confidence: float,
    embedding: bytes | None = None,
) -> None:
    """Store a newly detected unknown cat awaiting user naming.

    Called when the identity catalog finds no match for a detected cat.
    The app is notified via ``NewCatDetected`` push so the user can
    name the cat via ``IdentifyNewCatRequest``.

    If a pending cat with the same *track_id_hint* already exists,
    it is replaced (upsert).

    Args:
        conn: SQLite connection.
        track_id_hint: Track ID from the SORT tracker.
        thumbnail: JPEG thumbnail crop of the detected cat.
        confidence: Embedding model confidence score.
        embedding: Raw 512-byte embedding, or ``None`` if unavailable.
    """
    now = int(time.time())
    conn.execute(
        "INSERT OR REPLACE INTO pending_cats "
        "(track_id_hint, thumbnail, confidence, embedding, detected_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (track_id_hint, thumbnail, confidence, embedding, now),
    )
    conn.commit()


def get_pending_cat(
    conn: sqlite3.Connection,
    track_id_hint: int,
) -> PendingCatRow | None:
    """Fetch a pending cat by track ID hint.

    Args:
        conn: SQLite connection with ``row_factory = sqlite3.Row``.
        track_id_hint: Track ID from the SORT tracker.

    Returns:
        The pending cat, or ``None`` if not found.
    """
    row = conn.execute(
        "SELECT track_id_hint, thumbnail, confidence, embedding, detected_at "
        "FROM pending_cats WHERE track_id_hint = ?",
        (track_id_hint,),
    ).fetchone()
    if row is None:
        return None
    return _row_to_pending_cat(row)


def list_pending_cats(conn: sqlite3.Connection) -> list[PendingCatRow]:
    """List all pending cats awaiting user naming.

    Args:
        conn: SQLite connection with ``row_factory = sqlite3.Row``.

    Returns:
        All pending cats, oldest first.
    """
    rows = conn.execute(
        "SELECT track_id_hint, thumbnail, confidence, embedding, detected_at "
        "FROM pending_cats ORDER BY detected_at",
    ).fetchall()
    return [_row_to_pending_cat(row) for row in rows]


def resolve_pending_cat(
    conn: sqlite3.Connection,
    track_id_hint: int,
    cat_id: str,
    name: str,
) -> None:
    """Name a pending cat, creating a real cat profile.

    Atomically reads the pending cat's thumbnail and embedding, creates
    a new entry in ``cats`` (and ``cat_embeddings`` if an embedding is
    present), then deletes the pending row. Serves the
    ``IdentifyNewCatRequest`` flow in app.proto.

    After calling this function, the caller should invalidate the
    :class:`~catlaser_brain.identity.catalog.CatCatalog` cache so the
    new cat is visible for future identity matching.

    Args:
        conn: SQLite connection with ``row_factory = sqlite3.Row``.
        track_id_hint: Track ID of the pending cat to resolve.
        cat_id: Unique identifier for the new cat (e.g. UUID).
        name: User-provided display name for the cat.

    Raises:
        LookupError: If no pending cat with *track_id_hint* exists.
    """
    row = conn.execute(
        "SELECT thumbnail, embedding FROM pending_cats WHERE track_id_hint = ?",
        (track_id_hint,),
    ).fetchone()
    if row is None:
        msg = f"pending cat with track_id_hint {track_id_hint} not found"
        raise LookupError(msg)

    thumbnail: bytes = row["thumbnail"]
    embedding: bytes | None = row["embedding"]
    now = int(time.time())

    has_embedding = embedding is not None
    conn.execute(
        "INSERT INTO cats "
        "(cat_id, name, thumbnail, embeddings_seen, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (cat_id, name, thumbnail, int(has_embedding), now, now),
    )

    if embedding is not None:
        conn.execute(
            "INSERT INTO cat_embeddings (cat_id, embedding, captured_at) VALUES (?, ?, ?)",
            (cat_id, embedding, now),
        )

    conn.execute(
        "DELETE FROM pending_cats WHERE track_id_hint = ?",
        (track_id_hint,),
    )
    conn.commit()


def delete_pending_cat(
    conn: sqlite3.Connection,
    track_id_hint: int,
) -> None:
    """Delete a pending cat without creating a real cat profile.

    Idempotent: no error if the pending cat does not exist.

    Args:
        conn: SQLite connection.
        track_id_hint: Track ID of the pending cat to remove.
    """
    conn.execute(
        "DELETE FROM pending_cats WHERE track_id_hint = ?",
        (track_id_hint,),
    )
    conn.commit()


def _row_to_pending_cat(row: sqlite3.Row) -> PendingCatRow:
    """Convert a SQLite row to a PendingCatRow."""
    embedding_raw = row["embedding"]
    return PendingCatRow(
        track_id_hint=row["track_id_hint"],
        thumbnail=row["thumbnail"],
        confidence=row["confidence"],
        embedding=bytes(embedding_raw) if embedding_raw is not None else None,
        detected_at=row["detected_at"],
    )


# ---------------------------------------------------------------------------
# Push token CRUD
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True, slots=True)
class PushTokenRow:
    """Registered push notification token.

    Maps to ``RegisterPushTokenRequest`` in app.proto. Each app instance
    registers its FCM (or APNs) token on connect so the device can send
    push notifications when the app is backgrounded or disconnected.
    """

    token: str
    platform: str
    registered_at: int


def register_push_token(
    conn: sqlite3.Connection,
    token: str,
    platform: str,
) -> None:
    """Register or update a push notification token.

    Upserts: if the token already exists, the platform and timestamp
    are updated. This handles token refresh (same device, new token)
    and platform correction.

    Args:
        conn: SQLite connection.
        token: FCM or APNs device token.
        platform: ``'fcm'`` or ``'apns'``.
    """
    now = int(time.time())
    conn.execute(
        "INSERT INTO push_tokens (token, platform, registered_at) "
        "VALUES (?, ?, ?) "
        "ON CONFLICT(token) DO UPDATE SET platform = excluded.platform, "
        "registered_at = excluded.registered_at",
        (token, platform, now),
    )
    conn.commit()


def unregister_push_token(conn: sqlite3.Connection, token: str) -> None:
    """Remove a push notification token.

    Idempotent: no error if the token does not exist.

    Args:
        conn: SQLite connection.
        token: Token to remove.
    """
    conn.execute("DELETE FROM push_tokens WHERE token = ?", (token,))
    conn.commit()


def list_push_tokens(conn: sqlite3.Connection) -> list[PushTokenRow]:
    """List all registered push tokens.

    Args:
        conn: SQLite connection with ``row_factory = sqlite3.Row``.

    Returns:
        All registered tokens, oldest first.
    """
    rows = conn.execute(
        "SELECT token, platform, registered_at FROM push_tokens ORDER BY registered_at",
    ).fetchall()
    return [
        PushTokenRow(
            token=row["token"],
            platform=row["platform"],
            registered_at=row["registered_at"],
        )
        for row in rows
    ]
