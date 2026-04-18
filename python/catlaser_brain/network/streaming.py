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
    ``LIVEKIT_API_KEY``, ``LIVEKIT_API_SECRET``, ``LIVEKIT_URL``,
    ``DEVICE_SLUG`` (the device's server-assigned identifier, used to
    scope the LiveKit room name and participant identities so multiple
    devices sharing a LiveKit project cannot step on each other's
    streams).
"""

from __future__ import annotations

import asyncio
import dataclasses
import datetime as dt
import os
import re
from typing import Final

from livekit import api

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_ROOM_PREFIX: Final[str] = "catlaser-live-"
"""Prefix for per-device room names. A deployment with N devices on a
shared LiveKit project produces N distinct rooms, each with
max_participants=2, so a subscriber token minted for one household
cannot subscribe to another household's publisher. A prior design used
a fixed ``"catlaser-live"`` name across the fleet, which conflated
tenant boundaries with the LiveKit API secret — a rogue insider with a
valid token for their own room could have joined anyone else's.
"""

_PUBLISHER_IDENTITY_PREFIX: Final[str] = "catlaser-device-"
"""Prefix for the device-side publisher's LiveKit identity. Scoped to
the device slug so the app's participant-identity check can verify
that the video track it's about to render came from the device the
user actually paired with."""

_SLUG_PATTERN: Final[re.Pattern[str]] = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$")
"""Whitelist for device slugs — mirrors the server-side slug format
(ASCII alnum + dash + underscore, 1-63 chars starting with alnum).
Rejecting a malformed slug at StreamConfig construction time prevents
an unvetted input from appearing in a LiveKit room name / identity,
which protocol-wise tolerates anything but operationally is much
cleaner to keep constrained."""

_ROOM_EMPTY_TIMEOUT_SEC: Final[int] = 30
"""Seconds after the last participant leaves before the LiveKit server
automatically destroys the room. Short — the device re-creates the room
on the next stream start.
"""

_DEFAULT_BITRATE_BPS: Final[int] = 500_000
"""Default target video bitrate in bits per second. 500 kbps is reasonable
for 640x480 @ 15 fps H.264 Constrained Baseline over WiFi.
"""

_SUBSCRIBER_TOKEN_TTL: Final[dt.timedelta] = dt.timedelta(minutes=5)
"""Subscriber JWT lifetime. Short enough that a leaked token ages out
quickly; long enough for the app to receive the StreamOffer, dial
LiveKit, complete the ICE handshake, and begin playback.

A leaked token IS NOT a path into another household — the room name is
per-device and the grants include a user-specific identity — but a
short TTL still minimises the blast radius if a token escapes via a
process-memory dump, a crash log, or a mis-logged exception.
"""

_PUBLISHER_TOKEN_TTL: Final[dt.timedelta] = dt.timedelta(minutes=15)
"""Publisher JWT lifetime. Longer than the subscriber because the
publisher is the device itself (trusted, loopback-only), and a short
TTL forces repeated token churn on the IPC path to Rust. A 15-minute
window is enough for a typical session.
"""


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True, slots=True)
class StreamConfig:
    """LiveKit connection parameters.

    Read from environment variables at construction. All four are
    required — ``from_env`` raises ``ValueError`` if any is missing.

    Attributes:
        livekit_url: LiveKit server WebSocket URL (e.g. ``wss://lk.example.com``).
        api_key: LiveKit API key for token signing and server API auth.
        api_secret: LiveKit API secret for token signing and server API auth.
        device_slug: the server-assigned device identifier. Used to
            derive per-device LiveKit room name and publisher identity
            so multiple devices sharing a LiveKit project cannot step
            on each other's streams. Validated against
            :data:`_SLUG_PATTERN` at construction so malformed input
            fails at startup rather than silently producing a weird
            room name.
    """

    livekit_url: str
    api_key: str
    api_secret: str
    device_slug: str

    def __post_init__(self) -> None:
        if not _SLUG_PATTERN.match(self.device_slug):
            msg = (
                f"device_slug {self.device_slug!r} does not match the "
                f"required pattern (ASCII alnum + dash + underscore, "
                f"1-63 chars starting with alnum)"
            )
            raise ValueError(msg)

    @property
    def room_name(self) -> str:
        """Per-device LiveKit room name, stable across stream sessions."""
        return f"{_ROOM_PREFIX}{self.device_slug}"

    @property
    def publisher_identity(self) -> str:
        """Per-device LiveKit publisher identity.

        The iOS app's `LiveKitStreamSession` compares this string
        against ``participant.identity`` on every subscribed track
        and rejects any track from a different identity — the mirror
        of the fleet-wide spoofing fix.
        """
        return f"{_PUBLISHER_IDENTITY_PREFIX}{self.device_slug}"

    @classmethod
    def from_env(cls) -> StreamConfig:
        """Construct from LiveKit + DEVICE_SLUG environment variables.

        Reads ``LIVEKIT_URL``, ``LIVEKIT_API_KEY``, ``LIVEKIT_API_SECRET``,
        and ``DEVICE_SLUG``; all four are required.

        Raises:
            ValueError: If any required environment variable is unset or empty.
        """
        url = os.environ.get("LIVEKIT_URL", "")
        key = os.environ.get("LIVEKIT_API_KEY", "")
        secret = os.environ.get("LIVEKIT_API_SECRET", "")
        slug = os.environ.get("DEVICE_SLUG", "")

        missing: list[str] = []
        if not url:
            missing.append("LIVEKIT_URL")
        if not key:
            missing.append("LIVEKIT_API_KEY")
        if not secret:
            missing.append("LIVEKIT_API_SECRET")
        if not slug:
            missing.append("DEVICE_SLUG")

        if missing:
            msg = f"missing required environment variables: {', '.join(missing)}"
            raise ValueError(msg)

        return cls(
            livekit_url=url,
            api_key=key,
            api_secret=secret,
            device_slug=slug,
        )


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
    (the device doesn't need to receive media from the app). Scoped
    to the per-device room and carries a TTL so a leaked token ages
    out — see :data:`_PUBLISHER_TOKEN_TTL`.
    """
    token = (
        api.AccessToken(api_key=config.api_key, api_secret=config.api_secret)
        .with_identity(config.publisher_identity)
        .with_name("Catlaser Device")
        .with_ttl(_PUBLISHER_TOKEN_TTL)
        .with_grants(
            api.VideoGrants(
                room_join=True,
                room=config.room_name,
                can_publish=True,
                can_subscribe=False,
            ),
        )
    )
    return token.to_jwt()


def generate_subscriber_token(config: StreamConfig, user_spki_b64: str) -> str:
    """Generate a JWT for the app to subscribe to the per-device room.

    The token grants room join + subscribe permissions but not publish
    (the app is a viewer, not a broadcaster). Three scoping properties
    are load-bearing:

    * The identity is set to ``user_spki_b64`` — the SPKI that the
      handshake already authenticated for this TCP session. LiveKit
      uses identity as the de-duplication key for participant joins,
      so a second connection presenting the same token reveals itself
      on the server-side participant list.
    * The room is per-device (:meth:`StreamConfig.room_name`). A leaked
      token grants subscribe access only to that room; it cannot
      reach another household's publisher even if they share a
      LiveKit project.
    * A TTL is attached (:data:`_SUBSCRIBER_TOKEN_TTL`). The LiveKit
      SDK defaults tokens to 6 hours; the short explicit TTL bounds
      the blast radius of a token that escaped via a crash log.
    """
    if not user_spki_b64:
        msg = "user_spki_b64 must be non-empty"
        raise ValueError(msg)
    token = (
        api.AccessToken(api_key=config.api_key, api_secret=config.api_secret)
        .with_identity(user_spki_b64)
        .with_name("Catlaser App")
        .with_ttl(_SUBSCRIBER_TOKEN_TTL)
        .with_grants(
            api.VideoGrants(
                room_join=True,
                room=config.room_name,
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

    def start(self, *, user_spki_b64: str) -> StreamCredentials:
        """Start a live stream: create room, generate tokens.

        Returns credentials for the app (subscriber token bound to
        ``user_spki_b64`` — the SPKI that the TCP handshake already
        authenticated for the requesting client) and the Rust daemon
        (publisher token bound to the device identity). The caller is
        responsible for sending the publisher credentials to Rust
        via IPC.

        Args:
            user_spki_b64: standard-base64 DER SPKI of the user who
                asked for the stream. Becomes the LiveKit participant
                identity on the subscriber token. Non-empty.

        Raises:
            RuntimeError: If a stream is already active.
            ValueError: If ``user_spki_b64`` is empty.
        """
        if self._streaming:
            msg = "stream already active"
            raise RuntimeError(msg)

        self._loop.run_until_complete(self._create_room())
        self._streaming = True

        return StreamCredentials(
            livekit_url=self._config.livekit_url,
            subscriber_token=generate_subscriber_token(
                self._config,
                user_spki_b64=user_spki_b64,
            ),
            publisher_token=generate_publisher_token(self._config),
            room_name=self._config.room_name,
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
                    name=self._config.room_name,
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
            await lk.room.delete_room(
                api.DeleteRoomRequest(room=self._config.room_name),
            )
        finally:
            await lk.aclose()
