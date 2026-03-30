"""Tests for dispense orchestration."""

from __future__ import annotations

import dataclasses
import sqlite3
import time
from collections.abc import Iterator
from pathlib import Path

import pytest

from catlaser_brain.behavior.dispense import (
    DispenseRecord,
    finalize_session,
    next_chute_side,
)
from catlaser_brain.behavior.profile import load_profile
from catlaser_brain.behavior.state_machine import ChuteSide, SessionResult
from catlaser_brain.storage.db import Database

# ---------------------------------------------------------------------------
# Helpers
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
    preferred_speed: float = 1.0,
    preferred_smoothing: float = 0.5,
    pattern_randomness: float = 0.5,
) -> None:
    now = int(time.time())
    conn.execute(
        "INSERT INTO cats "
        "(cat_id, name, thumbnail, preferred_speed, preferred_smoothing, "
        "pattern_randomness, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (
            cat_id,
            "TestCat",
            b"\xff\xd8test",
            preferred_speed,
            preferred_smoothing,
            pattern_randomness,
            now,
            now,
        ),
    )
    conn.commit()


def _insert_session(
    conn: sqlite3.Connection,
    session_id: str = "session-1",
    *,
    start_time: int | None = None,
    trigger: str = "cat_detected",
) -> int:
    if start_time is None:
        start_time = int(time.time())
    conn.execute(
        "INSERT INTO sessions (session_id, start_time, trigger) VALUES (?, ?, ?)",
        (session_id, start_time, trigger),
    )
    conn.commit()
    return start_time


_DEFAULT_RESULT = SessionResult(
    engagement_score=0.5,
    dispense_tier=1,
    dispense_rotations=5,
    active_play_time=30.0,
    avg_velocity=0.1,
    pounce_count=3,
    pounce_rate=0.1,
    time_on_target=0.5,
)


def _result(**overrides: float) -> SessionResult:
    return dataclasses.replace(_DEFAULT_RESULT, **overrides)


# ---------------------------------------------------------------------------
# next_chute_side
# ---------------------------------------------------------------------------


class TestNextChuteSide:
    def test_fresh_db_returns_right(self, conn: sqlite3.Connection):
        assert next_chute_side(conn) is ChuteSide.RIGHT

    def test_after_right_returns_left(self, conn: sqlite3.Connection):
        conn.execute(
            "UPDATE chute_state SET last_side = 'right' WHERE id = 1",
        )
        assert next_chute_side(conn) is ChuteSide.LEFT

    def test_after_left_returns_right(self, conn: sqlite3.Connection):
        conn.execute(
            "UPDATE chute_state SET last_side = 'left' WHERE id = 1",
        )
        assert next_chute_side(conn) is ChuteSide.RIGHT


# ---------------------------------------------------------------------------
# finalize_session -- database writes
# ---------------------------------------------------------------------------


class TestFinalizeSessionWrites:
    def test_updates_chute_state(self, conn: sqlite3.Connection):
        _insert_cat(conn)
        start = _insert_session(conn)
        finalize_session(
            conn,
            session_id="session-1",
            cat_id="cat-1",
            result=_result(),
            chute_side=ChuteSide.RIGHT,
            start_time=start,
        )
        row = conn.execute(
            "SELECT last_side FROM chute_state WHERE id = 1",
        ).fetchone()
        assert row["last_side"] == "right"

    def test_closes_session_row(self, conn: sqlite3.Connection):
        _insert_cat(conn)
        start = _insert_session(conn)
        finalize_session(
            conn,
            session_id="session-1",
            cat_id="cat-1",
            result=_result(
                engagement_score=0.75,
                dispense_rotations=7,
                pounce_count=5,
            ),
            chute_side=ChuteSide.LEFT,
            start_time=start,
        )
        row = conn.execute(
            "SELECT end_time, duration_sec, engagement_score, "
            "treats_dispensed, pounce_count FROM sessions "
            "WHERE session_id = 'session-1'",
        ).fetchone()
        assert row["end_time"] is not None
        assert row["duration_sec"] >= 0
        assert row["engagement_score"] == 0.75
        assert row["treats_dispensed"] == 7
        assert row["pounce_count"] == 5

    def test_increments_cat_total_sessions(self, conn: sqlite3.Connection):
        _insert_cat(conn)
        start = _insert_session(conn)
        finalize_session(
            conn,
            session_id="session-1",
            cat_id="cat-1",
            result=_result(),
            chute_side=ChuteSide.LEFT,
            start_time=start,
        )
        row = conn.execute(
            "SELECT total_sessions FROM cats WHERE cat_id = 'cat-1'",
        ).fetchone()
        assert row["total_sessions"] == 1

    def test_increments_cat_total_treats(self, conn: sqlite3.Connection):
        _insert_cat(conn)
        start = _insert_session(conn)
        finalize_session(
            conn,
            session_id="session-1",
            cat_id="cat-1",
            result=_result(dispense_rotations=7),
            chute_side=ChuteSide.LEFT,
            start_time=start,
        )
        row = conn.execute(
            "SELECT total_treats FROM cats WHERE cat_id = 'cat-1'",
        ).fetchone()
        assert row["total_treats"] == 7

    def test_increments_cat_play_time(self, conn: sqlite3.Connection):
        _insert_cat(conn)
        start = _insert_session(conn)
        finalize_session(
            conn,
            session_id="session-1",
            cat_id="cat-1",
            result=_result(active_play_time=45.7),
            chute_side=ChuteSide.LEFT,
            start_time=start,
        )
        row = conn.execute(
            "SELECT total_play_time_sec FROM cats WHERE cat_id = 'cat-1'",
        ).fetchone()
        assert row["total_play_time_sec"] == 45

    def test_chute_state_updated_at(self, conn: sqlite3.Connection):
        _insert_cat(conn)
        start = _insert_session(conn)
        before = int(time.time())
        finalize_session(
            conn,
            session_id="session-1",
            cat_id="cat-1",
            result=_result(),
            chute_side=ChuteSide.RIGHT,
            start_time=start,
        )
        row = conn.execute(
            "SELECT updated_at FROM chute_state WHERE id = 1",
        ).fetchone()
        assert row["updated_at"] >= before


# ---------------------------------------------------------------------------
# finalize_session -- return value
# ---------------------------------------------------------------------------


class TestFinalizeSessionRecord:
    def test_returns_dispense_record(self, conn: sqlite3.Connection):
        _insert_cat(conn)
        start = _insert_session(conn)
        record = finalize_session(
            conn,
            session_id="session-1",
            cat_id="cat-1",
            result=_result(dispense_tier=2, dispense_rotations=7),
            chute_side=ChuteSide.RIGHT,
            start_time=start,
        )
        assert isinstance(record, DispenseRecord)
        assert record.chute_side is ChuteSide.RIGHT
        assert record.tier == 2
        assert record.rotations == 7

    def test_tier_zero_dispenses_three_rotations(
        self,
        conn: sqlite3.Connection,
    ):
        _insert_cat(conn)
        start = _insert_session(conn)
        record = finalize_session(
            conn,
            session_id="session-1",
            cat_id="cat-1",
            result=_result(dispense_tier=0, dispense_rotations=3),
            chute_side=ChuteSide.LEFT,
            start_time=start,
        )
        assert record.rotations == 3
        row = conn.execute(
            "SELECT treats_dispensed FROM sessions WHERE session_id = 'session-1'",
        ).fetchone()
        assert row["treats_dispensed"] == 3

    def test_all_tiers(self, conn: sqlite3.Connection):
        _insert_cat(conn)
        for tier, rotations in [(0, 3), (1, 5), (2, 7)]:
            sid = f"s-tier-{tier}"
            start = _insert_session(conn, sid)
            record = finalize_session(
                conn,
                session_id=sid,
                cat_id="cat-1",
                result=_result(
                    dispense_tier=tier,
                    dispense_rotations=rotations,
                ),
                chute_side=ChuteSide.LEFT,
                start_time=start,
            )
            assert record.tier == tier
            assert record.rotations == rotations
            row = conn.execute(
                "SELECT treats_dispensed FROM sessions WHERE session_id = ?",
                (sid,),
            ).fetchone()
            assert row["treats_dispensed"] == rotations


# ---------------------------------------------------------------------------
# finalize_session -- profile adaptation
# ---------------------------------------------------------------------------


class TestFinalizeSessionProfile:
    def test_high_engagement_increases_speed(
        self,
        conn: sqlite3.Connection,
    ):
        _insert_cat(conn)
        start = _insert_session(conn)
        finalize_session(
            conn,
            session_id="session-1",
            cat_id="cat-1",
            result=_result(engagement_score=0.9),
            chute_side=ChuteSide.LEFT,
            start_time=start,
        )
        profile = load_profile(conn, "cat-1")
        assert profile.preferred_speed > 1.0

    def test_low_engagement_decreases_speed(
        self,
        conn: sqlite3.Connection,
    ):
        _insert_cat(conn)
        start = _insert_session(conn)
        finalize_session(
            conn,
            session_id="session-1",
            cat_id="cat-1",
            result=_result(engagement_score=0.1),
            chute_side=ChuteSide.LEFT,
            start_time=start,
        )
        profile = load_profile(conn, "cat-1")
        assert profile.preferred_speed < 1.0

    def test_low_time_on_target_increases_smoothing(
        self,
        conn: sqlite3.Connection,
    ):
        _insert_cat(conn)
        start = _insert_session(conn)
        finalize_session(
            conn,
            session_id="session-1",
            cat_id="cat-1",
            result=_result(time_on_target=0.1),
            chute_side=ChuteSide.LEFT,
            start_time=start,
        )
        profile = load_profile(conn, "cat-1")
        assert profile.preferred_smoothing > 0.5

    def test_zero_pounce_rate_decreases_randomness(
        self,
        conn: sqlite3.Connection,
    ):
        _insert_cat(conn)
        start = _insert_session(conn)
        finalize_session(
            conn,
            session_id="session-1",
            cat_id="cat-1",
            result=_result(pounce_rate=0.0),
            chute_side=ChuteSide.LEFT,
            start_time=start,
        )
        profile = load_profile(conn, "cat-1")
        assert profile.pattern_randomness < 0.5

    def test_short_session_preserves_profile(
        self,
        conn: sqlite3.Connection,
    ):
        _insert_cat(
            conn,
            preferred_speed=1.5,
            preferred_smoothing=0.7,
            pattern_randomness=0.8,
        )
        start = _insert_session(conn)
        finalize_session(
            conn,
            session_id="session-1",
            cat_id="cat-1",
            result=_result(
                engagement_score=0.9,
                active_play_time=2.0,
            ),
            chute_side=ChuteSide.LEFT,
            start_time=start,
        )
        profile = load_profile(conn, "cat-1")
        assert profile.preferred_speed == 1.5
        assert profile.preferred_smoothing == 0.7
        assert profile.pattern_randomness == 0.8


# ---------------------------------------------------------------------------
# finalize_session -- accumulation and alternation
# ---------------------------------------------------------------------------


class TestFinalizeSessionAccumulation:
    def test_multiple_sessions_accumulate_stats(
        self,
        conn: sqlite3.Connection,
    ):
        _insert_cat(conn)
        start1 = _insert_session(conn, "s1")
        finalize_session(
            conn,
            session_id="s1",
            cat_id="cat-1",
            result=_result(dispense_rotations=3, active_play_time=20.0),
            chute_side=ChuteSide.LEFT,
            start_time=start1,
        )
        start2 = _insert_session(conn, "s2")
        finalize_session(
            conn,
            session_id="s2",
            cat_id="cat-1",
            result=_result(dispense_rotations=7, active_play_time=40.0),
            chute_side=ChuteSide.RIGHT,
            start_time=start2,
        )
        row = conn.execute(
            "SELECT total_sessions, total_play_time_sec, total_treats "
            "FROM cats WHERE cat_id = 'cat-1'",
        ).fetchone()
        assert row["total_sessions"] == 2
        assert row["total_play_time_sec"] == 60
        assert row["total_treats"] == 10

    def test_chute_alternation_across_sessions(
        self,
        conn: sqlite3.Connection,
    ):
        _insert_cat(conn)

        side1 = next_chute_side(conn)
        assert side1 is ChuteSide.RIGHT
        start1 = _insert_session(conn, "s1")
        finalize_session(
            conn,
            session_id="s1",
            cat_id="cat-1",
            result=_result(),
            chute_side=side1,
            start_time=start1,
        )

        side2 = next_chute_side(conn)
        assert side2 is ChuteSide.LEFT
        start2 = _insert_session(conn, "s2")
        finalize_session(
            conn,
            session_id="s2",
            cat_id="cat-1",
            result=_result(),
            chute_side=side2,
            start_time=start2,
        )

        side3 = next_chute_side(conn)
        assert side3 is ChuteSide.RIGHT

    def test_profile_evolves_across_sessions(
        self,
        conn: sqlite3.Connection,
    ):
        _insert_cat(conn)
        for i in range(10):
            sid = f"s-{i}"
            start = _insert_session(conn, sid)
            finalize_session(
                conn,
                session_id=sid,
                cat_id="cat-1",
                result=_result(engagement_score=0.95),
                chute_side=ChuteSide.LEFT,
                start_time=start,
            )
        profile = load_profile(conn, "cat-1")
        assert profile.preferred_speed > 1.5
