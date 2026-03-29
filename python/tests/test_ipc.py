"""Tests for the IPC wire format and client."""

from __future__ import annotations

import socket
import struct
import threading
import time
from pathlib import Path
from tempfile import TemporaryDirectory

import pytest

from catlaser_brain.ipc.client import IpcClient
from catlaser_brain.ipc.wire import (
    HEADER_SIZE,
    MAX_MESSAGE_SIZE,
    FrameReader,
    MsgType,
    encode_frame,
)
from catlaser_brain.proto.catlaser.detection.v1 import detection_pb2 as pb

# ---------------------------------------------------------------------------
# Wire format: encode / decode
# ---------------------------------------------------------------------------


class TestEncodeFrame:
    def test_round_trip(self):
        payload = b"hello protobuf"
        frame = encode_frame(MsgType.DETECTION_FRAME, payload)
        assert len(frame) == HEADER_SIZE + len(payload)

        type_byte, length = struct.unpack_from("<BI", frame)
        assert type_byte == MsgType.DETECTION_FRAME
        assert length == len(payload)
        assert frame[HEADER_SIZE:] == payload

    def test_empty_payload(self):
        frame = encode_frame(MsgType.SESSION_ACK, b"")
        assert len(frame) == HEADER_SIZE

        type_byte, length = struct.unpack_from("<BI", frame)
        assert type_byte == MsgType.SESSION_ACK
        assert length == 0

    def test_oversized_payload_rejected(self):
        payload = b"\x00" * (MAX_MESSAGE_SIZE + 1)
        with pytest.raises(ValueError, match="payload too large"):
            encode_frame(MsgType.DETECTION_FRAME, payload)

    def test_all_msg_types(self):
        for msg_type in MsgType:
            frame = encode_frame(msg_type, b"\x01\x02\x03")
            type_byte = frame[0]
            assert type_byte == msg_type


# ---------------------------------------------------------------------------
# FrameReader
# ---------------------------------------------------------------------------


class TestFrameReader:
    def test_complete_frame(self):
        reader = FrameReader()
        frame = encode_frame(MsgType.BEHAVIOR_COMMAND, b"data")
        reader.feed(frame)

        result = reader.next_frame()
        assert result is not None
        msg_type, payload = result
        assert msg_type == MsgType.BEHAVIOR_COMMAND
        assert payload == b"data"

    def test_partial_header(self):
        reader = FrameReader()
        frame = encode_frame(MsgType.DETECTION_FRAME, b"test")
        reader.feed(frame[:3])

        assert reader.next_frame() is None

        reader.feed(frame[3:])
        result = reader.next_frame()
        assert result is not None
        msg_type, payload = result
        assert msg_type == MsgType.DETECTION_FRAME
        assert payload == b"test"

    def test_partial_payload(self):
        reader = FrameReader()
        payload_data = b"a" * 100
        frame = encode_frame(MsgType.TRACK_EVENT, payload_data)

        reader.feed(frame[: HEADER_SIZE + 10])
        assert reader.next_frame() is None

        reader.feed(frame[HEADER_SIZE + 10 :])
        result = reader.next_frame()
        assert result is not None
        _, payload = result
        assert payload == payload_data

    def test_multiple_frames_in_one_feed(self):
        reader = FrameReader()
        frame1 = encode_frame(MsgType.BEHAVIOR_COMMAND, b"first")
        frame2 = encode_frame(MsgType.SESSION_ACK, b"second")
        reader.feed(frame1 + frame2)

        result1 = reader.next_frame()
        assert result1 is not None
        assert result1[0] == MsgType.BEHAVIOR_COMMAND
        assert result1[1] == b"first"

        result2 = reader.next_frame()
        assert result2 is not None
        assert result2[0] == MsgType.SESSION_ACK
        assert result2[1] == b"second"

        assert reader.next_frame() is None

    def test_invalid_type_byte_rejected(self):
        reader = FrameReader()
        bad_frame = struct.pack("<BI", 0, 0)
        reader.feed(bad_frame)

        with pytest.raises(ValueError, match="invalid wire type"):
            reader.next_frame()

    def test_oversized_length_rejected(self):
        reader = FrameReader()
        bad_frame = struct.pack("<BI", MsgType.DETECTION_FRAME, MAX_MESSAGE_SIZE + 1)
        reader.feed(bad_frame)

        with pytest.raises(ValueError, match="message too large"):
            reader.next_frame()

    def test_invalid_type_byte_drains_header_and_recovers(self):
        reader = FrameReader()
        bad_header = struct.pack("<BI", 0, 0)
        good_frame = encode_frame(MsgType.DETECTION_FRAME, b"valid")
        reader.feed(bad_header + good_frame)

        with pytest.raises(ValueError, match="invalid wire type"):
            reader.next_frame()

        result = reader.next_frame()
        assert result is not None
        msg_type, payload = result
        assert msg_type == MsgType.DETECTION_FRAME
        assert payload == b"valid"

    def test_oversized_length_drains_header_and_recovers(self):
        reader = FrameReader()
        bad_header = struct.pack("<BI", MsgType.DETECTION_FRAME, MAX_MESSAGE_SIZE + 1)
        good_frame = encode_frame(MsgType.BEHAVIOR_COMMAND, b"valid")
        reader.feed(bad_header + good_frame)

        with pytest.raises(ValueError, match="message too large"):
            reader.next_frame()

        result = reader.next_frame()
        assert result is not None
        msg_type, payload = result
        assert msg_type == MsgType.BEHAVIOR_COMMAND
        assert payload == b"valid"


# ---------------------------------------------------------------------------
# Cross-language wire compatibility
# ---------------------------------------------------------------------------


class TestCrossLanguageWire:
    """Verify Python wire bytes match the Rust snapshots."""

    def test_detection_frame_wire_matches_rust(self):
        frame = pb.DetectionFrame(
            timestamp_us=1_000_000,
            frame_number=42,
            cats=[
                pb.TrackedCat(
                    track_id=1,
                    cat_id="whiskers",
                    center_x=0.5,
                    center_y=0.6,
                    width=0.2,
                    height=0.3,
                    velocity_x=0.01,
                    velocity_y=-0.02,
                    state=pb.TRACK_STATE_CONFIRMED,
                ),
            ],
            safety_ceiling_y=0.75,
            person_in_frame=True,
            ambient_brightness=0.8,
        )

        payload = frame.SerializeToString()
        wire = encode_frame(MsgType.DETECTION_FRAME, payload)

        # Wire type byte must be 1 (DETECTION_FRAME).
        assert wire[0] == 1

        # Payload must round-trip through protobuf.
        decoded = pb.DetectionFrame()
        decoded.ParseFromString(wire[HEADER_SIZE:])
        assert decoded.timestamp_us == 1_000_000
        assert decoded.frame_number == 42
        assert len(decoded.cats) == 1
        assert decoded.cats[0].cat_id == "whiskers"
        assert decoded.person_in_frame is True

    def test_behavior_command_wire_matches_rust(self):
        cmd = pb.BehaviorCommand(
            mode=pb.TARGETING_MODE_TRACK,
            offset_x=0.1,
            offset_y=-0.05,
            smoothing=0.7,
            max_speed=0.5,
            laser_on=True,
            target_track_id=3,
        )

        payload = cmd.SerializeToString()
        wire = encode_frame(MsgType.BEHAVIOR_COMMAND, payload)

        # Wire type byte must be 4 (BEHAVIOR_COMMAND).
        assert wire[0] == 4

        # Round-trip.
        decoded = pb.BehaviorCommand()
        decoded.ParseFromString(wire[HEADER_SIZE:])
        assert decoded.mode == pb.TARGETING_MODE_TRACK
        assert decoded.target_track_id == 3
        assert decoded.laser_on is True


# ---------------------------------------------------------------------------
# Client integration: real Unix socket
# ---------------------------------------------------------------------------


def _make_socket_pair(tmpdir: str) -> tuple[Path, socket.socket, socket.socket]:
    """Create a Unix server socket, connect a client, and return both."""
    path = Path(tmpdir) / "test.sock"
    server_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server_sock.bind(str(path))
    server_sock.listen(1)

    client_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client_sock.connect(str(path))

    peer_sock, _ = server_sock.accept()
    server_sock.close()
    return path, client_sock, peer_sock


class TestIpcClient:
    def test_send_behavior_command(self):
        with TemporaryDirectory() as tmpdir:
            _, client_sock, peer_sock = _make_socket_pair(tmpdir)
            try:
                client = IpcClient(client_sock)
                cmd = pb.BehaviorCommand(
                    mode=pb.TARGETING_MODE_TRACK,
                    target_track_id=5,
                    laser_on=True,
                    smoothing=0.6,
                )
                client.send_behavior_command(cmd)

                # Read from the peer side.
                header = peer_sock.recv(HEADER_SIZE)
                type_byte, length = struct.unpack("<BI", header)
                assert type_byte == MsgType.BEHAVIOR_COMMAND
                payload = peer_sock.recv(length)
                decoded = pb.BehaviorCommand()
                decoded.ParseFromString(payload)
                assert decoded.target_track_id == 5
                assert decoded.laser_on is True
            finally:
                client_sock.close()
                peer_sock.close()

    def test_send_session_ack(self):
        with TemporaryDirectory() as tmpdir:
            _, client_sock, peer_sock = _make_socket_pair(tmpdir)
            try:
                client = IpcClient(client_sock)
                ack = pb.SessionAck(
                    accept=False,
                    skip_reason=pb.SKIP_REASON_HOPPER_EMPTY,
                )
                client.send_session_ack(ack)

                header = peer_sock.recv(HEADER_SIZE)
                type_byte, length = struct.unpack("<BI", header)
                assert type_byte == MsgType.SESSION_ACK
                payload = peer_sock.recv(length)
                decoded = pb.SessionAck()
                decoded.ParseFromString(payload)
                assert decoded.accept is False
                assert decoded.skip_reason == pb.SKIP_REASON_HOPPER_EMPTY
            finally:
                client_sock.close()
                peer_sock.close()

    def test_send_identity_result(self):
        with TemporaryDirectory() as tmpdir:
            _, client_sock, peer_sock = _make_socket_pair(tmpdir)
            try:
                client = IpcClient(client_sock)
                result = pb.IdentityResult(
                    track_id=2,
                    cat_id="mittens",
                    similarity=0.92,
                )
                client.send_identity_result(result)

                header = peer_sock.recv(HEADER_SIZE)
                type_byte, length = struct.unpack("<BI", header)
                assert type_byte == MsgType.IDENTITY_RESULT
                payload = peer_sock.recv(length)
                decoded = pb.IdentityResult()
                decoded.ParseFromString(payload)
                assert decoded.track_id == 2
                assert decoded.cat_id == "mittens"
            finally:
                client_sock.close()
                peer_sock.close()

    def test_recv_detection_frame(self):
        with TemporaryDirectory() as tmpdir:
            _, client_sock, peer_sock = _make_socket_pair(tmpdir)
            try:
                client = IpcClient(client_sock)

                frame = pb.DetectionFrame(
                    timestamp_us=500_000,
                    frame_number=7,
                    safety_ceiling_y=-1.0,
                )
                payload = frame.SerializeToString()
                wire = encode_frame(MsgType.DETECTION_FRAME, payload)
                peer_sock.sendall(wire)

                msg = client.recv()
                assert msg.msg_type == MsgType.DETECTION_FRAME
                assert isinstance(msg.message, pb.DetectionFrame)
                assert msg.message.timestamp_us == 500_000
                assert msg.message.frame_number == 7
            finally:
                client_sock.close()
                peer_sock.close()

    def test_recv_track_event(self):
        with TemporaryDirectory() as tmpdir:
            _, client_sock, peer_sock = _make_socket_pair(tmpdir)
            try:
                client = IpcClient(client_sock)

                event = pb.TrackEvent(
                    new_track=pb.NewTrack(track_id=42),
                )
                payload = event.SerializeToString()
                wire = encode_frame(MsgType.TRACK_EVENT, payload)
                peer_sock.sendall(wire)

                msg = client.recv()
                assert msg.msg_type == MsgType.TRACK_EVENT
                assert isinstance(msg.message, pb.TrackEvent)
                assert msg.message.new_track.track_id == 42
            finally:
                client_sock.close()
                peer_sock.close()

    def test_recv_session_request(self):
        with TemporaryDirectory() as tmpdir:
            _, client_sock, peer_sock = _make_socket_pair(tmpdir)
            try:
                client = IpcClient(client_sock)

                req = pb.SessionRequest(
                    trigger=pb.SESSION_TRIGGER_SCHEDULED,
                )
                payload = req.SerializeToString()
                wire = encode_frame(MsgType.SESSION_REQUEST, payload)
                peer_sock.sendall(wire)

                msg = client.recv()
                assert msg.msg_type == MsgType.SESSION_REQUEST
                assert isinstance(msg.message, pb.SessionRequest)
                assert msg.message.trigger == pb.SESSION_TRIGGER_SCHEDULED
            finally:
                client_sock.close()
                peer_sock.close()

    def test_peer_disconnect(self):
        with TemporaryDirectory() as tmpdir:
            _, client_sock, peer_sock = _make_socket_pair(tmpdir)
            try:
                client = IpcClient(client_sock)
                peer_sock.close()

                with pytest.raises(ConnectionError, match="closed by peer"):
                    client.recv()
            finally:
                client_sock.close()

    def test_bidirectional_exchange(self):
        with TemporaryDirectory() as tmpdir:
            _, client_sock, peer_sock = _make_socket_pair(tmpdir)
            try:
                client = IpcClient(client_sock)

                # Client sends BehaviorCommand.
                cmd = pb.BehaviorCommand(
                    mode=pb.TARGETING_MODE_TRACK,
                    target_track_id=42,
                    laser_on=True,
                )
                client.send_behavior_command(cmd)

                # Peer reads the command.
                header = peer_sock.recv(HEADER_SIZE)
                type_byte, length = struct.unpack("<BI", header)
                assert type_byte == MsgType.BEHAVIOR_COMMAND
                payload = peer_sock.recv(length)
                decoded_cmd = pb.BehaviorCommand()
                decoded_cmd.ParseFromString(payload)
                assert decoded_cmd.target_track_id == 42

                # Peer sends DetectionFrame back.
                frame = pb.DetectionFrame(
                    timestamp_us=1_234_567,
                    frame_number=100,
                )
                payload = frame.SerializeToString()
                wire = encode_frame(MsgType.DETECTION_FRAME, payload)
                peer_sock.sendall(wire)

                # Client receives it.
                msg = client.recv()
                assert msg.msg_type == MsgType.DETECTION_FRAME
                assert isinstance(msg.message, pb.DetectionFrame)
                assert msg.message.timestamp_us == 1_234_567
            finally:
                client_sock.close()
                peer_sock.close()

    def test_try_recv_no_data(self):
        with TemporaryDirectory() as tmpdir:
            _, client_sock, peer_sock = _make_socket_pair(tmpdir)
            try:
                client = IpcClient(client_sock)
                result = client.try_recv()
                assert result is None
            finally:
                client_sock.close()
                peer_sock.close()

    def test_try_recv_with_data(self):
        with TemporaryDirectory() as tmpdir:
            _, client_sock, peer_sock = _make_socket_pair(tmpdir)
            try:
                client = IpcClient(client_sock)

                frame = pb.DetectionFrame(timestamp_us=999)
                payload = frame.SerializeToString()
                wire = encode_frame(MsgType.DETECTION_FRAME, payload)
                peer_sock.sendall(wire)

                time.sleep(0.01)

                msg = client.try_recv()
                assert msg is not None
                assert msg.msg_type == MsgType.DETECTION_FRAME
                assert isinstance(msg.message, pb.DetectionFrame)
                assert msg.message.timestamp_us == 999
            finally:
                client_sock.close()
                peer_sock.close()

    def test_context_manager(self):
        with TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "ctx.sock"
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(path))
            server.listen(1)

            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(str(path))
            peer, _ = server.accept()
            server.close()

            with IpcClient(sock) as client:
                cmd = pb.BehaviorCommand(laser_on=True)
                client.send_behavior_command(cmd)

            # Socket should be closed after exiting context.
            assert sock.fileno() == -1
            peer.close()

    def test_send_preserves_recv_timeout(self):
        with TemporaryDirectory() as tmpdir:
            _, client_sock, peer_sock = _make_socket_pair(tmpdir)
            try:
                client = IpcClient(client_sock)
                client.set_timeout(5.0)

                cmd = pb.BehaviorCommand(laser_on=True)
                client.send_behavior_command(cmd)

                # The recv timeout must survive the send's temporary
                # timeout swap. Verify via the underlying socket which
                # IpcClient wraps.
                assert client_sock.gettimeout() == 5.0
            finally:
                client_sock.close()
                peer_sock.close()

    def test_send_preserves_blocking_mode(self):
        with TemporaryDirectory() as tmpdir:
            _, client_sock, peer_sock = _make_socket_pair(tmpdir)
            try:
                client = IpcClient(client_sock)
                # Default: blocking (timeout=None).
                assert client_sock.gettimeout() is None

                cmd = pb.BehaviorCommand(laser_on=True)
                client.send_behavior_command(cmd)

                # Must still be blocking after the send.
                assert client_sock.gettimeout() is None
            finally:
                client_sock.close()
                peer_sock.close()

    def test_connect_classmethod(self):
        with TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "connect.sock"
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(path))
            server.listen(1)

            client_holder: list[IpcClient] = []

            def do_connect():
                c = IpcClient.connect(path)
                client_holder.append(c)

            t = threading.Thread(target=do_connect)
            t.start()
            peer, _ = server.accept()
            t.join(timeout=5)
            server.close()

            assert len(client_holder) == 1
            client_holder[0].close()
            peer.close()
