"""Wire format for the app-to-device API protocol.

Frame layout: ``[4 bytes: length (LE u32)][N bytes: protobuf]``

The ``AppRequest``/``DeviceEvent`` oneof envelopes handle message type
discrimination, so no type byte is needed (unlike the Rust/Python IPC
protocol which prefixes each frame with a type byte for per-message
routing).
"""

from __future__ import annotations

import struct
from typing import Final

HEADER_SIZE: Final[int] = 4
"""Frame header: 4 bytes LE u32 length."""

MAX_MESSAGE_SIZE: Final[int] = 1_048_576
"""Maximum protobuf payload in bytes (1 MiB).

Larger than the IPC limit (64 KiB) to accommodate JPEG thumbnails
in cat profile and new-cat-detected messages.
"""

_HEADER_STRUCT: Final[struct.Struct] = struct.Struct("<I")
"""Pre-compiled struct for packing/unpacking ``(length_u32,)``."""


def encode_frame(payload: bytes) -> bytes:
    """Encode a protobuf payload into a length-prefixed frame.

    Args:
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
    header = _HEADER_STRUCT.pack(length)
    return header + payload


class FrameReader:
    """Stateful frame decoder that reassembles partial TCP reads.

    Feed raw bytes via :meth:`feed`. Extract complete frames via
    :meth:`next_frame`. Handles the TCP stream reality that a single
    ``recv()`` may deliver a partial frame, a complete frame, or
    multiple frames.

    Example::

        reader = FrameReader()
        while True:
            data = sock.recv(8192)
            if not data:
                break
            reader.feed(data)
            while (payload := reader.next_frame()) is not None:
                handle(payload)
    """

    __slots__ = ("_buf",)

    def __init__(self) -> None:
        self._buf = bytearray()

    def feed(self, data: bytes | bytearray | memoryview) -> None:
        """Append received bytes to the internal buffer."""
        self._buf.extend(data)

    def next_frame(self) -> bytes | None:
        """Try to extract one complete frame from the buffer.

        Returns:
            The protobuf payload if a complete frame is available,
            or ``None`` if the buffer contains only a partial frame.

        Raises:
            ValueError: If the declared length exceeds
                :data:`MAX_MESSAGE_SIZE`.
        """
        if len(self._buf) < HEADER_SIZE:
            return None

        (length,) = _HEADER_STRUCT.unpack_from(self._buf)

        if length > MAX_MESSAGE_SIZE:
            drain = min(HEADER_SIZE + length, len(self._buf))
            del self._buf[:drain]
            msg = f"message too large: {length} bytes (max {MAX_MESSAGE_SIZE})"
            raise ValueError(msg)

        frame_len = HEADER_SIZE + length
        if len(self._buf) < frame_len:
            return None

        payload = bytes(self._buf[HEADER_SIZE:frame_len])
        del self._buf[:frame_len]
        return payload
