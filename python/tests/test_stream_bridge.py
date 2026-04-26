"""Tests for :class:`StreamBridge`: handler-side stream notify forwarding."""

from __future__ import annotations

import socket
import threading
from collections.abc import Iterator
from pathlib import Path

import pytest

from catlaser_brain.daemon.stream_bridge import StreamBridge
from catlaser_brain.ipc.client import IpcClient
from catlaser_brain.ipc.wire import HEADER_SIZE, MsgType
from catlaser_brain.network.streaming import StreamCredentials
from catlaser_brain.proto.catlaser.detection.v1 import detection_pb2 as det

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def credentials() -> StreamCredentials:
    return StreamCredentials(
        livekit_url="wss://livekit.test",
        subscriber_token="sub-token",
        publisher_token="pub-token",
        room_name="catlaser-live-test",
        target_bitrate_bps=500_000,
    )


def _ipc_pair(tmp_path: Path) -> Iterator[tuple[IpcClient, socket.socket]]:
    """Yield an IPC client connected to a socketpair the test can read.

    The "server" side is a plain :func:`socket.socketpair` peer — the
    test reads frames off it directly to assert what the bridge sent.
    No real Unix socket bind is needed.
    """
    server_sock, client_sock = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    client = IpcClient(client_sock)
    try:
        yield client, server_sock
    finally:
        client.close()
        server_sock.close()


@pytest.fixture
def ipc(tmp_path: Path) -> Iterator[tuple[IpcClient, socket.socket]]:
    yield from _ipc_pair(tmp_path)


def _read_one_frame(sock: socket.socket) -> tuple[int, bytes]:
    """Block-read a single ``[type][length][payload]`` frame."""
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
# Forwarding
# ---------------------------------------------------------------------------


class TestStreamStart:
    def test_forwards_credentials_as_stream_control(
        self,
        ipc: tuple[IpcClient, socket.socket],
        credentials: StreamCredentials,
    ) -> None:
        client, server = ipc
        bridge = StreamBridge(ipc=client)

        # Send happens synchronously on the bridge call. Read it back
        # off the peer socket and assert structure.
        bridge.on_stream_start(credentials)

        type_byte, payload = _read_one_frame(server)
        assert type_byte == MsgType.STREAM_CONTROL.value

        ctrl = det.StreamControl()
        ctrl.ParseFromString(payload)
        assert ctrl.action == det.STREAM_ACTION_START
        assert ctrl.livekit_url == credentials.livekit_url
        assert ctrl.publisher_token == credentials.publisher_token
        assert ctrl.room_name == credentials.room_name
        assert ctrl.target_bitrate_bps == credentials.target_bitrate_bps


class TestStreamStop:
    def test_forwards_stop(
        self,
        ipc: tuple[IpcClient, socket.socket],
    ) -> None:
        client, server = ipc
        bridge = StreamBridge(ipc=client)
        bridge.on_stream_stop()

        type_byte, payload = _read_one_frame(server)
        assert type_byte == MsgType.STREAM_CONTROL.value

        ctrl = det.StreamControl()
        ctrl.ParseFromString(payload)
        assert ctrl.action == det.STREAM_ACTION_STOP


class TestDisconnected:
    def test_no_send_when_ipc_none(
        self,
        credentials: StreamCredentials,
    ) -> None:
        bridge = StreamBridge(ipc=None)
        # Without an IPC client, the call must not raise. The
        # orchestrator handles the lost connection separately.
        bridge.on_stream_start(credentials)
        bridge.on_stream_stop()

    def test_set_ipc_attaches_after_construction(
        self,
        ipc: tuple[IpcClient, socket.socket],
        credentials: StreamCredentials,
    ) -> None:
        client, server = ipc
        bridge = StreamBridge(ipc=None)
        bridge.set_ipc(client)
        bridge.on_stream_start(credentials)

        type_byte, _ = _read_one_frame(server)
        assert type_byte == MsgType.STREAM_CONTROL.value


# ---------------------------------------------------------------------------
# Send failure handling
# ---------------------------------------------------------------------------


class TestSendFailure:
    def test_broken_socket_does_not_raise(
        self,
        ipc: tuple[IpcClient, socket.socket],
        credentials: StreamCredentials,
    ) -> None:
        client, server = ipc
        bridge = StreamBridge(ipc=client)
        # Close the server side; the next send hits a closed pipe.
        server.close()
        # Bridge MUST swallow — the orchestrator's IPC reconnect loop
        # owns recovery; raising here would unwind the AppServer's
        # request-handling loop and tear down the app TCP session.
        bridge.on_stream_start(credentials)

    def test_thread_safety_smoke(
        self,
        ipc: tuple[IpcClient, socket.socket],
        credentials: StreamCredentials,
    ) -> None:
        # Two concurrent on_stream_stop calls (e.g. app + orchestrator
        # finalise) must both complete without raising. The IPC client
        # is not internally thread-safe, but stop is idempotent and
        # serialises naturally; the test just asserts no crash.
        client, _server = ipc
        bridge = StreamBridge(ipc=client)
        bridge.on_stream_start(credentials)
        threads = [threading.Thread(target=bridge.on_stream_stop) for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=2.0)
            assert not t.is_alive()
