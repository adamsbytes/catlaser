"""SQLite schema and connection management for the catlaser brain.

Single database on the writable partition stores cat profiles, play sessions,
re-ID embeddings, auto-play schedule, dispenser chute alternation state, and
pending cat identifications awaiting user naming.
"""

from __future__ import annotations

import contextlib
import sqlite3
from pathlib import Path
from typing import Final, Self

# ---------------------------------------------------------------------------
# Schema v1: initial tables
# ---------------------------------------------------------------------------

_V1_SCHEMA: Final[str] = """\
CREATE TABLE cats (
    cat_id              TEXT    NOT NULL PRIMARY KEY,
    name                TEXT    NOT NULL,
    thumbnail           BLOB    NOT NULL CHECK(length(thumbnail) > 0),
    preferred_speed     REAL    NOT NULL DEFAULT 1.0,
    preferred_smoothing REAL    NOT NULL DEFAULT 0.5,
    pattern_randomness  REAL    NOT NULL DEFAULT 0.5,
    total_sessions      INTEGER NOT NULL DEFAULT 0,
    total_play_time_sec INTEGER NOT NULL DEFAULT 0,
    total_treats        INTEGER NOT NULL DEFAULT 0,
    embeddings_seen     INTEGER NOT NULL DEFAULT 0,
    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

CREATE TABLE cat_embeddings (
    id          INTEGER PRIMARY KEY,
    cat_id      TEXT    NOT NULL REFERENCES cats(cat_id) ON DELETE CASCADE,
    embedding   BLOB    NOT NULL CHECK(length(embedding) = 512),
    captured_at INTEGER NOT NULL
) STRICT;

CREATE INDEX idx_cat_embeddings_cat_id ON cat_embeddings(cat_id);

CREATE TABLE sessions (
    session_id       TEXT    NOT NULL PRIMARY KEY,
    start_time       INTEGER NOT NULL,
    end_time         INTEGER,
    duration_sec     INTEGER,
    engagement_score REAL,
    treats_dispensed INTEGER NOT NULL DEFAULT 0,
    pounce_count     INTEGER NOT NULL DEFAULT 0,
    trigger          TEXT    NOT NULL
        CHECK(trigger IN ('scheduled', 'cat_detected', 'manual'))
) STRICT, WITHOUT ROWID;

CREATE INDEX idx_sessions_start_time ON sessions(start_time);

CREATE TABLE session_cats (
    session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    cat_id     TEXT NOT NULL REFERENCES cats(cat_id) ON DELETE CASCADE,
    PRIMARY KEY (session_id, cat_id)
) STRICT, WITHOUT ROWID;

CREATE INDEX idx_session_cats_cat_id ON session_cats(cat_id);

CREATE TABLE schedule_entries (
    entry_id     TEXT    NOT NULL PRIMARY KEY,
    start_minute INTEGER NOT NULL CHECK(start_minute >= 0 AND start_minute <= 1439),
    duration_min INTEGER NOT NULL CHECK(duration_min > 0),
    days         TEXT    NOT NULL DEFAULT '[]',
    enabled      INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0, 1))
) STRICT, WITHOUT ROWID;

CREATE TABLE chute_state (
    id         INTEGER NOT NULL PRIMARY KEY CHECK(id = 1),
    last_side  TEXT    NOT NULL CHECK(last_side IN ('left', 'right')),
    updated_at INTEGER NOT NULL
) STRICT;

INSERT INTO chute_state (id, last_side, updated_at) VALUES (1, 'left', 0);

CREATE TABLE pending_cats (
    track_id_hint INTEGER NOT NULL PRIMARY KEY,
    thumbnail     BLOB    NOT NULL CHECK(length(thumbnail) > 0),
    confidence    REAL    NOT NULL,
    embedding     BLOB    CHECK(embedding IS NULL OR length(embedding) = 512),
    detected_at   INTEGER NOT NULL
) STRICT;
"""

# Ordered list of (version, sql). Each migration runs inside an explicit
# transaction via executescript. If a migration fails partway, the transaction
# is never committed and rolls back when the connection closes. On next
# startup the migration retries from the same version.
_MIGRATIONS: Final[tuple[tuple[int, str], ...]] = ((1, _V1_SCHEMA),)


# ---------------------------------------------------------------------------
# Migration runner
# ---------------------------------------------------------------------------


def _apply_migrations(conn: sqlite3.Connection) -> None:
    current_version: int = conn.execute("PRAGMA user_version").fetchone()[0]
    for version, sql in _MIGRATIONS:
        if version > current_version:
            conn.executescript(f"BEGIN;\n{sql}\nPRAGMA user_version = {version};\nCOMMIT;")
            current_version = version


# ---------------------------------------------------------------------------
# Database handle
# ---------------------------------------------------------------------------


class Database:
    """SQLite connection with schema migrations applied on connect.

    Use as a context manager for automatic resource cleanup::

        with Database.connect(Path("/data/catlaser/brain.db")) as db:
            row = db.conn.execute("SELECT ...").fetchone()
    """

    __slots__ = ("_conn",)

    def __init__(self, conn: sqlite3.Connection) -> None:
        self._conn = conn

    @classmethod
    def connect(cls, path: Path) -> Database:
        """Open or create the database at *path* and apply pending migrations."""
        path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(path))
        try:
            result = conn.execute("PRAGMA journal_mode = WAL").fetchone()
            if result is None or result[0] != "wal":
                msg = f"failed to enable WAL mode: {result}"
                raise RuntimeError(msg)
            conn.execute("PRAGMA foreign_keys = ON")
            conn.execute("PRAGMA busy_timeout = 5000")
            _apply_migrations(conn)
            conn.row_factory = sqlite3.Row
        except Exception:
            conn.close()
            raise
        return cls(conn)

    @property
    def conn(self) -> sqlite3.Connection:
        """Underlying SQLite connection."""
        return self._conn

    def close(self) -> None:
        """Checkpoint WAL to main file and close the connection."""
        # TRUNCATE requires exclusive access. If blocked by an open
        # transaction or concurrent connection, skip it — SQLite
        # recovers WAL contents automatically on next open.
        with contextlib.suppress(sqlite3.OperationalError):
            self._conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        self._conn.close()

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()
