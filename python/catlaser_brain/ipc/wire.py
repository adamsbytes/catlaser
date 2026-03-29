"""Wire format for the Rust/Python IPC protocol.

Frame layout: ``[1 byte: msg type][4 bytes: length (LE u32)][N bytes: protobuf]``

Both sides must agree on the type byte values and framing. This module provides
encoding and stateful decoding that handles partial reads from the stream socket.
"""

from __future__ import annotations

import struct
from enum import IntEnum
from typing import Final

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

HEADER_SIZE: Final[int] = 5
"""Frame header: 1 byte type + 4 bytes LE u32 length."""

MAX_MESSAGE_SIZE: Final[int] = 65_536
"""Maximum protobuf payload in bytes (64 KiB)."""

_HEADER_STRUCT: Final[struct.Struct] = struct.Struct("<BI")
"""Pre-compiled struct for packing/unpacking ``(type_byte, length_u32)``."""


# ---------------------------------------------------------------------------
# Message type enum
# ---------------------------------------------------------------------------


class MsgType(IntEnum):
    """Wire type byte values matching ``MsgType`` in detection.proto."""

    DETECTION_FRAME = 1
    TRACK_EVENT = 2
    SESSION_REQUEST = 3
    BEHAVIOR_COMMAND = 4
    SESSION_ACK = 5
    IDENTITY_RESULT = 6


# ---------------------------------------------------------------------------
# Encode
# ---------------------------------------------------------------------------


def encode_frame(msg_type: MsgType, payload: bytes) -> bytes:
    """Encode a message into a framed wire byte string.

    Args:
        msg_type: The message type tag.
        payload: Serialized protobuf bytes.

    Returns:
        The complete frame: ``header + payload``.

    Raises:
        ValueError: If *payload* exceeds :data:`MAX_MESSAGE_SIZE`.
    """
    length = len(payload)
    if length > MAX_MESSAGE_SIZE:
        msg = f"payload too large: {length} bytes (max {MAX_MESSAGE_SIZE})"
        raise ValueError(msg)
    header = _HEADER_STRUCT.pack(msg_type, length)
    return header + payload


# ---------------------------------------------------------------------------
# Decode (stateful, handles partial reads)
# ---------------------------------------------------------------------------


class FrameReader:
    """Stateful frame decoder that reassembles partial reads.

    Feed raw bytes from the socket via :meth:`feed`. Extract complete frames
    via :meth:`next_frame`. This handles the stream-socket reality that a
    single ``recv()`` may deliver a partial frame, a complete frame, or
    multiple frames at once.

    Example::

        reader = FrameReader()
        while True:
            data = sock.recv(4096)
            if not data:
                break
            reader.feed(data)
            while (frame := reader.next_frame()) is not None:
                msg_type, payload = frame
                handle(msg_type, payload)
    """

    __slots__ = ("_buf",)

    def __init__(self) -> None:
        self._buf = bytearray()

    def feed(self, data: bytes | bytearray | memoryview) -> None:
        """Append received bytes to the internal buffer."""
        self._buf.extend(data)

    def next_frame(self) -> tuple[MsgType, bytes] | None:
        """Try to extract one complete frame from the buffer.

        Returns:
            A ``(msg_type, payload)`` tuple if a complete frame is available,
            or ``None`` if the buffer contains only a partial frame.

        Raises:
            ValueError: If the type byte is invalid or the declared length
                exceeds :data:`MAX_MESSAGE_SIZE`.
        """
        if len(self._buf) < HEADER_SIZE:
            return None

        type_byte, length = _HEADER_STRUCT.unpack_from(self._buf)

        try:
            msg_type = MsgType(type_byte)
        except ValueError:
            del self._buf[:HEADER_SIZE]
            msg = f"invalid wire type byte: {type_byte}"
            raise ValueError(msg) from None

        if length > MAX_MESSAGE_SIZE:
            del self._buf[:HEADER_SIZE]
            msg = f"message too large: {length} bytes (max {MAX_MESSAGE_SIZE})"
            raise ValueError(msg)

        frame_len = HEADER_SIZE + length
        if len(self._buf) < frame_len:
            return None

        payload = bytes(self._buf[HEADER_SIZE:frame_len])
        del self._buf[:frame_len]
        return msg_type, payload
