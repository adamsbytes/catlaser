"""Tests for SQLite CRUD operations (storage layer for the app API)."""

from __future__ import annotations

import sqlite3
import struct
import time
from collections.abc import Iterator
from pathlib import Path

import pytest

from catlaser_brain.identity.catalog import EMBEDDING_BYTES, EMBEDDING_DIM
from catlaser_brain.storage.crud import (
    CatRow,
    PendingCatRow,
    ScheduleEntryRow,
    SessionRow,
    create_session,
    delete_cat,
    delete_pending_cat,
    get_cat,
    get_pending_cat,
    get_play_history,
    list_cats,
    list_pending_cats,
    list_schedule,
    resolve_pending_cat,
    set_schedule,
    store_pending_cat,
    update_cat,
)
from catlaser_brain.storage.db import Database

# ---------------------------------------------------------------------------
# Fixtures and helpers
# ---------------------------------------------------------------------------


@pytest.fixture
def conn(tmp_path: Path) -> Iterator[sqlite3.Connection]:
    db = Database.connect(tmp_path / "test.db")
    yield db.conn
    db.close()


def _insert_cat(
    conn: sqlite3.Connection,
    cat_id: str = "cat-1",
    *,
    name: str = "TestCat",
    thumbnail: bytes = b"\xff\xd8test",
    created_at: int | None = None,
) -> None:
    now = created_at if created_at is not None else int(time.time())
    conn.execute(
        "INSERT INTO cats "
        "(cat_id, name, thumbnail, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (cat_id, name, thumbnail, now, now),
    )
    conn.commit()


def _insert_completed_session(
    conn: sqlite3.Connection,
    session_id: str,
    *,
    start_time: int,
    duration_sec: int = 60,
    cat_ids: tuple[str, ...] = (),
) -> None:
    end_time = start_time + duration_sec
    conn.execute(
        "INSERT INTO sessions "
        "(session_id, start_time, end_time, duration_sec, engagement_score, "
        "treats_dispensed, pounce_count, trigger) "
        "VALUES (?, ?, ?, ?, 0.5, 5, 3, 'cat_detected')",
        (session_id, start_time, end_time, duration_sec),
    )
    for cid in cat_ids:
        conn.execute(
            "INSERT INTO session_cats (session_id, cat_id) VALUES (?, ?)",
            (session_id, cid),
        )
    conn.commit()


def _make_embedding_bytes() -> bytes:
    """Create a valid 512-byte embedding (128 LE f32s)."""
    return struct.pack(f"<{EMBEDDING_DIM}f", *([0.1] * EMBEDDING_DIM))


# ---------------------------------------------------------------------------
# Cat profile CRUD
# ---------------------------------------------------------------------------


class TestGetCat:
    def test_nonexistent_returns_none(self, conn: sqlite3.Connection):
        assert get_cat(conn, "no-such-cat") is None

    def test_returns_cat_row(self, conn: sqlite3.Connection):
        _insert_cat(conn, "cat-1", name="Whiskers")
        cat = get_cat(conn, "cat-1")
        assert cat is not None
        assert isinstance(cat, CatRow)
        assert cat.cat_id == "cat-1"
        assert cat.name == "Whiskers"

    def test_all_fields_populated(self, conn: sqlite3.Connection):
        _insert_cat(conn, "cat-1", name="Luna", thumbnail=b"\xff\xd8luna")
        cat = get_cat(conn, "cat-1")
        assert cat is not None
        assert cat.thumbnail == b"\xff\xd8luna"
        assert cat.preferred_speed == 1.0
        assert cat.preferred_smoothing == 0.5
        assert cat.pattern_randomness == 0.5
        assert cat.total_sessions == 0
        assert cat.total_play_time_sec == 0
        assert cat.total_treats == 0
        assert cat.created_at > 0
        assert cat.updated_at > 0


class TestListCats:
    def test_empty_returns_empty_list(self, conn: sqlite3.Connection):
        assert list_cats(conn) == []

    def test_single_cat(self, conn: sqlite3.Connection):
        _insert_cat(conn, "cat-1")
        cats = list_cats(conn)
        assert len(cats) == 1
        assert cats[0].cat_id == "cat-1"

    def test_multiple_cats_ordered_by_created_at(
        self,
        conn: sqlite3.Connection,
    ):
        _insert_cat(conn, "cat-b", name="Second", created_at=2000)
        _insert_cat(conn, "cat-a", name="First", created_at=1000)
        _insert_cat(conn, "cat-c", name="Third", created_at=3000)
        cats = list_cats(conn)
        assert len(cats) == 3
        assert cats[0].cat_id == "cat-a"
        assert cats[1].cat_id == "cat-b"
        assert cats[2].cat_id == "cat-c"


class TestUpdateCat:
    def test_update_name(self, conn: sqlite3.Connection):
        _insert_cat(conn, "cat-1", name="OldName")
        update_cat(conn, "cat-1", name="NewName")
        cat = get_cat(conn, "cat-1")
        assert cat is not None
        assert cat.name == "NewName"

    def test_update_thumbnail(self, conn: sqlite3.Connection):
        _insert_cat(conn, "cat-1", thumbnail=b"\xff\xd8old")
        update_cat(conn, "cat-1", thumbnail=b"\xff\xd8new")
        cat = get_cat(conn, "cat-1")
        assert cat is not None
        assert cat.thumbnail == b"\xff\xd8new"

    def test_update_name_and_thumbnail(self, conn: sqlite3.Connection):
        _insert_cat(conn, "cat-1", name="Old", thumbnail=b"\xff\xd8old")
        update_cat(conn, "cat-1", name="New", thumbnail=b"\xff\xd8new")
        cat = get_cat(conn, "cat-1")
        assert cat is not None
        assert cat.name == "New"
        assert cat.thumbnail == b"\xff\xd8new"

    def test_preserves_unchanged_fields(self, conn: sqlite3.Connection):
        _insert_cat(conn, "cat-1", name="Keep", thumbnail=b"\xff\xd8keep")
        update_cat(conn, "cat-1", name="Changed")
        cat = get_cat(conn, "cat-1")
        assert cat is not None
        assert cat.name == "Changed"
        assert cat.thumbnail == b"\xff\xd8keep"

    def test_refreshes_updated_at(self, conn: sqlite3.Connection):
        _insert_cat(conn, "cat-1", created_at=1000)
        before = int(time.time())
        update_cat(conn, "cat-1", name="Updated")
        cat = get_cat(conn, "cat-1")
        assert cat is not None
        assert cat.updated_at >= before

    def test_nonexistent_raises_lookup_error(
        self,
        conn: sqlite3.Connection,
    ):
        with pytest.raises(LookupError, match="no-such-cat"):
            update_cat(conn, "no-such-cat", name="Fail")


class TestDeleteCat:
    def test_removes_cat(self, conn: sqlite3.Connection):
        _insert_cat(conn, "cat-1")
        delete_cat(conn, "cat-1")
        assert get_cat(conn, "cat-1") is None

    def test_cascades_to_embeddings(self, conn: sqlite3.Connection):
        _insert_cat(conn, "cat-1")
        emb = _make_embedding_bytes()
        conn.execute(
            "INSERT INTO cat_embeddings (cat_id, embedding, captured_at) VALUES (?, ?, ?)",
            ("cat-1", emb, int(time.time())),
        )
        conn.commit()
        count_before = conn.execute(
            "SELECT COUNT(*) FROM cat_embeddings WHERE cat_id = 'cat-1'",
        ).fetchone()[0]
        assert count_before == 1

        delete_cat(conn, "cat-1")

        count_after = conn.execute(
            "SELECT COUNT(*) FROM cat_embeddings WHERE cat_id = 'cat-1'",
        ).fetchone()[0]
        assert count_after == 0

    def test_cascades_to_session_cats(self, conn: sqlite3.Connection):
        _insert_cat(conn, "cat-1")
        now = int(time.time())
        _insert_completed_session(
            conn,
            "s-1",
            start_time=now,
            cat_ids=("cat-1",),
        )

        delete_cat(conn, "cat-1")

        links = conn.execute(
            "SELECT COUNT(*) FROM session_cats WHERE cat_id = 'cat-1'",
        ).fetchone()[0]
        assert links == 0

    def test_nonexistent_is_idempotent(self, conn: sqlite3.Connection):
        delete_cat(conn, "no-such-cat")


# ---------------------------------------------------------------------------
# Session CRUD
# ---------------------------------------------------------------------------


class TestCreateSession:
    def test_inserts_open_session(self, conn: sqlite3.Connection):
        now = int(time.time())
        create_session(conn, "s-1", now, "manual")
        row = conn.execute(
            "SELECT session_id, start_time, end_time, trigger "
            "FROM sessions WHERE session_id = 's-1'",
        ).fetchone()
        assert row is not None
        assert row["session_id"] == "s-1"
        assert row["start_time"] == now
        assert row["end_time"] is None
        assert row["trigger"] == "manual"

    def test_all_trigger_types(self, conn: sqlite3.Connection):
        now = int(time.time())
        for trigger in ("scheduled", "cat_detected", "manual"):
            sid = f"s-{trigger}"
            create_session(conn, sid, now, trigger)
            row = conn.execute(
                "SELECT trigger FROM sessions WHERE session_id = ?",
                (sid,),
            ).fetchone()
            assert row["trigger"] == trigger

    def test_duplicate_id_raises(self, conn: sqlite3.Connection):
        now = int(time.time())
        create_session(conn, "s-dup", now, "manual")
        with pytest.raises(sqlite3.IntegrityError):
            create_session(conn, "s-dup", now, "manual")


class TestGetPlayHistory:
    def test_empty_returns_empty_list(self, conn: sqlite3.Connection):
        assert get_play_history(conn, 0, 9999999999) == []

    def test_returns_sessions_in_range(self, conn: sqlite3.Connection):
        _insert_cat(conn, "cat-1")
        _insert_completed_session(
            conn,
            "s-1",
            start_time=1000,
            cat_ids=("cat-1",),
        )
        _insert_completed_session(
            conn,
            "s-2",
            start_time=2000,
            cat_ids=("cat-1",),
        )
        history = get_play_history(conn, 0, 3000)
        assert len(history) == 2
        assert history[0].session_id == "s-1"
        assert history[1].session_id == "s-2"

    def test_excludes_sessions_outside_range(
        self,
        conn: sqlite3.Connection,
    ):
        _insert_cat(conn, "cat-1")
        _insert_completed_session(
            conn,
            "s-before",
            start_time=500,
            cat_ids=("cat-1",),
        )
        _insert_completed_session(
            conn,
            "s-in",
            start_time=1500,
            cat_ids=("cat-1",),
        )
        _insert_completed_session(
            conn,
            "s-after",
            start_time=3000,
            cat_ids=("cat-1",),
        )
        history = get_play_history(conn, 1000, 2000)
        assert len(history) == 1
        assert history[0].session_id == "s-in"

    def test_range_is_inclusive(self, conn: sqlite3.Connection):
        _insert_cat(conn, "cat-1")
        _insert_completed_session(
            conn,
            "s-start",
            start_time=1000,
            cat_ids=("cat-1",),
        )
        _insert_completed_session(
            conn,
            "s-end",
            start_time=2000,
            cat_ids=("cat-1",),
        )
        history = get_play_history(conn, 1000, 2000)
        assert len(history) == 2

    def test_excludes_incomplete_sessions(self, conn: sqlite3.Connection):
        now = int(time.time())
        create_session(conn, "s-open", now, "manual")
        history = get_play_history(conn, 0, now + 1000)
        assert len(history) == 0

    def test_includes_cat_ids(self, conn: sqlite3.Connection):
        _insert_cat(conn, "cat-1", name="Luna")
        _insert_completed_session(
            conn,
            "s-1",
            start_time=1000,
            cat_ids=("cat-1",),
        )
        history = get_play_history(conn, 0, 2000)
        assert len(history) == 1
        assert history[0].cat_ids == ("cat-1",)

    def test_multiple_cats_per_session(self, conn: sqlite3.Connection):
        _insert_cat(conn, "cat-a", name="Luna")
        _insert_cat(conn, "cat-b", name="Milo")
        _insert_completed_session(
            conn,
            "s-1",
            start_time=1000,
            cat_ids=("cat-a", "cat-b"),
        )
        history = get_play_history(conn, 0, 2000)
        assert len(history) == 1
        assert sorted(history[0].cat_ids) == ["cat-a", "cat-b"]

    def test_session_with_no_cats(self, conn: sqlite3.Connection):
        _insert_completed_session(
            conn,
            "s-solo",
            start_time=1000,
            cat_ids=(),
        )
        history = get_play_history(conn, 0, 2000)
        assert len(history) == 1
        assert history[0].cat_ids == ()

    def test_session_row_fields(self, conn: sqlite3.Connection):
        _insert_cat(conn, "cat-1")
        conn.execute(
            "INSERT INTO sessions "
            "(session_id, start_time, end_time, duration_sec, engagement_score, "
            "treats_dispensed, pounce_count, trigger) "
            "VALUES ('s-1', 1000, 1060, 60, 0.75, 7, 5, 'scheduled')",
        )
        conn.execute(
            "INSERT INTO session_cats (session_id, cat_id) VALUES ('s-1', 'cat-1')",
        )
        conn.commit()
        history = get_play_history(conn, 0, 2000)
        assert len(history) == 1
        s = history[0]
        assert isinstance(s, SessionRow)
        assert s.session_id == "s-1"
        assert s.start_time == 1000
        assert s.end_time == 1060
        assert s.duration_sec == 60
        assert s.engagement_score == 0.75
        assert s.treats_dispensed == 7
        assert s.pounce_count == 5
        assert s.trigger == "scheduled"

    def test_ordered_by_start_time(self, conn: sqlite3.Connection):
        _insert_completed_session(conn, "s-late", start_time=3000)
        _insert_completed_session(conn, "s-early", start_time=1000)
        _insert_completed_session(conn, "s-mid", start_time=2000)
        history = get_play_history(conn, 0, 4000)
        assert [s.session_id for s in history] == [
            "s-early",
            "s-mid",
            "s-late",
        ]


# ---------------------------------------------------------------------------
# Schedule CRUD
# ---------------------------------------------------------------------------


class TestListSchedule:
    def test_empty_returns_empty_list(self, conn: sqlite3.Connection):
        assert list_schedule(conn) == []

    def test_returns_all_entries_including_disabled(
        self,
        conn: sqlite3.Connection,
    ):
        entries = [
            ScheduleEntryRow("e-1", 480, 30, (1, 3, 5), enabled=True),
            ScheduleEntryRow("e-2", 1200, 20, (), enabled=False),
        ]
        set_schedule(conn, entries)
        result = list_schedule(conn)
        assert len(result) == 2
        disabled = [e for e in result if not e.enabled]
        assert len(disabled) == 1
        assert disabled[0].entry_id == "e-2"

    def test_ordered_by_start_minute(self, conn: sqlite3.Connection):
        entries = [
            ScheduleEntryRow("e-late", 1200, 30, (), enabled=True),
            ScheduleEntryRow("e-early", 480, 30, (), enabled=True),
        ]
        set_schedule(conn, entries)
        result = list_schedule(conn)
        assert result[0].entry_id == "e-early"
        assert result[1].entry_id == "e-late"


class TestSetSchedule:
    def test_replaces_existing_entries(self, conn: sqlite3.Connection):
        old = [ScheduleEntryRow("old-1", 480, 30, (), enabled=True)]
        set_schedule(conn, old)
        assert len(list_schedule(conn)) == 1

        new = [
            ScheduleEntryRow("new-1", 600, 20, (), enabled=True),
            ScheduleEntryRow("new-2", 900, 15, (), enabled=True),
        ]
        set_schedule(conn, new)
        result = list_schedule(conn)
        assert len(result) == 2
        assert {e.entry_id for e in result} == {"new-1", "new-2"}

    def test_empty_list_clears_all(self, conn: sqlite3.Connection):
        entries = [ScheduleEntryRow("e-1", 480, 30, (), enabled=True)]
        set_schedule(conn, entries)
        assert len(list_schedule(conn)) == 1

        set_schedule(conn, [])
        assert list_schedule(conn) == []

    def test_preserves_days(self, conn: sqlite3.Connection):
        entries = [
            ScheduleEntryRow("e-1", 480, 30, (1, 3, 5), enabled=True),
        ]
        set_schedule(conn, entries)
        result = list_schedule(conn)
        assert result[0].days == (1, 3, 5)

    def test_empty_days_means_every_day(self, conn: sqlite3.Connection):
        entries = [ScheduleEntryRow("e-1", 480, 30, (), enabled=True)]
        set_schedule(conn, entries)
        result = list_schedule(conn)
        assert result[0].days == ()

    def test_stores_enabled_flag(self, conn: sqlite3.Connection):
        entries = [
            ScheduleEntryRow("e-on", 480, 30, (), enabled=True),
            ScheduleEntryRow("e-off", 600, 30, (), enabled=False),
        ]
        set_schedule(conn, entries)
        result = list_schedule(conn)
        by_id = {e.entry_id: e for e in result}
        assert by_id["e-on"].enabled is True
        assert by_id["e-off"].enabled is False

    def test_round_trip_preserves_all_fields(
        self,
        conn: sqlite3.Connection,
    ):
        original = ScheduleEntryRow(
            entry_id="e-1",
            start_minute=1380,
            duration_min=120,
            days=(1, 2, 3, 4, 5),
            enabled=True,
        )
        set_schedule(conn, [original])
        result = list_schedule(conn)
        assert len(result) == 1
        assert result[0] == original


# ---------------------------------------------------------------------------
# Pending cat CRUD
# ---------------------------------------------------------------------------


class TestStorePendingCat:
    def test_inserts_pending_cat(self, conn: sqlite3.Connection):
        store_pending_cat(conn, 42, b"\xff\xd8thumb", 0.85)
        pending = get_pending_cat(conn, 42)
        assert pending is not None
        assert pending.track_id_hint == 42
        assert pending.thumbnail == b"\xff\xd8thumb"
        assert pending.confidence == 0.85
        assert pending.embedding is None
        assert pending.detected_at > 0

    def test_with_embedding(self, conn: sqlite3.Connection):
        emb = _make_embedding_bytes()
        store_pending_cat(conn, 42, b"\xff\xd8thumb", 0.9, embedding=emb)
        pending = get_pending_cat(conn, 42)
        assert pending is not None
        assert pending.embedding is not None
        assert pending.embedding == emb
        assert len(pending.embedding) == EMBEDDING_BYTES

    def test_upsert_replaces_existing(self, conn: sqlite3.Connection):
        store_pending_cat(conn, 42, b"\xff\xd8old", 0.5)
        store_pending_cat(conn, 42, b"\xff\xd8new", 0.9)
        pending = get_pending_cat(conn, 42)
        assert pending is not None
        assert pending.thumbnail == b"\xff\xd8new"
        assert pending.confidence == 0.9

        count = conn.execute(
            "SELECT COUNT(*) FROM pending_cats WHERE track_id_hint = 42",
        ).fetchone()[0]
        assert count == 1


class TestGetPendingCat:
    def test_nonexistent_returns_none(self, conn: sqlite3.Connection):
        assert get_pending_cat(conn, 999) is None

    def test_returns_pending_cat_row(self, conn: sqlite3.Connection):
        store_pending_cat(conn, 42, b"\xff\xd8thumb", 0.85)
        pending = get_pending_cat(conn, 42)
        assert pending is not None
        assert isinstance(pending, PendingCatRow)


class TestListPendingCats:
    def test_empty_returns_empty_list(self, conn: sqlite3.Connection):
        assert list_pending_cats(conn) == []

    def test_multiple_ordered_by_detected_at(
        self,
        conn: sqlite3.Connection,
    ):
        store_pending_cat(conn, 10, b"\xff\xd8a", 0.8)
        store_pending_cat(conn, 20, b"\xff\xd8b", 0.9)
        store_pending_cat(conn, 30, b"\xff\xd8c", 0.7)
        pending = list_pending_cats(conn)
        assert len(pending) == 3
        assert pending[0].track_id_hint == 10
        assert pending[2].track_id_hint == 30


class TestResolvePendingCat:
    def test_creates_cat_with_embedding(self, conn: sqlite3.Connection):
        emb = _make_embedding_bytes()
        store_pending_cat(conn, 42, b"\xff\xd8thumb", 0.9, embedding=emb)

        resolve_pending_cat(conn, 42, "cat-new", "Whiskers")

        cat = get_cat(conn, "cat-new")
        assert cat is not None
        assert cat.name == "Whiskers"
        assert cat.thumbnail == b"\xff\xd8thumb"
        assert cat.created_at > 0

        emb_row = conn.execute(
            "SELECT embedding FROM cat_embeddings WHERE cat_id = 'cat-new'",
        ).fetchone()
        assert emb_row is not None
        assert emb_row["embedding"] == emb

    def test_creates_cat_without_embedding(
        self,
        conn: sqlite3.Connection,
    ):
        store_pending_cat(conn, 42, b"\xff\xd8thumb", 0.5)

        resolve_pending_cat(conn, 42, "cat-new", "Shadow")

        cat = get_cat(conn, "cat-new")
        assert cat is not None
        assert cat.name == "Shadow"

        emb_count = conn.execute(
            "SELECT COUNT(*) FROM cat_embeddings WHERE cat_id = 'cat-new'",
        ).fetchone()[0]
        assert emb_count == 0

    def test_sets_embeddings_seen(self, conn: sqlite3.Connection):
        emb = _make_embedding_bytes()
        store_pending_cat(conn, 42, b"\xff\xd8thumb", 0.9, embedding=emb)
        resolve_pending_cat(conn, 42, "cat-new", "Boots")

        row = conn.execute(
            "SELECT embeddings_seen FROM cats WHERE cat_id = 'cat-new'",
        ).fetchone()
        assert row["embeddings_seen"] == 1

    def test_sets_zero_embeddings_seen_without_embedding(
        self,
        conn: sqlite3.Connection,
    ):
        store_pending_cat(conn, 42, b"\xff\xd8thumb", 0.5)
        resolve_pending_cat(conn, 42, "cat-new", "Boots")

        row = conn.execute(
            "SELECT embeddings_seen FROM cats WHERE cat_id = 'cat-new'",
        ).fetchone()
        assert row["embeddings_seen"] == 0

    def test_deletes_pending_row(self, conn: sqlite3.Connection):
        store_pending_cat(conn, 42, b"\xff\xd8thumb", 0.9)
        resolve_pending_cat(conn, 42, "cat-new", "Pepper")
        assert get_pending_cat(conn, 42) is None

    def test_nonexistent_raises_lookup_error(
        self,
        conn: sqlite3.Connection,
    ):
        with pytest.raises(LookupError, match="track_id_hint 999"):
            resolve_pending_cat(conn, 999, "cat-fail", "Fail")

    def test_cat_queryable_after_resolve(self, conn: sqlite3.Connection):
        emb = _make_embedding_bytes()
        store_pending_cat(conn, 42, b"\xff\xd8thumb", 0.9, embedding=emb)
        resolve_pending_cat(conn, 42, "cat-new", "Nala")

        cats = list_cats(conn)
        assert len(cats) == 1
        assert cats[0].cat_id == "cat-new"
        assert cats[0].name == "Nala"

    def test_atomic_on_duplicate_cat_id(self, conn: sqlite3.Connection):
        _insert_cat(conn, "cat-dup")
        store_pending_cat(conn, 42, b"\xff\xd8thumb", 0.9)

        with pytest.raises(sqlite3.IntegrityError):
            resolve_pending_cat(conn, 42, "cat-dup", "Duplicate")

        # Pending cat should still exist (transaction rolled back).
        assert get_pending_cat(conn, 42) is not None


class TestDeletePendingCat:
    def test_removes_pending_cat(self, conn: sqlite3.Connection):
        store_pending_cat(conn, 42, b"\xff\xd8thumb", 0.85)
        delete_pending_cat(conn, 42)
        assert get_pending_cat(conn, 42) is None

    def test_nonexistent_is_idempotent(self, conn: sqlite3.Connection):
        delete_pending_cat(conn, 999)


# ---------------------------------------------------------------------------
# Cross-table integrity
# ---------------------------------------------------------------------------


class TestCrossTableIntegrity:
    def test_delete_cat_preserves_session(self, conn: sqlite3.Connection):
        """Deleting a cat removes session_cats links but keeps session rows."""
        _insert_cat(conn, "cat-1")
        _insert_completed_session(
            conn,
            "s-1",
            start_time=1000,
            cat_ids=("cat-1",),
        )
        delete_cat(conn, "cat-1")

        session = conn.execute(
            "SELECT session_id FROM sessions WHERE session_id = 's-1'",
        ).fetchone()
        assert session is not None

        history = get_play_history(conn, 0, 2000)
        assert len(history) == 1
        assert history[0].cat_ids == ()

    def test_resolve_then_play_history(self, conn: sqlite3.Connection):
        """Resolved cat appears in play history after session finalization."""
        emb = _make_embedding_bytes()
        store_pending_cat(conn, 42, b"\xff\xd8thumb", 0.9, embedding=emb)
        resolve_pending_cat(conn, 42, "cat-new", "Pepper")

        _insert_completed_session(
            conn,
            "s-1",
            start_time=1000,
            cat_ids=("cat-new",),
        )
        history = get_play_history(conn, 0, 2000)
        assert len(history) == 1
        assert "cat-new" in history[0].cat_ids

    def test_schedule_set_then_list_round_trip(
        self,
        conn: sqlite3.Connection,
    ):
        entries = [
            ScheduleEntryRow("e-1", 480, 30, (1, 2, 3, 4, 5), enabled=True),
            ScheduleEntryRow("e-2", 1320, 60, (6, 7), enabled=True),
            ScheduleEntryRow("e-3", 0, 15, (), enabled=False),
        ]
        set_schedule(conn, entries)
        result = list_schedule(conn)
        assert len(result) == 3
        by_id = {e.entry_id: e for e in result}
        assert by_id["e-1"].days == (1, 2, 3, 4, 5)
        assert by_id["e-2"].start_minute == 1320
        assert by_id["e-3"].enabled is False
