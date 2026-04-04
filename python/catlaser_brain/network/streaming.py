"""LiveKit room management and token generation for WebRTC live view.

Manages the device-side LiveKit integration: creates rooms, generates
JWT tokens for the publisher (Rust vision daemon) and subscriber (mobile
app), and provides the stream lifecycle callbacks wired into the request
handler.

The actual video publish happens in Rust (hardware encoder + str0m WebRTC
transport). This module only handles the control plane: room creation via
the LiveKit server API and JWT token minting. No video data passes through
Python.

Configuration is read from environment variables:
    ``LIVEKIT_API_KEY``, ``LIVEKIT_API_SECRET``, ``LIVEKIT_URL``
"""

from __future__ import annotations

import asyncio
import dataclasses
import os
from typing import Final

from livekit import api

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_ROOM_NAME: Final[str] = "catlaser-live"
"""Fixed room name. Only one device exists per deployment, so a single
room suffices. The room is created on demand and destroyed on stream stop.
"""

_PUBLISHER_IDENTITY: Final[str] = "catlaser-device"
"""LiveKit participant identity for the publishing device."""

_SUBSCRIBER_IDENTITY: Final[str] = "catlaser-app"
"""LiveKit participant identity for the subscribing app."""

_ROOM_EMPTY_TIMEOUT_SEC: Final[int] = 30
"""Seconds after the last participant leaves before the LiveKit server
automatically destroys the room. Short — the device re-creates the room
on the next stream start.
"""

_DEFAULT_BITRATE_BPS: Final[int] = 500_000
"""Default target video bitrate in bits per second. 500 kbps is reasonable
for 640x480 @ 15 fps H.264 Constrained Baseline over WiFi.
"""


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True, slots=True)
class StreamConfig:
    """LiveKit connection parameters.

    Read from environment variables at construction. All three are
    required — ``from_env`` raises ``ValueError`` if any is missing.

    Attributes:
        livekit_url: LiveKit server WebSocket URL (e.g. ``wss://lk.example.com``).
        api_key: LiveKit API key for token signing and server API auth.
        api_secret: LiveKit API secret for token signing and server API auth.
    """

    livekit_url: str
    api_key: str
    api_secret: str

    @classmethod
    def from_env(cls) -> StreamConfig:
        """Construct from ``LIVEKIT_URL``, ``LIVEKIT_API_KEY``, ``LIVEKIT_API_SECRET``.

        Raises:
            ValueError: If any required environment variable is unset or empty.
        """
        url = os.environ.get("LIVEKIT_URL", "")
        key = os.environ.get("LIVEKIT_API_KEY", "")
        secret = os.environ.get("LIVEKIT_API_SECRET", "")

        missing: list[str] = []
        if not url:
            missing.append("LIVEKIT_URL")
        if not key:
            missing.append("LIVEKIT_API_KEY")
        if not secret:
            missing.append("LIVEKIT_API_SECRET")

        if missing:
            msg = f"missing required environment variables: {', '.join(missing)}"
            raise ValueError(msg)

        return cls(livekit_url=url, api_key=key, api_secret=secret)


# ---------------------------------------------------------------------------
# Stream credentials
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True, slots=True)
class StreamCredentials:
    """Credentials returned to the app for subscribing to the live stream.

    Attributes:
        livekit_url: LiveKit server URL the app should connect to.
        subscriber_token: JWT token for the app to join as a subscriber.
        publisher_token: JWT token for the Rust daemon to join as a publisher.
        room_name: LiveKit room name.
        target_bitrate_bps: Suggested video bitrate for the publisher.
    """

    livekit_url: str
    subscriber_token: str
    publisher_token: str
    room_name: str
    target_bitrate_bps: int


# ---------------------------------------------------------------------------
# Token generation (pure, synchronous)
# ---------------------------------------------------------------------------


def generate_publisher_token(config: StreamConfig) -> str:
    """Generate a JWT for the device to publish video to the room.

    The token grants room join + publish permissions but not subscribe
    (the device doesn't need to receive media from the app).
    """
    token = (
        api.AccessToken(api_key=config.api_key, api_secret=config.api_secret)
        .with_identity(_PUBLISHER_IDENTITY)
        .with_name("Catlaser Device")
        .with_grants(
            api.VideoGrants(
                room_join=True,
                room=_ROOM_NAME,
                can_publish=True,
                can_subscribe=False,
            ),
        )
    )
    return token.to_jwt()


def generate_subscriber_token(config: StreamConfig) -> str:
    """Generate a JWT for the app to subscribe to the room.

    The token grants room join + subscribe permissions but not publish
    (the app is a viewer, not a broadcaster).
    """
    token = (
        api.AccessToken(api_key=config.api_key, api_secret=config.api_secret)
        .with_identity(_SUBSCRIBER_IDENTITY)
        .with_name("Catlaser App")
        .with_grants(
            api.VideoGrants(
                room_join=True,
                room=_ROOM_NAME,
                can_publish=False,
                can_subscribe=True,
            ),
        )
    )
    return token.to_jwt()


# ---------------------------------------------------------------------------
# Stream manager
# ---------------------------------------------------------------------------


class StreamManager:
    """Manages LiveKit room lifecycle for the WebRTC live view.

    Synchronous interface for the request handler. Async LiveKit API
    calls are run via a private event loop.

    Args:
        config: LiveKit connection parameters.
    """

    __slots__ = ("_config", "_loop", "_streaming")

    def __init__(self, config: StreamConfig) -> None:
        self._config = config
        self._loop = asyncio.new_event_loop()
        self._streaming = False

    @property
    def is_streaming(self) -> bool:
        """Whether a stream is currently active."""
        return self._streaming

    def start(self) -> StreamCredentials:
        """Start a live stream: create room, generate tokens.

        Returns credentials for the app (subscriber token) and the Rust
        daemon (publisher token). The caller is responsible for sending
        the publisher credentials to Rust via IPC.

        Raises:
            RuntimeError: If a stream is already active.
        """
        if self._streaming:
            msg = "stream already active"
            raise RuntimeError(msg)

        self._loop.run_until_complete(self._create_room())
        self._streaming = True

        return StreamCredentials(
            livekit_url=self._config.livekit_url,
            subscriber_token=generate_subscriber_token(self._config),
            publisher_token=generate_publisher_token(self._config),
            room_name=_ROOM_NAME,
            target_bitrate_bps=_DEFAULT_BITRATE_BPS,
        )

    def stop(self) -> None:
        """Stop the live stream: delete the room.

        Idempotent — safe to call when not streaming.
        """
        if not self._streaming:
            return
        self._streaming = False
        self._loop.run_until_complete(self._delete_room())

    def close(self) -> None:
        """Release resources. Call on shutdown."""
        if self._streaming:
            self.stop()
        self._loop.close()

    async def _create_room(self) -> None:
        """Create the LiveKit room via the server API.

        Idempotent — if the room already exists, LiveKit returns success.
        """
        lk = api.LiveKitAPI(
            url=self._config.livekit_url,
            api_key=self._config.api_key,
            api_secret=self._config.api_secret,
        )
        try:
            await lk.room.create_room(
                api.CreateRoomRequest(
                    name=_ROOM_NAME,
                    empty_timeout=_ROOM_EMPTY_TIMEOUT_SEC,
                    max_participants=2,
                ),
            )
        finally:
            await lk.aclose()

    async def _delete_room(self) -> None:
        """Delete the LiveKit room via the server API.

        Best-effort — failure to delete is logged but not raised.
        """
        lk = api.LiveKitAPI(
            url=self._config.livekit_url,
            api_key=self._config.api_key,
            api_secret=self._config.api_secret,
        )
        try:
            await lk.room.delete_room(api.DeleteRoomRequest(room=_ROOM_NAME))
        finally:
            await lk.aclose()
