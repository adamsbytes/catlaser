"""IPC client for connecting to the Rust vision daemon.

Connects to the Unix domain socket, sends behavior commands, and receives
detection frames and track events. All messages are framed with the wire
protocol defined in :mod:`catlaser_brain.ipc.wire`.

The client uses blocking I/O with an optional receive timeout. Python runs
its own event loop and is not constrained by the Rust frame clock.
"""

from __future__ import annotations

import socket
from pathlib import Path
from typing import TYPE_CHECKING, Final, Self

from catlaser_brain.ipc.wire import (
    FrameReader,
    MsgType,
    encode_frame,
)
from catlaser_brain.proto.catlaser.detection.v1 import detection_pb2 as pb

if TYPE_CHECKING:
    from google.protobuf.message import Message

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_SOCKET_PATH: Final[Path] = Path("/run/catlaser/vision.sock")
"""Default socket path matching the Rust server's default."""

_RECV_BUF_SIZE: Final[int] = 4096
"""Socket receive buffer size per ``recv()`` call."""

_NON_BLOCKING: Final[bool] = False

# ---------------------------------------------------------------------------
# Message type mapping
# ---------------------------------------------------------------------------

# Maps wire type -> protobuf message class for inbound (Rust -> Python) messages.
_INBOUND_DECODERS: Final[dict[MsgType, type[Message]]] = {
    MsgType.DETECTION_FRAME: pb.DetectionFrame,
    MsgType.TRACK_EVENT: pb.TrackEvent,
    MsgType.SESSION_REQUEST: pb.SessionRequest,
}


# ---------------------------------------------------------------------------
# Incoming message
# ---------------------------------------------------------------------------


class IncomingMessage:
    """A decoded message received from the Rust vision daemon.

    Attributes:
        msg_type: The wire message type.
        message: The decoded protobuf message instance.
    """

    __slots__ = ("message", "msg_type")

    def __init__(self, msg_type: MsgType, message: Message) -> None:
        self.msg_type = msg_type
        self.message = message

    def __repr__(self) -> str:
        return f"IncomingMessage({self.msg_type.name}, {self.message})"


# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------


class IpcClient:
    """Blocking IPC client for the Rust vision daemon.

    Connects to the Unix domain socket and provides typed send/receive
    methods for the IPC protocol messages.

    Use as a context manager for automatic resource cleanup::

        with IpcClient.connect() as client:
            client.send_behavior_command(cmd)
            msg = client.recv()
    """

    __slots__ = ("_reader", "_sock")

    def __init__(self, sock: socket.socket) -> None:
        self._sock = sock
        self._reader = FrameReader()

    @classmethod
    def connect(cls, path: Path = DEFAULT_SOCKET_PATH) -> IpcClient:
        """Connect to the vision daemon's Unix socket.

        Args:
            path: Filesystem path to the Unix domain socket.

        Returns:
            A connected client ready for send/receive.

        Raises:
            ConnectionRefusedError: If the server is not listening.
            FileNotFoundError: If the socket path does not exist.
        """
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect(str(path))
        except Exception:
            sock.close()
            raise
        return cls(sock)

    def close(self) -> None:
        """Close the socket connection."""
        self._sock.close()

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    # -----------------------------------------------------------------------
    # Send (Python -> Rust)
    # -----------------------------------------------------------------------

    def send_behavior_command(self, cmd: pb.BehaviorCommand) -> None:
        """Send a behavior command to the vision daemon."""
        self._send(MsgType.BEHAVIOR_COMMAND, cmd)

    def send_session_ack(self, ack: pb.SessionAck) -> None:
        """Send a session acknowledgment to the vision daemon."""
        self._send(MsgType.SESSION_ACK, ack)

    def send_identity_result(self, result: pb.IdentityResult) -> None:
        """Send an identity resolution result to the vision daemon."""
        self._send(MsgType.IDENTITY_RESULT, result)

    def _send(self, msg_type: MsgType, msg: Message) -> None:
        """Encode and send a framed protobuf message."""
        payload = msg.SerializeToString()
        frame = encode_frame(msg_type, payload)
        self._sock.sendall(frame)

    # -----------------------------------------------------------------------
    # Receive (Rust -> Python)
    # -----------------------------------------------------------------------

    def set_timeout(self, timeout: float | None) -> None:
        """Set the receive timeout in seconds.

        Args:
            timeout: Seconds to wait for data, or ``None`` for blocking.
        """
        self._sock.settimeout(timeout)

    def recv(self) -> IncomingMessage:
        """Receive and decode the next message from the vision daemon.

        Blocks until a complete message is available (subject to timeout).

        Returns:
            The decoded incoming message.

        Raises:
            ConnectionError: If the server closed the connection.
            TimeoutError: If no data arrives within the configured timeout.
            ValueError: If the frame is malformed or the wire type is not a
                valid inbound message.
        """
        while True:
            frame = self._reader.next_frame()
            if frame is not None:
                msg_type, payload = frame
                return self._decode(msg_type, payload)

            data = self._sock.recv(_RECV_BUF_SIZE)
            if not data:
                msg = "connection closed by peer"
                raise ConnectionError(msg)
            self._reader.feed(data)

    def try_recv(self) -> IncomingMessage | None:
        """Non-blocking receive attempt.

        Returns:
            A decoded message if one is available, or ``None`` if not.

        Raises:
            ConnectionError: If the server closed the connection.
            ValueError: If the frame is malformed.
        """
        # Check buffered data first.
        frame = self._reader.next_frame()
        if frame is not None:
            msg_type, payload = frame
            return self._decode(msg_type, payload)

        # Try a non-blocking read. Save and restore the current timeout
        # so callers who set a timeout via set_timeout() aren't clobbered.
        prev_timeout = self._sock.gettimeout()
        self._sock.setblocking(_NON_BLOCKING)
        try:
            data = self._sock.recv(_RECV_BUF_SIZE)
        except BlockingIOError:
            return None
        finally:
            self._sock.settimeout(prev_timeout)

        if not data:
            msg = "connection closed by peer"
            raise ConnectionError(msg)

        self._reader.feed(data)

        frame = self._reader.next_frame()
        if frame is not None:
            msg_type, payload = frame
            return self._decode(msg_type, payload)
        return None

    @staticmethod
    def _decode(msg_type: MsgType, payload: bytes) -> IncomingMessage:
        """Decode a protobuf payload by wire type."""
        decoder = _INBOUND_DECODERS.get(msg_type)
        if decoder is None:
            err = f"unexpected inbound wire type: {msg_type.name}"
            raise ValueError(err)
        message = decoder()
        message.ParseFromString(payload)
        return IncomingMessage(msg_type, message)
