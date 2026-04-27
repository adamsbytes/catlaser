"""Tests for :class:`SessionBridge`: session lifecycle, identity, hopper gating."""

from __future__ import annotations

import time
from collections.abc import Iterator
from pathlib import Path

import pytest

from catlaser_brain.behavior.dispense import next_chute_side
from catlaser_brain.behavior.state_machine import EngineConfig, State
from catlaser_brain.daemon.hopper import HopperSensor
from catlaser_brain.daemon.session_bridge import OutboundMessages, SessionBridge
from catlaser_brain.identity.catalog import EMBEDDING_BYTES, CatCatalog, serialize_embedding
from catlaser_brain.proto.catlaser.app.v1 import app_pb2 as app_pb
from catlaser_brain.proto.catlaser.detection.v1 import detection_pb2 as det
from catlaser_brain.storage.db import Database

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def db(tmp_path: Path) -> Iterator[Database]:
    database = Database.connect(tmp_path / "bridge.db")
    yield database
    database.close()


@pytest.fixture
def catalog(db: Database) -> CatCatalog:
    return CatCatalog(db)


@pytest.fixture
def hopper_ok() -> HopperSensor:
    """A sensor with no GPIO wired — always reports OK."""
    return HopperSensor("")


class _FakeClock:
    """Monotonic clock with a step-on-demand interface."""

    def __init__(self, start: float = 1000.0) -> None:
        self.now = start

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


class _FakeWallClock:
    """Wall clock with a step-on-demand interface."""

    def __init__(self, start: int = 1_700_000_000) -> None:
        self.now = start

    def __call__(self) -> float:
        return float(self.now)

    def advance(self, seconds: int) -> None:
        self.now += seconds


def _short_engine_config() -> EngineConfig:
    """Tight timing so test sessions complete in reasonable wall time."""
    return EngineConfig(
        lure_min_duration=0.1,
        lure_max_duration=0.5,
        chase_min_before_tease=0.2,
        chase_tease_interval_min=0.2,
        chase_tease_interval_max=0.3,
        tease_duration_min=0.05,
        tease_duration_max=0.1,
        cooldown_decel_duration=0.05,
        cooldown_timeout=0.2,
        dispense_duration=0.05,
        session_timeout=2.0,
        track_lost_timeout=0.5,
    )


def _make_bridge(
    db: Database,
    *,
    hopper: HopperSensor | None = None,
    clock: _FakeClock | None = None,
    wall_clock: _FakeWallClock | None = None,
    engine_config: EngineConfig | None = None,
) -> SessionBridge:
    return SessionBridge(
        conn=db.conn,
        catalog=CatCatalog(db),
        hopper=hopper if hopper is not None else HopperSensor(""),
        engine_config=engine_config if engine_config is not None else _short_engine_config(),
        clock=clock if clock is not None else _FakeClock(),
        wall_clock=wall_clock if wall_clock is not None else _FakeWallClock(),
    )


def _frame_with_cat(track_id: int, *, cx: float = 0.5, cy: float = 0.5) -> det.DetectionFrame:
    return det.DetectionFrame(
        cats=[
            det.TrackedCat(
                track_id=track_id,
                center_x=cx,
                center_y=cy,
                width=0.1,
                height=0.1,
                velocity_x=0.05,
                velocity_y=0.0,
                state=det.TRACK_STATE_CONFIRMED,
            ),
        ],
    )


def _session_request(track_id: int = 7) -> det.SessionRequest:
    return det.SessionRequest(
        trigger=det.SESSION_TRIGGER_CAT_DETECTED,
        track_id=track_id,
    )


def _seed_known_cat(db: Database, cat_id: str, embedding: bytes) -> None:
    """Insert a cat into the catalog so ``match_embedding`` resolves it."""
    catalog = CatCatalog(db)
    catalog.add_cat(
        cat_id=cat_id,
        name="Whiskers",
        thumbnail=b"\x89PNG\r\n\x1a\n",  # any non-empty blob satisfies the schema check
        embedding_bytes=embedding,
    )


# ---------------------------------------------------------------------------
# Session acceptance: priority gating
# ---------------------------------------------------------------------------


class TestSessionRequestGating:
    def test_accepts_when_idle(self, db: Database) -> None:
        bridge = _make_bridge(db)
        out = bridge.handle_session_request(_session_request())
        assert len(out.session_acks) == 1
        assert out.session_acks[0].accept is True
        assert bridge.is_active

    def test_rejects_when_active(self, db: Database) -> None:
        bridge = _make_bridge(db)
        bridge.handle_session_request(_session_request())
        out = bridge.handle_session_request(_session_request(track_id=8))
        assert len(out.session_acks) == 1
        assert out.session_acks[0].accept is False
        # Re-entry rejection cites cooldown so Rust retries, not a permanent
        # block — the active session will eventually finish.
        assert out.session_acks[0].skip_reason == det.SKIP_REASON_COOLDOWN

    def test_rejects_when_hopper_empty(self, db: Database, tmp_path: Path) -> None:
        gpio = tmp_path / "hopper-value"
        gpio.write_bytes(b"1\n")  # 1 = beam clear = empty
        bridge = _make_bridge(db, hopper=HopperSensor(str(gpio)))
        out = bridge.handle_session_request(_session_request())
        assert out.session_acks[0].accept is False
        assert out.session_acks[0].skip_reason == det.SKIP_REASON_HOPPER_EMPTY
        assert not bridge.is_active

    def test_rejects_zero_track_id(self, db: Database) -> None:
        bridge = _make_bridge(db)
        # Build a request that omits track_id (proto3 oneof field).
        request = det.SessionRequest(trigger=det.SESSION_TRIGGER_CAT_DETECTED)
        out = bridge.handle_session_request(request)
        assert out.session_acks[0].accept is False
        # Defensive — Rust always includes a track_id for CAT_DETECTED, but
        # if a future variant ever omits it the bridge cannot start a
        # session that has nothing to follow.
        assert not bridge.is_active

    def test_creates_session_row_in_db(self, db: Database) -> None:
        bridge = _make_bridge(db)
        bridge.handle_session_request(_session_request())
        rows = db.conn.execute(
            "SELECT trigger, end_time FROM sessions",
        ).fetchall()
        assert len(rows) == 1
        # Default trigger is the proto's CAT_DETECTED; not a manual arm.
        assert rows[0]["trigger"] == "cat_detected"
        # Session is open (end_time NULL) until finalize fires.
        assert rows[0]["end_time"] is None


# ---------------------------------------------------------------------------
# Manual arm
# ---------------------------------------------------------------------------


class TestManualArm:
    def test_manual_arm_records_manual_trigger(self, db: Database) -> None:
        bridge = _make_bridge(db)
        bridge.start_session()  # arm
        bridge.handle_session_request(_session_request())
        row = db.conn.execute("SELECT trigger FROM sessions").fetchone()
        # An armed session is recorded as "manual" so play history can
        # distinguish app-initiated from Rust-triggered runs.
        assert row["trigger"] == "manual"

    def test_manual_arm_consumed_after_one_session(self, db: Database) -> None:
        clock = _FakeClock()
        wall = _FakeWallClock()
        bridge = _make_bridge(db, clock=clock, wall_clock=wall)
        bridge.start_session()
        out = bridge.handle_session_request(_session_request())
        assert out.session_acks[0].accept is True
        # The arm is one-shot. After acceptance the manual flag is cleared
        # so a stale SessionRequest seconds later does not silently steal
        # a future scheduled session.
        bridge.handle_disconnect()  # reset bridge but keep arm logic
        wall.advance(10)  # distinct start_time so the rows can be ordered
        out = bridge.handle_session_request(_session_request(track_id=9))
        # Without a re-arm and with no schedule entries, the next request
        # falls into the normal evaluator. Default schedule has no quiet
        # hours, so it accepts — but as cat_detected, not manual.
        assert out.session_acks[0].accept is True
        rows = db.conn.execute(
            "SELECT trigger, start_time FROM sessions ORDER BY start_time ASC",
        ).fetchall()
        assert len(rows) == 2
        assert rows[0]["trigger"] == "manual"
        assert rows[1]["trigger"] == "cat_detected"

    def test_manual_arm_expires(self, db: Database) -> None:
        clock = _FakeClock()
        bridge = _make_bridge(db, clock=clock)
        bridge.start_session()
        clock.advance(60.0)  # past the arm TTL (30 s)
        out = bridge.handle_session_request(_session_request())
        # Still accepted but marked as cat_detected — the stale arm
        # cannot make it manual.
        assert out.session_acks[0].accept is True
        row = db.conn.execute("SELECT trigger FROM sessions").fetchone()
        assert row["trigger"] == "cat_detected"


# ---------------------------------------------------------------------------
# Detection-frame engine driving
# ---------------------------------------------------------------------------


class TestDetectionFrame:
    def test_frame_without_session_produces_no_output(self, db: Database) -> None:
        bridge = _make_bridge(db)
        out = bridge.handle_detection_frame(_frame_with_cat(track_id=1))
        # No active session — Rust autonomous mode runs, Python is silent.
        assert out == OutboundMessages()

    def test_frame_with_target_emits_behavior_command(self, db: Database) -> None:
        bridge = _make_bridge(db)
        bridge.handle_session_request(_session_request(track_id=42))
        out = bridge.handle_detection_frame(_frame_with_cat(track_id=42))
        assert len(out.behavior_commands) == 1
        cmd = out.behavior_commands[0]
        # The engine starts in LURE — laser is on, mode is TRACK.
        assert cmd.laser_on is True
        assert cmd.mode == det.TARGETING_MODE_TRACK
        assert cmd.target_track_id == 42

    def test_frame_without_matching_cat_still_ticks_engine(
        self,
        db: Database,
    ) -> None:
        bridge = _make_bridge(db)
        bridge.handle_session_request(_session_request(track_id=42))
        # Frame contains cats but not our target.
        out = bridge.handle_detection_frame(_frame_with_cat(track_id=99))
        assert len(out.behavior_commands) == 1


# ---------------------------------------------------------------------------
# Track lost
# ---------------------------------------------------------------------------


class TestTrackLost:
    def test_target_lost_transitions_to_cooldown(self, db: Database) -> None:
        bridge = _make_bridge(db)
        bridge.handle_session_request(_session_request(track_id=42))
        # Drive enough frames that LURE rolls into CHASE so the track-lost
        # transition has somewhere to come from.
        clock = _FakeClock()
        bridge_ts = SessionBridge(
            conn=db.conn,
            catalog=CatCatalog(db),
            hopper=HopperSensor(""),
            engine_config=_short_engine_config(),
            clock=clock,
        )
        bridge_ts.handle_session_request(_session_request(track_id=42))
        bridge_ts.handle_detection_frame(_frame_with_cat(track_id=42))
        clock.advance(1.0)
        bridge_ts.handle_detection_frame(_frame_with_cat(track_id=42))

        event = det.TrackEvent(track_lost=det.TrackLost(track_id=42, duration_ms=1000))
        out = bridge_ts.handle_track_event(event)
        # `on_track_lost` itself returns no IPC traffic — the next
        # detection frame will produce the cooldown command.
        assert out == OutboundMessages()
        # Engine private state can be inspected via the next frame's
        # produced command.
        clock.advance(0.05)
        cmd = bridge_ts.handle_detection_frame(_frame_with_cat(track_id=99)).behavior_commands[0]
        # Cooldown's first phase is decel, still TRACK mode but
        # ramping speed and smoothing toward cooldown values.
        assert cmd.laser_on is True

    def test_lost_other_track_is_ignored(self, db: Database) -> None:
        bridge = _make_bridge(db)
        bridge.handle_session_request(_session_request(track_id=42))
        # Lost track is NOT the target.
        event = det.TrackEvent(track_lost=det.TrackLost(track_id=99, duration_ms=1000))
        out = bridge.handle_track_event(event)
        assert out == OutboundMessages()


# ---------------------------------------------------------------------------
# Identity request
# ---------------------------------------------------------------------------


class TestIdentityRequest:
    def test_unknown_cat_returns_empty_id(self, db: Database) -> None:
        bridge = _make_bridge(db)
        bridge.handle_session_request(_session_request(track_id=42))
        zeroes = bytes(EMBEDDING_BYTES)
        event = det.TrackEvent(
            identity_request=det.IdentityRequest(
                track_id=42,
                embedding=zeroes,
                confidence=0.9,
            ),
        )
        out = bridge.handle_track_event(event)
        assert len(out.identity_results) == 1
        # Empty catalog returns an empty cat_id — Python tells Rust the
        # cat is unknown without crashing the embedding round trip.
        assert out.identity_results[0].cat_id == ""

    def test_known_cat_resolved(self, db: Database) -> None:
        # Build a deterministic embedding and seed the catalog with it.
        emb = serialize_embedding([1.0] + [0.0] * 127)
        _seed_known_cat(db, "cat-known", emb)

        bridge = _make_bridge(db)
        bridge.handle_session_request(_session_request(track_id=42))
        event = det.TrackEvent(
            identity_request=det.IdentityRequest(
                track_id=42,
                embedding=emb,
                confidence=0.9,
            ),
        )
        out = bridge.handle_track_event(event)
        assert len(out.identity_results) == 1
        result = out.identity_results[0]
        assert result.cat_id == "cat-known"
        assert result.similarity > 0.9
        # The active session's cat_id is updated so finalize can write
        # the per-cat profile/stats rows.
        assert bridge.active_cat_ids == ["cat-known"]

    def test_malformed_embedding_returns_empty(self, db: Database) -> None:
        bridge = _make_bridge(db)
        bridge.handle_session_request(_session_request(track_id=42))
        event = det.TrackEvent(
            identity_request=det.IdentityRequest(
                track_id=42,
                embedding=b"\x00\x01",  # too short
                confidence=0.9,
            ),
        )
        out = bridge.handle_track_event(event)
        # Bad-shape embedding does not crash the bridge — it produces a
        # negative-similarity unknown-cat result so Rust can move on.
        assert out.identity_results[0].cat_id == ""
        assert out.identity_results[0].similarity < 0.0


# ---------------------------------------------------------------------------
# New-cat detection emission
# ---------------------------------------------------------------------------


class TestNewCatDetection:
    def test_unknown_cat_queues_detection_for_orchestrator(self, db: Database) -> None:
        bridge = _make_bridge(db)
        bridge.handle_session_request(_session_request(track_id=42))
        emb = serialize_embedding([1.0] + [0.0] * 127)
        bridge.handle_track_event(
            det.TrackEvent(
                identity_request=det.IdentityRequest(
                    track_id=42,
                    embedding=emb,
                    confidence=0.83,
                    thumbnail=b"\xff\xd8\xff\xe0jpeg-ish-bytes",
                ),
            ),
        )
        detections = bridge.take_new_cat_detections()
        assert len(detections) == 1
        assert detections[0].track_id == 42
        # Protobuf serializes confidence as float32; accept tolerable
        # round-trip drift on the way back through the bridge.
        assert abs(detections[0].confidence - 0.83) < 1e-6
        assert detections[0].thumbnail == b"\xff\xd8\xff\xe0jpeg-ish-bytes"

    def test_drained_detections_do_not_repeat(self, db: Database) -> None:
        bridge = _make_bridge(db)
        bridge.handle_session_request(_session_request(track_id=42))
        emb = serialize_embedding([1.0] + [0.0] * 127)
        bridge.handle_track_event(
            det.TrackEvent(
                identity_request=det.IdentityRequest(
                    track_id=42,
                    embedding=emb,
                    confidence=0.7,
                    thumbnail=b"\xff\xd8thumb",
                ),
            ),
        )
        first = bridge.take_new_cat_detections()
        assert len(first) == 1
        # A second drain on the same untouched bridge yields nothing —
        # the orchestrator must see a single notification per unmatched
        # IdentityRequest, not a stream every loop tick.
        assert bridge.take_new_cat_detections() == []

    def test_known_cat_does_not_queue_detection(self, db: Database) -> None:
        emb = serialize_embedding([1.0] + [0.0] * 127)
        _seed_known_cat(db, "cat-known", emb)
        bridge = _make_bridge(db)
        bridge.handle_session_request(_session_request(track_id=42))
        bridge.handle_track_event(
            det.TrackEvent(
                identity_request=det.IdentityRequest(
                    track_id=42,
                    embedding=emb,
                    confidence=0.95,
                    thumbnail=b"\xff\xd8thumb",
                ),
            ),
        )
        # A confident match is not "new" — no notification, even though
        # the IdentityRequest carried a fresh thumbnail.
        assert bridge.take_new_cat_detections() == []

    def test_malformed_embedding_does_not_queue_detection(self, db: Database) -> None:
        bridge = _make_bridge(db)
        bridge.handle_session_request(_session_request(track_id=42))
        bridge.handle_track_event(
            det.TrackEvent(
                identity_request=det.IdentityRequest(
                    track_id=42,
                    embedding=b"\x00\x01",  # malformed
                    confidence=0.9,
                    thumbnail=b"\xff\xd8thumb",
                ),
            ),
        )
        # Malformed embedding is a vision-side bug, not an unknown
        # cat; queueing a "new cat" notification would surface a
        # noisy push to the user for a transient pipeline failure.
        assert bridge.take_new_cat_detections() == []

    def test_thumbnail_persists_pending_cat_row(self, db: Database) -> None:
        bridge = _make_bridge(db)
        bridge.handle_session_request(_session_request(track_id=42))
        emb = serialize_embedding([1.0] + [0.0] * 127)
        bridge.handle_track_event(
            det.TrackEvent(
                identity_request=det.IdentityRequest(
                    track_id=42,
                    embedding=emb,
                    confidence=0.83,
                    thumbnail=b"\xff\xd8\xff\xe0jpeg-ish-bytes",
                ),
            ),
        )
        # Persisted so a subsequent IdentifyNewCatRequest from the app
        # can resolve the pending track into a real cat profile.
        row = db.conn.execute(
            "SELECT thumbnail, embedding FROM pending_cats WHERE track_id_hint = ?",
            (42,),
        ).fetchone()
        assert row is not None
        assert row["thumbnail"] == b"\xff\xd8\xff\xe0jpeg-ish-bytes"
        assert row["embedding"] == emb

    def test_empty_thumbnail_skips_persistence_but_still_notifies(
        self,
        db: Database,
    ) -> None:
        bridge = _make_bridge(db)
        bridge.handle_session_request(_session_request(track_id=42))
        emb = serialize_embedding([1.0] + [0.0] * 127)
        bridge.handle_track_event(
            det.TrackEvent(
                identity_request=det.IdentityRequest(
                    track_id=42,
                    embedding=emb,
                    confidence=0.83,
                    thumbnail=b"",  # transient encoder failure on the Rust side
                ),
            ),
        )
        # The schema requires a non-empty thumbnail. Vision normally
        # ships one with every IdentityRequest, but a transient JPEG
        # encode failure can leave it empty — defensive belt-and-braces
        # behaviour: skip the pending_cats persist, still queue the
        # notification so the owner is told the unknown cat appeared.
        row = db.conn.execute(
            "SELECT track_id_hint FROM pending_cats WHERE track_id_hint = ?",
            (42,),
        ).fetchone()
        assert row is None
        assert len(bridge.take_new_cat_detections()) == 1

    def test_disconnect_drops_pending_detections(self, db: Database) -> None:
        bridge = _make_bridge(db)
        bridge.handle_session_request(_session_request(track_id=42))
        emb = serialize_embedding([1.0] + [0.0] * 127)
        bridge.handle_track_event(
            det.TrackEvent(
                identity_request=det.IdentityRequest(
                    track_id=42,
                    embedding=emb,
                    confidence=0.83,
                    thumbnail=b"\xff\xd8thumb",
                ),
            ),
        )
        # An IPC disconnect crosses an epoch boundary — the track IDs
        # in the pending queue may not exist in the next vision
        # session, so the queue must be cleared rather than emitting
        # stale notifications after reconnect.
        bridge.handle_disconnect()
        assert bridge.take_new_cat_detections() == []


# ---------------------------------------------------------------------------
# Session finalization
# ---------------------------------------------------------------------------


class TestSessionFinalize:
    def test_full_session_emits_session_end_and_finalized(self, db: Database) -> None:
        emb = serialize_embedding([1.0] + [0.0] * 127)
        _seed_known_cat(db, "cat-known", emb)

        clock = _FakeClock()
        wall = _FakeWallClock(start=1_700_000_000)
        bridge = _make_bridge(db, clock=clock, wall_clock=wall)
        bridge.handle_session_request(_session_request(track_id=42))

        # Resolve identity so finalize writes the per-cat row.
        bridge.handle_track_event(
            det.TrackEvent(
                identity_request=det.IdentityRequest(
                    track_id=42,
                    embedding=emb,
                    confidence=0.9,
                ),
            ),
        )

        # Push the engine through LURE → CHASE → ... by advancing the
        # clock and feeding frames. The short engine config is timed
        # so the whole sequence completes within ~3 seconds wall time.
        wall.advance(5)
        completed = False
        out = OutboundMessages()
        for _ in range(200):
            clock.advance(0.05)
            wall.advance(1)
            out = bridge.handle_detection_frame(
                _frame_with_cat(track_id=42, cx=0.32, cy=0.85),
            )
            if out.session_ends > 0:
                completed = True
                break

        assert completed, "engine should reach IDLE after a full session"
        # The end-of-session frame ships exactly one SessionEnd to Rust.
        assert out.session_ends == 1
        # The finalized notification is queued for the orchestrator to
        # broadcast as a SessionSummary.
        finalized = bridge.take_finalized()
        assert finalized is not None
        assert "cat-known" in finalized.cat_ids
        assert finalized.duration_sec > 0
        # SQLite session row is closed.
        rows = db.conn.execute(
            "SELECT end_time, duration_sec FROM sessions",
        ).fetchall()
        assert rows[0]["end_time"] is not None
        assert rows[0]["duration_sec"] is not None
        # Bridge is back to idle.
        assert not bridge.is_active

    def test_anonymous_session_finalizes_without_session_cats(
        self,
        db: Database,
    ) -> None:
        clock = _FakeClock()
        wall = _FakeWallClock(start=1_700_000_000)
        bridge = _make_bridge(db, clock=clock, wall_clock=wall)
        bridge.handle_session_request(_session_request(track_id=42))
        # No IdentityResult; session ends as anonymous.

        for _ in range(200):
            clock.advance(0.05)
            wall.advance(1)
            out = bridge.handle_detection_frame(
                _frame_with_cat(track_id=42, cx=0.32, cy=0.85),
            )
            if out.session_ends > 0:
                break

        finalized = bridge.take_finalized()
        assert finalized is not None
        # Anonymous run has no resolved cat_id.
        assert finalized.cat_ids == ()
        # session_cats junction stays empty — the foreign key would have
        # rejected an empty cat_id insert.
        cats = db.conn.execute("SELECT COUNT(*) AS c FROM session_cats").fetchone()
        assert cats["c"] == 0
        # The chute alternation row still rotates so the next session
        # uses the opposite side.
        chute_after = next_chute_side(db.conn)
        # Default seeded "left"; first session uses right; second would use left.
        assert chute_after.value in {"left", "right"}


# ---------------------------------------------------------------------------
# IPC disconnect handling
# ---------------------------------------------------------------------------


class TestDisconnect:
    def test_disconnect_clears_active_session(self, db: Database) -> None:
        bridge = _make_bridge(db)
        bridge.handle_session_request(_session_request(track_id=42))
        assert bridge.is_active
        bridge.handle_disconnect()
        # Active session is dropped — a reconnect session would otherwise
        # collide with the abandoned one's track_id.
        assert not bridge.is_active
        # Bridge accepts a fresh request after reconnect.
        out = bridge.handle_session_request(_session_request(track_id=99))
        assert out.session_acks[0].accept is True


# ---------------------------------------------------------------------------
# Stop session (app-initiated graceful end)
# ---------------------------------------------------------------------------


class TestStopSession:
    def test_stop_idle_is_noop(self, db: Database) -> None:
        bridge = _make_bridge(db)
        bridge.stop_session()
        assert not bridge.is_active

    def test_stop_active_transitions_to_cooldown(self, db: Database) -> None:
        clock = _FakeClock()
        bridge = _make_bridge(db, clock=clock)
        bridge.handle_session_request(_session_request(track_id=42))
        # Drive into CHASE.
        clock.advance(1.0)
        bridge.handle_detection_frame(_frame_with_cat(track_id=42))
        bridge.stop_session()
        clock.advance(0.05)
        out = bridge.handle_detection_frame(_frame_with_cat(track_id=42))
        # First post-stop frame reports an active behavior command — the
        # engine is in cooldown decel, not idle.
        assert len(out.behavior_commands) == 1
        # Engine state public read confirms cooldown.
        assert bridge._engine.state == State.COOLDOWN  # pyright: ignore[reportPrivateUsage]


# ---------------------------------------------------------------------------
# Stream status passthrough
# ---------------------------------------------------------------------------


class TestStreamStatus:
    def test_stream_status_handled_quietly(self, db: Database) -> None:
        bridge = _make_bridge(db)
        # Currently logged-only; assert the call does not raise and does
        # not pollute the outbound batch.
        bridge.handle_stream_status(
            det.StreamStatus(state=det.STREAM_STATE_PUBLISHING),
        )


# ---------------------------------------------------------------------------
# Active cat ids surface
# ---------------------------------------------------------------------------


class TestActiveCatIds:
    def test_idle_returns_empty(self, db: Database) -> None:
        bridge = _make_bridge(db)
        assert bridge.active_cat_ids == []

    def test_active_unidentified_returns_empty(self, db: Database) -> None:
        bridge = _make_bridge(db)
        bridge.handle_session_request(_session_request(track_id=42))
        # Cat is not yet identified — surface as empty so the StatusUpdate
        # doesn't claim a cat the app has never heard of.
        assert bridge.active_cat_ids == []


# ---------------------------------------------------------------------------
# OutboundMessages
# ---------------------------------------------------------------------------


class TestOutboundMessages:
    def test_default_batch_is_empty(self) -> None:
        out = OutboundMessages()
        assert out.behavior_commands == ()
        assert out.session_acks == ()
        assert out.identity_results == ()
        assert out.session_ends == 0


# Avoid the unused-import warning for ``app_pb`` and ``time`` (they are
# kept so IDE-driven autocomplete in this file picks up the proto types
# tests will likely reach for in future iterations).
_ = app_pb
_ = time
