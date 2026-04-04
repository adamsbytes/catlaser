"""Tests for the app-to-device API: wire framing, handler, and TCP server."""

from __future__ import annotations

import socket
import struct
import time
from collections.abc import Iterator
from pathlib import Path

import pytest

from catlaser_brain.network.handler import DeviceState, RequestHandler
from catlaser_brain.network.server import MAX_CLIENTS, AppServer
from catlaser_brain.network.wire import (
    HEADER_SIZE,
    MAX_MESSAGE_SIZE,
    FrameReader,
    encode_frame,
)
from catlaser_brain.proto.catlaser.app.v1 import app_pb2 as pb
from catlaser_brain.storage.crud import (
    ScheduleEntryRow,
    set_schedule,
    store_pending_cat,
)
from catlaser_brain.storage.db import Database

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn(tmp_path: Path) -> Iterator[Database]:
    db = Database.connect(tmp_path / "test.db")
    yield db
    db.close()


@pytest.fixture
def state() -> DeviceState:
    return DeviceState(
        hopper_level=pb.HOPPER_LEVEL_OK,
        session_active=False,
        active_cat_ids=[],
        boot_time=time.monotonic(),
        firmware_version="1.0.0-test",
    )


@pytest.fixture
def handler(conn: Database, state: DeviceState) -> RequestHandler:
    return RequestHandler(conn.conn, state)


@pytest.fixture
def server(handler: RequestHandler) -> Iterator[AppServer]:
    srv = AppServer(handler, "127.0.0.1", 0)
    srv.start()
    yield srv
    srv.close()


# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------


def _insert_cat(
    conn: Database,
    cat_id: str = "cat-1",
    *,
    name: str = "TestCat",
    thumbnail: bytes = b"\xff\xd8test",
    created_at: int | None = None,
) -> None:
    now = created_at if created_at is not None else int(time.time())
    conn.conn.execute(
        "INSERT INTO cats "
        "(cat_id, name, thumbnail, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (cat_id, name, thumbnail, now, now),
    )
    conn.conn.commit()


def _insert_completed_session(
    conn: Database,
    session_id: str,
    *,
    start_time: int,
    duration_sec: int = 60,
    cat_ids: tuple[str, ...] = (),
) -> None:
    end_time = start_time + duration_sec
    conn.conn.execute(
        "INSERT INTO sessions "
        "(session_id, start_time, end_time, duration_sec, engagement_score, "
        "treats_dispensed, pounce_count, trigger) "
        "VALUES (?, ?, ?, ?, 0.5, 5, 3, 'cat_detected')",
        (session_id, start_time, end_time, duration_sec),
    )
    for cid in cat_ids:
        conn.conn.execute(
            "INSERT INTO session_cats (session_id, cat_id) VALUES (?, ?)",
            (session_id, cid),
        )
    conn.conn.commit()


def _make_embedding_bytes() -> bytes:
    """Create a valid 512-byte embedding (128 LE f32s)."""
    return struct.pack("<128f", *([0.1] * 128))


def _connect(server: AppServer) -> socket.socket:
    """Connect a test client to the server."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.connect(server.address)
    sock.settimeout(2.0)
    return sock


def _send_request(sock: socket.socket, request: pb.AppRequest) -> None:
    """Send an AppRequest to the server."""
    frame = encode_frame(request.SerializeToString())
    sock.sendall(frame)


def _recv_exact(sock: socket.socket, n: int) -> bytes:
    """Read exactly *n* bytes from *sock*."""
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            msg = "connection closed while reading"
            raise ConnectionError(msg)
        buf.extend(chunk)
    return bytes(buf)


def _recv_event(sock: socket.socket) -> pb.DeviceEvent:
    """Read a length-prefixed DeviceEvent from the socket."""
    header = _recv_exact(sock, HEADER_SIZE)
    (length,) = struct.unpack("<I", header)
    payload = _recv_exact(sock, length)
    event = pb.DeviceEvent()
    event.ParseFromString(payload)
    return event


# ===========================================================================
# Wire protocol tests
# ===========================================================================


class TestEncodeFrame:
    def test_round_trip(self):
        payload = b"hello world"
        frame = encode_frame(payload)
        reader = FrameReader()
        reader.feed(frame)
        assert reader.next_frame() == payload

    def test_empty_payload(self):
        frame = encode_frame(b"")
        reader = FrameReader()
        reader.feed(frame)
        assert reader.next_frame() == b""

    def test_oversized_payload_raises(self):
        with pytest.raises(ValueError, match="too large"):
            encode_frame(b"\x00" * (MAX_MESSAGE_SIZE + 1))

    def test_max_size_payload_accepted(self):
        payload = b"\x00" * MAX_MESSAGE_SIZE
        frame = encode_frame(payload)
        assert len(frame) == HEADER_SIZE + MAX_MESSAGE_SIZE


class TestFrameReader:
    def test_partial_header(self):
        reader = FrameReader()
        reader.feed(b"\x05\x00")
        assert reader.next_frame() is None

    def test_partial_payload(self):
        header = struct.pack("<I", 10)
        reader = FrameReader()
        reader.feed(header + b"\x00" * 5)
        assert reader.next_frame() is None
        reader.feed(b"\x00" * 5)
        assert reader.next_frame() == b"\x00" * 10

    def test_multiple_frames_in_one_feed(self):
        f1 = encode_frame(b"aaa")
        f2 = encode_frame(b"bbb")
        reader = FrameReader()
        reader.feed(f1 + f2)
        assert reader.next_frame() == b"aaa"
        assert reader.next_frame() == b"bbb"
        assert reader.next_frame() is None

    def test_oversized_declared_length_raises(self):
        header = struct.pack("<I", MAX_MESSAGE_SIZE + 1)
        reader = FrameReader()
        reader.feed(header)
        with pytest.raises(ValueError, match="too large"):
            reader.next_frame()

    def test_recovery_after_oversized_error(self):
        bad = struct.pack("<I", MAX_MESSAGE_SIZE + 1)
        reader = FrameReader()
        reader.feed(bad)
        with pytest.raises(ValueError, match="too large"):
            reader.next_frame()
        good = encode_frame(b"ok")
        reader.feed(good)
        assert reader.next_frame() == b"ok"

    def test_zero_length_frame(self):
        header = struct.pack("<I", 0)
        reader = FrameReader()
        reader.feed(header)
        assert reader.next_frame() == b""

    def test_incremental_byte_by_byte(self):
        frame = encode_frame(b"xyz")
        reader = FrameReader()
        for byte in frame:
            reader.feed(bytes([byte]))
        assert reader.next_frame() == b"xyz"


# ===========================================================================
# Handler tests
# ===========================================================================


class TestHandlerStatus:
    def test_returns_status_update(self, handler: RequestHandler):
        req = pb.AppRequest(
            request_id=1,
            get_status=pb.GetStatusRequest(),
        )
        event = handler.handle(req)
        assert event.request_id == 1
        assert event.HasField("status_update")
        assert event.status_update.firmware_version == "1.0.0-test"
        assert event.status_update.hopper_level == pb.HOPPER_LEVEL_OK
        assert event.status_update.session_active is False

    def test_uptime_increases(self, handler: RequestHandler, state: DeviceState):
        state.boot_time = time.monotonic() - 10.0
        req = pb.AppRequest(get_status=pb.GetStatusRequest())
        event = handler.handle(req)
        assert event.status_update.uptime_sec >= 10

    def test_reflects_active_session(self, handler: RequestHandler, state: DeviceState):
        state.session_active = True
        state.active_cat_ids = ["cat-1", "cat-2"]
        req = pb.AppRequest(get_status=pb.GetStatusRequest())
        event = handler.handle(req)
        assert event.status_update.session_active is True
        assert list(event.status_update.active_cat_ids) == ["cat-1", "cat-2"]


class TestHandlerCatProfiles:
    def test_empty_returns_empty_list(self, handler: RequestHandler):
        req = pb.AppRequest(get_cat_profiles=pb.GetCatProfilesRequest())
        event = handler.handle(req)
        assert event.HasField("cat_profile_list")
        assert len(event.cat_profile_list.profiles) == 0

    def test_returns_all_cats(self, handler: RequestHandler, conn: Database):
        _insert_cat(conn, "cat-1", name="Luna")
        _insert_cat(conn, "cat-2", name="Milo")
        req = pb.AppRequest(get_cat_profiles=pb.GetCatProfilesRequest())
        event = handler.handle(req)
        assert len(event.cat_profile_list.profiles) == 2
        names = {p.name for p in event.cat_profile_list.profiles}
        assert names == {"Luna", "Milo"}

    def test_profile_fields_populated(self, handler: RequestHandler, conn: Database):
        _insert_cat(conn, "cat-1", name="Luna", thumbnail=b"\xff\xd8luna")
        req = pb.AppRequest(get_cat_profiles=pb.GetCatProfilesRequest())
        event = handler.handle(req)
        profile = event.cat_profile_list.profiles[0]
        assert profile.cat_id == "cat-1"
        assert profile.name == "Luna"
        assert profile.thumbnail == b"\xff\xd8luna"
        assert profile.preferred_speed == 1.0
        assert profile.preferred_smoothing == 0.5
        assert profile.created_at > 0

    def test_update_name(self, handler: RequestHandler, conn: Database):
        _insert_cat(conn, "cat-1", name="Old")
        req = pb.AppRequest(
            update_cat_profile=pb.UpdateCatProfileRequest(
                profile=pb.CatProfile(cat_id="cat-1", name="New"),
            ),
        )
        event = handler.handle(req)
        assert event.HasField("cat_profile_list")
        assert event.cat_profile_list.profiles[0].name == "New"

    def test_update_nonexistent_cat_returns_error(self, handler: RequestHandler):
        req = pb.AppRequest(
            update_cat_profile=pb.UpdateCatProfileRequest(
                profile=pb.CatProfile(cat_id="no-such-cat", name="Fail"),
            ),
        )
        event = handler.handle(req)
        assert event.HasField("error")
        assert "not found" in event.error.message

    def test_delete_cat(self, handler: RequestHandler, conn: Database):
        _insert_cat(conn, "cat-1", name="Luna")
        req = pb.AppRequest(
            delete_cat_profile=pb.DeleteCatProfileRequest(cat_id="cat-1"),
        )
        event = handler.handle(req)
        assert event.HasField("cat_profile_list")
        assert len(event.cat_profile_list.profiles) == 0

    def test_delete_nonexistent_cat_is_idempotent(self, handler: RequestHandler):
        req = pb.AppRequest(
            delete_cat_profile=pb.DeleteCatProfileRequest(cat_id="nope"),
        )
        event = handler.handle(req)
        assert event.HasField("cat_profile_list")


class TestHandlerPlayHistory:
    def test_empty_history(self, handler: RequestHandler):
        req = pb.AppRequest(
            get_play_history=pb.GetPlayHistoryRequest(
                start_time=0,
                end_time=9999999999,
            ),
        )
        event = handler.handle(req)
        assert event.HasField("play_history")
        assert len(event.play_history.sessions) == 0

    def test_returns_sessions_in_range(self, handler: RequestHandler, conn: Database):
        _insert_cat(conn, "cat-1")
        _insert_completed_session(conn, "s-1", start_time=1000, cat_ids=("cat-1",))
        _insert_completed_session(conn, "s-2", start_time=2000, cat_ids=("cat-1",))
        req = pb.AppRequest(
            get_play_history=pb.GetPlayHistoryRequest(start_time=0, end_time=3000),
        )
        event = handler.handle(req)
        assert len(event.play_history.sessions) == 2
        assert event.play_history.sessions[0].session_id == "s-1"

    def test_session_fields(self, handler: RequestHandler, conn: Database):
        _insert_cat(conn, "cat-1")
        _insert_completed_session(
            conn,
            "s-1",
            start_time=1000,
            duration_sec=60,
            cat_ids=("cat-1",),
        )
        req = pb.AppRequest(
            get_play_history=pb.GetPlayHistoryRequest(start_time=0, end_time=2000),
        )
        event = handler.handle(req)
        s = event.play_history.sessions[0]
        assert s.session_id == "s-1"
        assert s.start_time == 1000
        assert s.end_time == 1060
        assert s.duration_sec == 60
        assert list(s.cat_ids) == ["cat-1"]


class TestHandlerSchedule:
    def test_get_schedule_empty(self, handler: RequestHandler):
        req = pb.AppRequest(get_schedule=pb.GetScheduleRequest())
        event = handler.handle(req)
        assert event.HasField("schedule")
        assert len(event.schedule.entries) == 0

    def test_set_and_get_schedule(self, handler: RequestHandler):
        req = pb.AppRequest(
            set_schedule=pb.SetScheduleRequest(
                entries=[
                    pb.ScheduleEntry(
                        entry_id="e-1",
                        start_minute=480,
                        duration_min=30,
                        days=[pb.DAY_OF_WEEK_MONDAY, pb.DAY_OF_WEEK_WEDNESDAY],
                        enabled=True,
                    ),
                ],
            ),
        )
        event = handler.handle(req)
        assert event.HasField("schedule")
        assert len(event.schedule.entries) == 1
        entry = event.schedule.entries[0]
        assert entry.entry_id == "e-1"
        assert entry.start_minute == 480
        assert entry.duration_min == 30
        assert entry.enabled is True

        get_req = pb.AppRequest(get_schedule=pb.GetScheduleRequest())
        get_event = handler.handle(get_req)
        assert len(get_event.schedule.entries) == 1

    def test_set_schedule_replaces_existing(self, handler: RequestHandler, conn: Database):
        old = [ScheduleEntryRow("old-1", 480, 30, (), enabled=True)]
        set_schedule(conn.conn, old)

        req = pb.AppRequest(
            set_schedule=pb.SetScheduleRequest(
                entries=[
                    pb.ScheduleEntry(
                        entry_id="new-1",
                        start_minute=600,
                        duration_min=20,
                        enabled=True,
                    ),
                ],
            ),
        )
        event = handler.handle(req)
        assert len(event.schedule.entries) == 1
        assert event.schedule.entries[0].entry_id == "new-1"


class TestHandlerIdentification:
    def test_identify_new_cat(self, handler: RequestHandler, conn: Database):
        emb = _make_embedding_bytes()
        store_pending_cat(conn.conn, 42, b"\xff\xd8thumb", 0.9, embedding=emb)

        req = pb.AppRequest(
            identify_new_cat=pb.IdentifyNewCatRequest(
                track_id_hint=42,
                name="Whiskers",
            ),
        )
        event = handler.handle(req)
        assert event.HasField("cat_profile_list")
        assert len(event.cat_profile_list.profiles) == 1
        assert event.cat_profile_list.profiles[0].name == "Whiskers"

    def test_identify_nonexistent_pending_cat(self, handler: RequestHandler):
        req = pb.AppRequest(
            identify_new_cat=pb.IdentifyNewCatRequest(
                track_id_hint=999,
                name="Ghost",
            ),
        )
        event = handler.handle(req)
        assert event.HasField("error")
        assert "track_id_hint 999" in event.error.message


class TestHandlerSessionControl:
    def test_start_session_without_control_returns_error(self, handler: RequestHandler):
        req = pb.AppRequest(start_session=pb.StartSessionRequest())
        event = handler.handle(req)
        assert event.HasField("error")
        assert "not available" in event.error.message

    def test_stop_session_without_control_returns_error(self, handler: RequestHandler):
        req = pb.AppRequest(stop_session=pb.StopSessionRequest())
        event = handler.handle(req)
        assert event.HasField("error")
        assert "not available" in event.error.message

    def test_start_session_with_control(self, conn: Database, state: DeviceState):
        calls: list[str] = []

        class _Control:
            def start_session(self) -> None:
                calls.append("start")

            def stop_session(self) -> None:
                calls.append("stop")

        h = RequestHandler(conn.conn, state, session_control=_Control())
        req = pb.AppRequest(start_session=pb.StartSessionRequest())
        event = h.handle(req)
        assert event.HasField("status_update")
        assert calls == ["start"]

    def test_stop_session_with_control(self, conn: Database, state: DeviceState):
        calls: list[str] = []

        class _Control:
            def start_session(self) -> None:
                calls.append("start")

            def stop_session(self) -> None:
                calls.append("stop")

        h = RequestHandler(conn.conn, state, session_control=_Control())
        req = pb.AppRequest(stop_session=pb.StopSessionRequest())
        event = h.handle(req)
        assert event.HasField("status_update")
        assert calls == ["stop"]


class TestHandlerStubs:
    def test_start_stream_not_configured(self, handler: RequestHandler):
        req = pb.AppRequest(start_stream=pb.StartStreamRequest())
        event = handler.handle(req)
        assert event.HasField("error")
        assert "not configured" in event.error.message

    def test_stop_stream_not_configured(self, handler: RequestHandler):
        req = pb.AppRequest(stop_stream=pb.StopStreamRequest())
        event = handler.handle(req)
        assert event.HasField("error")
        assert "not configured" in event.error.message

    def test_run_diagnostic_not_available(self, handler: RequestHandler):
        req = pb.AppRequest(
            run_diagnostic=pb.RunDiagnosticRequest(
                diagnostic_type=pb.DIAGNOSTIC_TYPE_FULL,
            ),
        )
        event = handler.handle(req)
        assert event.HasField("error")


class TestHandlerErrors:
    def test_empty_request_returns_error(self, handler: RequestHandler):
        req = pb.AppRequest()
        event = handler.handle(req)
        assert event.HasField("error")
        assert "empty" in event.error.message

    def test_request_id_echoed(self, handler: RequestHandler):
        req = pb.AppRequest(
            request_id=42,
            get_status=pb.GetStatusRequest(),
        )
        event = handler.handle(req)
        assert event.request_id == 42

    def test_request_id_zero_for_no_id(self, handler: RequestHandler):
        req = pb.AppRequest(get_status=pb.GetStatusRequest())
        event = handler.handle(req)
        assert event.request_id == 0


# ===========================================================================
# Server tests
# ===========================================================================


class TestServerConnection:
    def test_start_and_close(self, handler: RequestHandler):
        srv = AppServer(handler, "127.0.0.1", 0)
        srv.start()
        assert srv.client_count == 0
        _, port = srv.address
        assert port > 0
        srv.close()

    def test_accept_single_client(self, server: AppServer):
        client = _connect(server)
        server.poll()
        assert server.client_count == 1
        client.close()

    def test_accept_multiple_clients(self, server: AppServer):
        clients = [_connect(server) for _ in range(3)]
        server.poll()
        assert server.client_count == 3
        for c in clients:
            c.close()

    def test_max_clients_enforced(self, server: AppServer):
        clients = [_connect(server) for _ in range(MAX_CLIENTS)]
        server.poll()
        assert server.client_count == MAX_CLIENTS

        extra = _connect(server)
        server.poll()
        assert server.client_count == MAX_CLIENTS
        extra.close()
        for c in clients:
            c.close()

    def test_client_disconnect_detected(self, server: AppServer):
        client = _connect(server)
        server.poll()
        assert server.client_count == 1
        client.close()
        server.poll()
        assert server.client_count == 0

    def test_context_manager(self, handler: RequestHandler):
        with AppServer(handler, "127.0.0.1", 0) as srv:
            srv.start()
            client = _connect(srv)
            srv.poll()
            assert srv.client_count == 1
            client.close()
        assert srv.client_count == 0

    def test_address_before_start_raises(self, handler: RequestHandler):
        srv = AppServer(handler, "127.0.0.1", 0)
        with pytest.raises(RuntimeError, match="not started"):
            _ = srv.address


class TestServerRequestResponse:
    def test_get_status(self, server: AppServer):
        client = _connect(server)
        server.poll()

        _send_request(
            client,
            pb.AppRequest(request_id=1, get_status=pb.GetStatusRequest()),
        )
        server.poll()

        event = _recv_event(client)
        assert event.request_id == 1
        assert event.HasField("status_update")
        assert event.status_update.firmware_version == "1.0.0-test"
        client.close()

    def test_multiple_requests_same_client(self, server: AppServer):
        client = _connect(server)
        server.poll()

        for i in range(1, 4):
            _send_request(
                client,
                pb.AppRequest(request_id=i, get_status=pb.GetStatusRequest()),
            )
        server.poll()

        for i in range(1, 4):
            event = _recv_event(client)
            assert event.request_id == i
        client.close()

    def test_requests_from_different_clients(self, server: AppServer):
        c1 = _connect(server)
        c2 = _connect(server)
        server.poll()

        _send_request(c1, pb.AppRequest(request_id=10, get_status=pb.GetStatusRequest()))
        _send_request(c2, pb.AppRequest(request_id=20, get_status=pb.GetStatusRequest()))
        server.poll()

        e1 = _recv_event(c1)
        e2 = _recv_event(c2)
        assert e1.request_id == 10
        assert e2.request_id == 20
        c1.close()
        c2.close()


class TestServerBroadcast:
    def test_broadcast_to_all_clients(self, server: AppServer):
        c1 = _connect(server)
        c2 = _connect(server)
        server.poll()

        server.broadcast(
            pb.DeviceEvent(
                status_update=pb.StatusUpdate(firmware_version="broadcast-test"),
            ),
        )

        e1 = _recv_event(c1)
        e2 = _recv_event(c2)
        assert e1.status_update.firmware_version == "broadcast-test"
        assert e2.status_update.firmware_version == "broadcast-test"
        c1.close()
        c2.close()

    def test_broadcast_with_no_clients(self, server: AppServer):
        server.broadcast(pb.DeviceEvent(hopper_empty=pb.HopperEmpty()))

    def test_broadcast_removes_dead_client(self, server: AppServer):
        c1 = _connect(server)
        c2 = _connect(server)
        server.poll()
        assert server.client_count == 2

        c1.close()
        server.poll()
        assert server.client_count == 1

        server.broadcast(
            pb.DeviceEvent(hopper_empty=pb.HopperEmpty()),
        )
        event = _recv_event(c2)
        assert event.HasField("hopper_empty")
        assert server.client_count == 1
        c2.close()

    def test_broadcast_request_id_zero(self, server: AppServer):
        client = _connect(server)
        server.poll()

        server.broadcast(
            pb.DeviceEvent(
                session_summary=pb.SessionSummary(
                    cat_ids=["cat-1"],
                    duration_sec=120,
                    engagement_score=0.8,
                    treats_dispensed=5,
                    pounce_count=12,
                    ended_at=1000,
                ),
            ),
        )

        event = _recv_event(client)
        assert event.request_id == 0
        assert event.session_summary.duration_sec == 120
        client.close()
