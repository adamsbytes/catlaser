"""Tests for the orchestrator's IPC dispatch + outgoing-send helpers.

The full :class:`Daemon` ``run`` loop depends on a real Unix socket
bound by the Rust vision daemon, a real Tailnet interface, and a
reachable coordination server — none of which are available in unit
tests. The integration story for those pieces lives in the on-device
end-to-end harness.

What we CAN test in isolation: the orchestrator's pure dispatch
helpers, ``_bridge_dispatch`` and ``_send_outgoing``. They cover the
path between an inbound IPC message and the resulting outbound bytes,
and exercise the same code that the live loop runs every frame.
"""

from __future__ import annotations

import socket
from collections.abc import Iterator
from pathlib import Path
from random import Random
from typing import TYPE_CHECKING

import pytest

from catlaser_brain.daemon.hopper import HopperSensor
from catlaser_brain.daemon.orchestrator import (
    _bridge_dispatch,  # pyright: ignore[reportPrivateUsage]
    _broadcast_hopper_empty,  # pyright: ignore[reportPrivateUsage]
    _broadcast_new_cat_event,  # pyright: ignore[reportPrivateUsage]
    _send_hopper_empty_push,  # pyright: ignore[reportPrivateUsage]
    _send_new_cat_push,  # pyright: ignore[reportPrivateUsage]
    _send_outgoing,  # pyright: ignore[reportPrivateUsage]
)
from catlaser_brain.daemon.session_bridge import (
    NewCatDetection,
    OutboundMessages,
    SessionBridge,
)
from catlaser_brain.identity.catalog import CatCatalog
from catlaser_brain.ipc.client import IncomingMessage, IpcClient
from catlaser_brain.ipc.wire import HEADER_SIZE, MsgType
from catlaser_brain.proto.catlaser.detection.v1 import detection_pb2 as det
from catlaser_brain.storage.db import Database

if TYPE_CHECKING:
    from catlaser_brain.proto.catlaser.app.v1 import app_pb2 as app_pb

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def db(tmp_path: Path) -> Iterator[Database]:
    database = Database.connect(tmp_path / "orch.db")
    yield database
    database.close()


@pytest.fixture
def bridge(db: Database) -> SessionBridge:
    return SessionBridge(
        conn=db.conn,
        catalog=CatCatalog(db),
        hopper=HopperSensor(""),
        rng=Random(0),  # noqa: S311 — non-crypto tease cadence in tests
    )


@pytest.fixture
def ipc_pair() -> Iterator[tuple[IpcClient, socket.socket]]:
    server, client_sock = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    client = IpcClient(client_sock)
    try:
        yield client, server
    finally:
        client.close()
        server.close()


def _read_one_frame(sock: socket.socket) -> tuple[int, bytes]:
    sock.settimeout(2.0)
    header = b""
    while len(header) < HEADER_SIZE:
        chunk = sock.recv(HEADER_SIZE - len(header))
        if not chunk:
            msg = "peer closed before header complete"
            raise ConnectionError(msg)
        header += chunk
    type_byte = header[0]
    length = int.from_bytes(header[1:5], "little")
    payload = b""
    while len(payload) < length:
        chunk = sock.recv(length - len(payload))
        if not chunk:
            msg = "peer closed before payload complete"
            raise ConnectionError(msg)
        payload += chunk
    return type_byte, payload


# ---------------------------------------------------------------------------
# _bridge_dispatch
# ---------------------------------------------------------------------------


class TestBridgeDispatch:
    def test_session_request_routes_to_handler(self, bridge: SessionBridge) -> None:
        request = det.SessionRequest(
            trigger=det.SESSION_TRIGGER_CAT_DETECTED,
            track_id=42,
        )
        msg = IncomingMessage(MsgType.SESSION_REQUEST, request)
        result = _bridge_dispatch(bridge, msg)
        assert isinstance(result, OutboundMessages)
        assert len(result.session_acks) == 1
        assert result.session_acks[0].accept is True
        # Sanity: dispatch had the side effect of starting a session.
        assert bridge.is_active

    def test_detection_frame_routes_to_handler(self, bridge: SessionBridge) -> None:
        # Set up an active session first so the bridge has something
        # to do when the frame arrives.
        bridge.handle_session_request(
            det.SessionRequest(
                trigger=det.SESSION_TRIGGER_CAT_DETECTED,
                track_id=42,
            ),
        )
        frame = det.DetectionFrame(
            cats=[
                det.TrackedCat(
                    track_id=42,
                    center_x=0.5,
                    center_y=0.5,
                    width=0.1,
                    height=0.1,
                    velocity_x=0.0,
                    velocity_y=0.0,
                    state=det.TRACK_STATE_CONFIRMED,
                ),
            ],
        )
        msg = IncomingMessage(MsgType.DETECTION_FRAME, frame)
        result = _bridge_dispatch(bridge, msg)
        assert isinstance(result, OutboundMessages)
        assert len(result.behavior_commands) == 1

    def test_track_event_routes_to_handler(self, bridge: SessionBridge) -> None:
        bridge.handle_session_request(
            det.SessionRequest(
                trigger=det.SESSION_TRIGGER_CAT_DETECTED,
                track_id=42,
            ),
        )
        event = det.TrackEvent(new_track=det.NewTrack(track_id=42))
        msg = IncomingMessage(MsgType.TRACK_EVENT, event)
        result = _bridge_dispatch(bridge, msg)
        assert result == OutboundMessages()

    def test_stream_status_returns_none(self, bridge: SessionBridge) -> None:
        status = det.StreamStatus(state=det.STREAM_STATE_PUBLISHING)
        msg = IncomingMessage(MsgType.STREAM_STATUS, status)
        # Stream status is logged, not turned into outbound traffic.
        # A None return signals the orchestrator to skip the send.
        assert _bridge_dispatch(bridge, msg) is None

    def test_unexpected_msg_type_returns_none(self, bridge: SessionBridge) -> None:
        # An inbound `BehaviorCommand` is a protocol violation — the
        # bridge does not act on it, but must not raise either, so a
        # mis-tagged frame from a buggy peer cannot tear down the loop.
        cmd = det.BehaviorCommand()
        msg = IncomingMessage(MsgType.BEHAVIOR_COMMAND, cmd)
        assert _bridge_dispatch(bridge, msg) is None


# ---------------------------------------------------------------------------
# _send_outgoing
# ---------------------------------------------------------------------------


class TestSendOutgoing:
    def test_empty_batch_returns_true(
        self,
        ipc_pair: tuple[IpcClient, socket.socket],
    ) -> None:
        client, _server = ipc_pair
        # Empty batch is a no-op success — the orchestrator may dispatch
        # a frame whose only effect is engine state mutation, returning
        # an empty OutboundMessages.
        assert _send_outgoing(client, OutboundMessages()) is True

    def test_behavior_command_lands_on_socket(
        self,
        ipc_pair: tuple[IpcClient, socket.socket],
    ) -> None:
        client, server = ipc_pair
        cmd = det.BehaviorCommand(mode=det.TARGETING_MODE_TRACK, laser_on=True)
        ok = _send_outgoing(client, OutboundMessages(behavior_commands=(cmd,)))
        assert ok is True
        type_byte, payload = _read_one_frame(server)
        assert type_byte == MsgType.BEHAVIOR_COMMAND.value
        decoded = det.BehaviorCommand()
        decoded.ParseFromString(payload)
        assert decoded.laser_on is True

    def test_session_ack_lands_on_socket(
        self,
        ipc_pair: tuple[IpcClient, socket.socket],
    ) -> None:
        client, server = ipc_pair
        ack = det.SessionAck(accept=True)
        ok = _send_outgoing(client, OutboundMessages(session_acks=(ack,)))
        assert ok is True
        type_byte, _ = _read_one_frame(server)
        assert type_byte == MsgType.SESSION_ACK.value

    def test_session_end_lands_on_socket(
        self,
        ipc_pair: tuple[IpcClient, socket.socket],
    ) -> None:
        client, server = ipc_pair
        ok = _send_outgoing(client, OutboundMessages(session_ends=1))
        assert ok is True
        type_byte, _ = _read_one_frame(server)
        assert type_byte == MsgType.SESSION_END.value

    def test_multiple_frames_in_one_batch(
        self,
        ipc_pair: tuple[IpcClient, socket.socket],
    ) -> None:
        client, server = ipc_pair
        cmd = det.BehaviorCommand(mode=det.TARGETING_MODE_DISPENSE)
        ack = det.SessionAck(accept=False, skip_reason=det.SKIP_REASON_HOPPER_EMPTY)
        result = det.IdentityResult(track_id=7, cat_id="cat-7", similarity=0.91)
        out = OutboundMessages(
            behavior_commands=(cmd,),
            session_acks=(ack,),
            identity_results=(result,),
            session_ends=1,
        )
        assert _send_outgoing(client, out) is True
        # Ordering is BehaviorCommand → SessionAck → IdentityResult →
        # SessionEnd. This matches the orchestrator's documented send
        # priority and is asserted here so a reordering refactor is
        # caught in code review.
        type_a, _ = _read_one_frame(server)
        type_b, _ = _read_one_frame(server)
        type_c, _ = _read_one_frame(server)
        type_d, _ = _read_one_frame(server)
        assert type_a == MsgType.BEHAVIOR_COMMAND.value
        assert type_b == MsgType.SESSION_ACK.value
        assert type_c == MsgType.IDENTITY_RESULT.value
        assert type_d == MsgType.SESSION_END.value

    def test_broken_socket_returns_false(
        self,
        ipc_pair: tuple[IpcClient, socket.socket],
    ) -> None:
        client, server = ipc_pair
        # Close the peer; the next send fails with a broken-pipe.
        server.close()
        cmd = det.BehaviorCommand()
        # _send_outgoing returns False so the caller can mark the
        # connection broken and reconnect — it must NOT raise.
        assert _send_outgoing(client, OutboundMessages(behavior_commands=(cmd,))) is False


# ---------------------------------------------------------------------------
# Broadcast helpers
# ---------------------------------------------------------------------------


class _RecordingAppServer:
    """In-memory stand-in for :class:`AppServer` used by helper tests.

    Captures every event passed to :meth:`broadcast` so a test can assert
    both the oneof case selected and the field values inside it. The
    real server's authentication/eviction logic is unrelated to the
    helper functions under test.
    """

    def __init__(self) -> None:
        self.events: list[app_pb.DeviceEvent] = []

    def broadcast(self, event: app_pb.DeviceEvent) -> None:
        self.events.append(event)


class _RecordingPush:
    """In-memory stand-in for :class:`PushNotifier` for helper tests."""

    def __init__(self) -> None:
        self.hopper_empty_calls: int = 0
        self.new_cat_calls: list[tuple[int, float]] = []

    def notify_hopper_empty(self) -> None:
        self.hopper_empty_calls += 1

    def notify_new_cat_detected(
        self,
        track_id_hint: int,
        confidence: float,
    ) -> None:
        self.new_cat_calls.append((track_id_hint, confidence))


class TestBroadcastHelpers:
    def test_broadcast_hopper_empty_emits_correct_event(self) -> None:
        server = _RecordingAppServer()
        _broadcast_hopper_empty(server)  # type: ignore[arg-type]
        assert len(server.events) == 1
        assert server.events[0].WhichOneof("event") == "hopper_empty"

    def test_send_hopper_empty_push_invokes_notifier(self) -> None:
        push = _RecordingPush()
        _send_hopper_empty_push(push)  # type: ignore[arg-type]
        assert push.hopper_empty_calls == 1

    def test_broadcast_new_cat_event_carries_thumbnail_and_confidence(self) -> None:
        server = _RecordingAppServer()
        detection = NewCatDetection(
            track_id=42,
            confidence=0.83,
            thumbnail=b"\xff\xd8thumb",
        )
        _broadcast_new_cat_event(server, detection)  # type: ignore[arg-type]
        assert len(server.events) == 1
        event = server.events[0]
        assert event.WhichOneof("event") == "new_cat_detected"
        assert event.new_cat_detected.track_id_hint == 42
        # Approximate equality: protobuf stores float, not double, by
        # default — round-trip introduces ~1e-7 noise.
        assert abs(event.new_cat_detected.confidence - 0.83) < 1e-6
        assert event.new_cat_detected.thumbnail == b"\xff\xd8thumb"

    def test_send_new_cat_push_omits_thumbnail(self) -> None:
        # Thumbnail bytes are intentionally NOT in the push payload —
        # FCM/APNs cap notifications below the size of a JPEG crop, so
        # the app fetches the thumbnail via the data-channel event.
        push = _RecordingPush()
        detection = NewCatDetection(
            track_id=7,
            confidence=0.91,
            thumbnail=b"\xff\xd8thumb",
        )
        _send_new_cat_push(push, detection)  # type: ignore[arg-type]
        assert push.new_cat_calls == [(7, 0.91)]
