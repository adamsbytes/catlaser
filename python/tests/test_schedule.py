"""Tests for session scheduling."""

from __future__ import annotations

import sqlite3
import time
from collections.abc import Iterator
from pathlib import Path

import pytest

from catlaser_brain.behavior.schedule import (
    ClockReading,
    ScheduleConfig,
    ScheduleEntry,
    SessionDecision,
    SessionTrigger,
    SkipReason,
    evaluate_session,
    evaluate_session_request,
    is_quiet_hours,
    is_within_window,
    last_session_end_time,
    load_schedule,
)
from catlaser_brain.storage.db import Database

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


@pytest.fixture
def conn(tmp_path: Path) -> Iterator[sqlite3.Connection]:
    db = Database.connect(tmp_path / "test.db")
    yield db.conn
    db.close()


def _insert_schedule_entry(
    conn: sqlite3.Connection,
    entry_id: str = "e1",
    *,
    start_minute: int = 480,
    duration_min: int = 60,
    days: str = "[]",
    enabled: int = 1,
) -> None:
    conn.execute(
        "INSERT INTO schedule_entries (entry_id, start_minute, duration_min, days, enabled) "
        "VALUES (?, ?, ?, ?, ?)",
        (entry_id, start_minute, duration_min, days, enabled),
    )
    conn.commit()


def _insert_session(
    conn: sqlite3.Connection,
    session_id: str = "session-1",
    *,
    start_time: int | None = None,
    end_time: int | None = None,
    trigger: str = "cat_detected",
) -> None:
    if start_time is None:
        start_time = int(time.time())
    conn.execute(
        "INSERT INTO sessions (session_id, start_time, end_time, trigger) VALUES (?, ?, ?, ?)",
        (session_id, start_time, end_time, trigger),
    )
    conn.commit()


def _entry(
    entry_id: str = "e1",
    *,
    start_minute: int = 480,
    duration_min: int = 60,
    days: frozenset[int] = frozenset(),
    enabled: bool = True,
) -> ScheduleEntry:
    return ScheduleEntry(
        entry_id=entry_id,
        start_minute=start_minute,
        duration_min=duration_min,
        days=days,
        enabled=enabled,
    )


# ---------------------------------------------------------------------------
# load_schedule
# ---------------------------------------------------------------------------


class TestLoadSchedule:
    def test_empty_table(self, conn: sqlite3.Connection):
        assert load_schedule(conn) == []

    def test_loads_enabled_entries(self, conn: sqlite3.Connection):
        _insert_schedule_entry(conn, "e1", start_minute=480, duration_min=60)
        entries = load_schedule(conn)
        assert len(entries) == 1
        assert entries[0].entry_id == "e1"
        assert entries[0].start_minute == 480
        assert entries[0].duration_min == 60
        assert entries[0].enabled is True

    def test_filters_disabled_entries(self, conn: sqlite3.Connection):
        _insert_schedule_entry(conn, "e1", enabled=1)
        _insert_schedule_entry(conn, "e2", enabled=0)
        entries = load_schedule(conn)
        assert len(entries) == 1
        assert entries[0].entry_id == "e1"

    def test_parses_days_json(self, conn: sqlite3.Connection):
        _insert_schedule_entry(conn, "e1", days="[1, 3, 5]")
        entries = load_schedule(conn)
        assert entries[0].days == frozenset({1, 3, 5})

    def test_empty_days_array(self, conn: sqlite3.Connection):
        _insert_schedule_entry(conn, "e1", days="[]")
        entries = load_schedule(conn)
        assert entries[0].days == frozenset()

    def test_multiple_entries(self, conn: sqlite3.Connection):
        _insert_schedule_entry(conn, "e1", start_minute=480, duration_min=60)
        _insert_schedule_entry(conn, "e2", start_minute=1080, duration_min=120)
        entries = load_schedule(conn)
        assert len(entries) == 2


# ---------------------------------------------------------------------------
# is_within_window -- same-day windows
# ---------------------------------------------------------------------------


class TestIsWithinWindowSameDay:
    def test_inside_window(self):
        entry = _entry(start_minute=480, duration_min=60)
        assert is_within_window(entry, iso_weekday=1, minute_of_day=500) is True

    def test_before_window(self):
        entry = _entry(start_minute=480, duration_min=60)
        assert is_within_window(entry, iso_weekday=1, minute_of_day=479) is False

    def test_after_window(self):
        entry = _entry(start_minute=480, duration_min=60)
        assert is_within_window(entry, iso_weekday=1, minute_of_day=540) is False

    def test_at_start_minute_inclusive(self):
        entry = _entry(start_minute=480, duration_min=60)
        assert is_within_window(entry, iso_weekday=1, minute_of_day=480) is True

    def test_at_end_minute_exclusive(self):
        entry = _entry(start_minute=480, duration_min=60)
        assert is_within_window(entry, iso_weekday=1, minute_of_day=540) is False

    def test_one_before_end(self):
        entry = _entry(start_minute=480, duration_min=60)
        assert is_within_window(entry, iso_weekday=1, minute_of_day=539) is True


# ---------------------------------------------------------------------------
# is_within_window -- day filtering
# ---------------------------------------------------------------------------


class TestIsWithinWindowDays:
    def test_matching_day(self):
        entry = _entry(start_minute=480, duration_min=60, days=frozenset({1, 3, 5}))
        assert is_within_window(entry, iso_weekday=3, minute_of_day=500) is True

    def test_non_matching_day(self):
        entry = _entry(start_minute=480, duration_min=60, days=frozenset({1, 3, 5}))
        assert is_within_window(entry, iso_weekday=2, minute_of_day=500) is False

    def test_empty_days_matches_all(self):
        entry = _entry(start_minute=480, duration_min=60, days=frozenset())
        assert is_within_window(entry, iso_weekday=4, minute_of_day=500) is True


# ---------------------------------------------------------------------------
# is_within_window -- midnight-crossing windows
# ---------------------------------------------------------------------------


class TestIsWithinWindowMidnight:
    def test_pre_midnight_portion(self):
        # 23:00 for 2 hours (23:00-01:00)
        entry = _entry(start_minute=1380, duration_min=120)
        assert is_within_window(entry, iso_weekday=5, minute_of_day=1400) is True

    def test_post_midnight_overflow(self):
        entry = _entry(start_minute=1380, duration_min=120)
        assert is_within_window(entry, iso_weekday=6, minute_of_day=30) is True

    def test_past_overflow(self):
        # Overflow ends at minute 60 (01:00)
        entry = _entry(start_minute=1380, duration_min=120)
        assert is_within_window(entry, iso_weekday=6, minute_of_day=90) is False

    def test_at_overflow_boundary_exclusive(self):
        # Overflow = 1380 + 120 - 1440 = 60
        entry = _entry(start_minute=1380, duration_min=120)
        assert is_within_window(entry, iso_weekday=6, minute_of_day=60) is False

    def test_midnight_with_days_pre_midnight(self):
        # Friday 23:00 - Saturday 01:00, days={5} (Friday)
        entry = _entry(start_minute=1380, duration_min=120, days=frozenset({5}))
        # Friday 23:30
        assert is_within_window(entry, iso_weekday=5, minute_of_day=1410) is True

    def test_midnight_with_days_post_midnight(self):
        # Friday 23:00 - Saturday 01:00, days={5} (Friday)
        entry = _entry(start_minute=1380, duration_min=120, days=frozenset({5}))
        # Saturday 00:30 -- yesterday was Friday which is in days
        assert is_within_window(entry, iso_weekday=6, minute_of_day=30) is True

    def test_midnight_with_days_wrong_day_pre(self):
        # Only Friday, but checking Thursday 23:30
        entry = _entry(start_minute=1380, duration_min=120, days=frozenset({5}))
        assert is_within_window(entry, iso_weekday=4, minute_of_day=1410) is False

    def test_midnight_with_days_wrong_day_post(self):
        # Only Friday, but checking Sunday 00:30 (yesterday=Saturday=6, not in {5})
        entry = _entry(start_minute=1380, duration_min=120, days=frozenset({5}))
        assert is_within_window(entry, iso_weekday=7, minute_of_day=30) is False

    def test_sunday_to_monday_overflow(self):
        # Sunday 23:00 - Monday 01:00, days={7} (Sunday)
        entry = _entry(start_minute=1380, duration_min=120, days=frozenset({7}))
        # Monday 00:30 -- yesterday was Sunday (7), prev_weekday(1) = 7
        assert is_within_window(entry, iso_weekday=1, minute_of_day=30) is True

    def test_between_windows_not_in_overflow(self):
        # 23:00-01:00 window, check at 12:00 (clearly outside)
        entry = _entry(start_minute=1380, duration_min=120)
        assert is_within_window(entry, iso_weekday=1, minute_of_day=720) is False


# ---------------------------------------------------------------------------
# is_quiet_hours
# ---------------------------------------------------------------------------


class TestIsQuietHours:
    def test_no_entries_never_quiet(self):
        assert is_quiet_hours([], iso_weekday=1, minute_of_day=180) is False

    def test_within_window_not_quiet(self):
        entries = [_entry(start_minute=480, duration_min=120)]
        assert is_quiet_hours(entries, iso_weekday=1, minute_of_day=500) is False

    def test_outside_all_windows_is_quiet(self):
        entries = [_entry(start_minute=480, duration_min=120)]
        assert is_quiet_hours(entries, iso_weekday=1, minute_of_day=700) is True

    def test_multiple_windows_within_one(self):
        entries = [
            _entry("e1", start_minute=480, duration_min=60),
            _entry("e2", start_minute=1080, duration_min=120),
        ]
        assert is_quiet_hours(entries, iso_weekday=1, minute_of_day=1100) is False

    def test_multiple_windows_outside_all(self):
        entries = [
            _entry("e1", start_minute=480, duration_min=60),
            _entry("e2", start_minute=1080, duration_min=120),
        ]
        assert is_quiet_hours(entries, iso_weekday=1, minute_of_day=800) is True


# ---------------------------------------------------------------------------
# last_session_end_time
# ---------------------------------------------------------------------------


class TestLastSessionEndTime:
    def test_no_sessions(self, conn: sqlite3.Connection):
        assert last_session_end_time(conn) is None

    def test_open_sessions_only(self, conn: sqlite3.Connection):
        _insert_session(conn, "s1", start_time=1000, end_time=None)
        assert last_session_end_time(conn) is None

    def test_completed_session(self, conn: sqlite3.Connection):
        _insert_session(conn, "s1", start_time=1000, end_time=1300)
        assert last_session_end_time(conn) == 1300

    def test_returns_most_recent(self, conn: sqlite3.Connection):
        _insert_session(conn, "s1", start_time=1000, end_time=1300)
        _insert_session(conn, "s2", start_time=2000, end_time=2500)
        _insert_session(conn, "s3", start_time=1500, end_time=1800)
        assert last_session_end_time(conn) == 2500

    def test_ignores_open_when_completed_exists(self, conn: sqlite3.Connection):
        _insert_session(conn, "s1", start_time=1000, end_time=1300)
        _insert_session(conn, "s2", start_time=2000, end_time=None)
        assert last_session_end_time(conn) == 1300


# ---------------------------------------------------------------------------
# evaluate_session -- pure decision logic
# ---------------------------------------------------------------------------


class TestEvaluateSession:
    def test_hopper_empty_blocks_all(self):
        decision = evaluate_session(
            SessionTrigger.CAT_DETECTED,
            schedule=[],
            hopper_empty=True,
            last_session_ended_at=None,
            clock=ClockReading(epoch=1000, weekday=1, minute=500),
        )
        assert decision.accept is False
        assert decision.skip_reason is SkipReason.HOPPER_EMPTY

    def test_hopper_empty_blocks_scheduled(self):
        decision = evaluate_session(
            SessionTrigger.SCHEDULED,
            schedule=[],
            hopper_empty=True,
            last_session_ended_at=None,
            clock=ClockReading(epoch=1000, weekday=1, minute=500),
        )
        assert decision.accept is False
        assert decision.skip_reason is SkipReason.HOPPER_EMPTY

    def test_cooldown_blocks_cat_detected(self):
        decision = evaluate_session(
            SessionTrigger.CAT_DETECTED,
            schedule=[],
            hopper_empty=False,
            last_session_ended_at=900,
            clock=ClockReading(epoch=1000, weekday=1, minute=500),
        )
        assert decision.accept is False
        assert decision.skip_reason is SkipReason.COOLDOWN

    def test_cooldown_blocks_scheduled(self):
        decision = evaluate_session(
            SessionTrigger.SCHEDULED,
            schedule=[],
            hopper_empty=False,
            last_session_ended_at=900,
            clock=ClockReading(epoch=1000, weekday=1, minute=500),
        )
        assert decision.accept is False
        assert decision.skip_reason is SkipReason.COOLDOWN

    def test_cooldown_expired_accepts(self):
        decision = evaluate_session(
            SessionTrigger.CAT_DETECTED,
            schedule=[],
            hopper_empty=False,
            last_session_ended_at=500,
            clock=ClockReading(epoch=1000, weekday=1, minute=500),
        )
        assert decision.accept is True

    def test_cooldown_boundary_exactly_at_threshold(self):
        config = ScheduleConfig(session_cooldown_sec=300.0)
        decision = evaluate_session(
            SessionTrigger.CAT_DETECTED,
            schedule=[],
            hopper_empty=False,
            last_session_ended_at=700,
            clock=ClockReading(epoch=1000, weekday=1, minute=500),
            config=config,
        )
        assert decision.accept is True

    def test_cooldown_one_second_before_threshold(self):
        config = ScheduleConfig(session_cooldown_sec=300.0)
        decision = evaluate_session(
            SessionTrigger.CAT_DETECTED,
            schedule=[],
            hopper_empty=False,
            last_session_ended_at=701,
            clock=ClockReading(epoch=1000, weekday=1, minute=500),
            config=config,
        )
        assert decision.accept is False
        assert decision.skip_reason is SkipReason.COOLDOWN

    def test_no_previous_session_skips_cooldown(self):
        decision = evaluate_session(
            SessionTrigger.CAT_DETECTED,
            schedule=[],
            hopper_empty=False,
            last_session_ended_at=None,
            clock=ClockReading(epoch=1000, weekday=1, minute=500),
        )
        assert decision.accept is True

    def test_cat_detected_quiet_hours_skips(self):
        schedule = [_entry(start_minute=480, duration_min=120)]
        decision = evaluate_session(
            SessionTrigger.CAT_DETECTED,
            schedule=schedule,
            hopper_empty=False,
            last_session_ended_at=None,
            clock=ClockReading(epoch=1000, weekday=1, minute=700),
        )
        assert decision.accept is False
        assert decision.skip_reason is SkipReason.QUIET_HOURS

    def test_cat_detected_within_window_accepts(self):
        schedule = [_entry(start_minute=480, duration_min=120)]
        decision = evaluate_session(
            SessionTrigger.CAT_DETECTED,
            schedule=schedule,
            hopper_empty=False,
            last_session_ended_at=None,
            clock=ClockReading(epoch=1000, weekday=1, minute=500),
        )
        assert decision.accept is True

    def test_scheduled_bypasses_quiet_hours(self):
        schedule = [_entry(start_minute=480, duration_min=120)]
        decision = evaluate_session(
            SessionTrigger.SCHEDULED,
            schedule=schedule,
            hopper_empty=False,
            last_session_ended_at=None,
            clock=ClockReading(epoch=1000, weekday=1, minute=700),
        )
        assert decision.accept is True

    def test_no_schedule_entries_no_quiet_hours(self):
        decision = evaluate_session(
            SessionTrigger.CAT_DETECTED,
            schedule=[],
            hopper_empty=False,
            last_session_ended_at=None,
            clock=ClockReading(epoch=1000, weekday=1, minute=180),
        )
        assert decision.accept is True

    def test_priority_hopper_over_cooldown(self):
        decision = evaluate_session(
            SessionTrigger.CAT_DETECTED,
            schedule=[],
            hopper_empty=True,
            last_session_ended_at=999,
            clock=ClockReading(epoch=1000, weekday=1, minute=500),
        )
        assert decision.skip_reason is SkipReason.HOPPER_EMPTY

    def test_priority_cooldown_over_quiet_hours(self):
        schedule = [_entry(start_minute=480, duration_min=120)]
        decision = evaluate_session(
            SessionTrigger.CAT_DETECTED,
            schedule=schedule,
            hopper_empty=False,
            last_session_ended_at=999,
            clock=ClockReading(epoch=1000, weekday=1, minute=700),
        )
        assert decision.skip_reason is SkipReason.COOLDOWN

    def test_all_clear_accepts(self):
        schedule = [_entry(start_minute=480, duration_min=120)]
        decision = evaluate_session(
            SessionTrigger.CAT_DETECTED,
            schedule=schedule,
            hopper_empty=False,
            last_session_ended_at=None,
            clock=ClockReading(epoch=1000, weekday=1, minute=500),
        )
        assert decision == SessionDecision(accept=True)

    def test_custom_cooldown(self):
        config = ScheduleConfig(session_cooldown_sec=60.0)
        decision = evaluate_session(
            SessionTrigger.CAT_DETECTED,
            schedule=[],
            hopper_empty=False,
            last_session_ended_at=950,
            clock=ClockReading(epoch=1000, weekday=1, minute=500),
            config=config,
        )
        assert decision.accept is False
        # But 61 seconds later it's fine
        decision2 = evaluate_session(
            SessionTrigger.CAT_DETECTED,
            schedule=[],
            hopper_empty=False,
            last_session_ended_at=950,
            clock=ClockReading(epoch=1011, weekday=1, minute=500),
            config=config,
        )
        assert decision2.accept is True


# ---------------------------------------------------------------------------
# evaluate_session_request -- integration with SQLite
# ---------------------------------------------------------------------------


class TestEvaluateSessionRequest:
    def test_accepts_with_empty_schedule(self, conn: sqlite3.Connection):
        decision = evaluate_session_request(
            conn,
            SessionTrigger.CAT_DETECTED,
            hopper_empty=False,
            clock=ClockReading(epoch=1000, weekday=1, minute=500),
        )
        assert decision.accept is True

    def test_rejects_hopper_empty(self, conn: sqlite3.Connection):
        decision = evaluate_session_request(
            conn,
            SessionTrigger.CAT_DETECTED,
            hopper_empty=True,
            clock=ClockReading(epoch=1000, weekday=1, minute=500),
        )
        assert decision.accept is False
        assert decision.skip_reason is SkipReason.HOPPER_EMPTY

    def test_rejects_during_cooldown(self, conn: sqlite3.Connection):
        _insert_session(conn, "s1", start_time=900, end_time=950)
        decision = evaluate_session_request(
            conn,
            SessionTrigger.CAT_DETECTED,
            hopper_empty=False,
            clock=ClockReading(epoch=1000, weekday=1, minute=500),
        )
        assert decision.accept is False
        assert decision.skip_reason is SkipReason.COOLDOWN

    def test_rejects_quiet_hours(self, conn: sqlite3.Connection):
        _insert_schedule_entry(conn, "e1", start_minute=480, duration_min=120)
        decision = evaluate_session_request(
            conn,
            SessionTrigger.CAT_DETECTED,
            hopper_empty=False,
            clock=ClockReading(epoch=100_000, weekday=1, minute=700),
        )
        assert decision.accept is False
        assert decision.skip_reason is SkipReason.QUIET_HOURS

    def test_scheduled_bypasses_quiet_hours_from_db(
        self,
        conn: sqlite3.Connection,
    ):
        _insert_schedule_entry(conn, "e1", start_minute=480, duration_min=120)
        decision = evaluate_session_request(
            conn,
            SessionTrigger.SCHEDULED,
            hopper_empty=False,
            clock=ClockReading(epoch=100_000, weekday=1, minute=700),
        )
        assert decision.accept is True

    def test_reads_schedule_and_last_session(
        self,
        conn: sqlite3.Connection,
    ):
        _insert_schedule_entry(conn, "e1", start_minute=480, duration_min=120)
        _insert_session(conn, "s1", start_time=900, end_time=950)
        # Cooldown expired, within schedule window
        decision = evaluate_session_request(
            conn,
            SessionTrigger.CAT_DETECTED,
            hopper_empty=False,
            clock=ClockReading(epoch=100_000, weekday=1, minute=500),
        )
        assert decision.accept is True

    def test_disabled_entries_ignored(self, conn: sqlite3.Connection):
        _insert_schedule_entry(conn, "e1", start_minute=480, duration_min=120, enabled=0)
        # All entries disabled = no quiet hours
        decision = evaluate_session_request(
            conn,
            SessionTrigger.CAT_DETECTED,
            hopper_empty=False,
            clock=ClockReading(epoch=100_000, weekday=1, minute=700),
        )
        assert decision.accept is True
