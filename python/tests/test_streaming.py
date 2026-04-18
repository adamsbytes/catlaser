"""Tests for LiveKit streaming: token generation, StreamManager, and handler integration."""

from __future__ import annotations

import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any
from unittest.mock import AsyncMock, patch

import jwt
import pytest

from catlaser_brain.network.handler import DeviceState, RequestHandler
from catlaser_brain.network.streaming import (
    StreamConfig,
    StreamCredentials,
    StreamManager,
    generate_publisher_token,
    generate_subscriber_token,
)
from catlaser_brain.proto.catlaser.app.v1 import app_pb2 as pb
from catlaser_brain.storage.db import Database

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

_TEST_API_KEY = "APIdevKey1234"
_TEST_API_SECRET = "thisisaverylongsecretkeythatmustbeatleast32bytes"
_TEST_URL = "wss://livekit.test.local"
_TEST_DEVICE_SLUG = "cat-test-01"
_TEST_USER_SPKI = "dGVzdC11c2VyLXNwa2ktYjY0"  # base64 of "test-user-spki-b64"


def _decode_jwt(token: str) -> dict[str, Any]:
    """Decode a JWT token for test assertions, typed to satisfy pyright."""
    return jwt.decode(  # pyright: ignore[reportUnknownMemberType]
        token,
        _TEST_API_SECRET,
        algorithms=["HS256"],
    )


@pytest.fixture
def stream_config() -> StreamConfig:
    return StreamConfig(
        livekit_url=_TEST_URL,
        api_key=_TEST_API_KEY,
        api_secret=_TEST_API_SECRET,
        device_slug=_TEST_DEVICE_SLUG,
    )


@pytest.fixture
def managed_stream(stream_config: StreamConfig) -> Iterator[StreamManager]:
    """Yield a StreamManager with room APIs mocked out."""
    with (
        patch.object(StreamManager, "_create_room", new_callable=AsyncMock),
        patch.object(StreamManager, "_delete_room", new_callable=AsyncMock),
    ):
        mgr = StreamManager(stream_config)
        yield mgr
        mgr.close()


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


# ---------------------------------------------------------------------------
# StreamConfig
# ---------------------------------------------------------------------------


class TestStreamConfig:
    def test_from_env(self, monkeypatch: pytest.MonkeyPatch):
        monkeypatch.setenv("LIVEKIT_URL", _TEST_URL)
        monkeypatch.setenv("LIVEKIT_API_KEY", _TEST_API_KEY)
        monkeypatch.setenv("LIVEKIT_API_SECRET", _TEST_API_SECRET)
        monkeypatch.setenv("DEVICE_SLUG", _TEST_DEVICE_SLUG)

        config = StreamConfig.from_env()
        assert config.livekit_url == _TEST_URL
        assert config.api_key == _TEST_API_KEY
        assert config.api_secret == _TEST_API_SECRET
        assert config.device_slug == _TEST_DEVICE_SLUG
        assert config.room_name == f"catlaser-live-{_TEST_DEVICE_SLUG}"
        assert config.publisher_identity == f"catlaser-device-{_TEST_DEVICE_SLUG}"

    def test_from_env_missing_all(self, monkeypatch: pytest.MonkeyPatch):
        monkeypatch.delenv("LIVEKIT_URL", raising=False)
        monkeypatch.delenv("LIVEKIT_API_KEY", raising=False)
        monkeypatch.delenv("LIVEKIT_API_SECRET", raising=False)
        monkeypatch.delenv("DEVICE_SLUG", raising=False)

        with pytest.raises(ValueError, match="LIVEKIT_URL"):
            StreamConfig.from_env()

    def test_from_env_missing_one(self, monkeypatch: pytest.MonkeyPatch):
        monkeypatch.setenv("LIVEKIT_URL", _TEST_URL)
        monkeypatch.setenv("LIVEKIT_API_KEY", _TEST_API_KEY)
        monkeypatch.delenv("LIVEKIT_API_SECRET", raising=False)
        monkeypatch.setenv("DEVICE_SLUG", _TEST_DEVICE_SLUG)

        with pytest.raises(ValueError, match="LIVEKIT_API_SECRET"):
            StreamConfig.from_env()

    def test_from_env_missing_device_slug(self, monkeypatch: pytest.MonkeyPatch):
        monkeypatch.setenv("LIVEKIT_URL", _TEST_URL)
        monkeypatch.setenv("LIVEKIT_API_KEY", _TEST_API_KEY)
        monkeypatch.setenv("LIVEKIT_API_SECRET", _TEST_API_SECRET)
        monkeypatch.delenv("DEVICE_SLUG", raising=False)

        with pytest.raises(ValueError, match="DEVICE_SLUG"):
            StreamConfig.from_env()

    def test_from_env_empty_value(self, monkeypatch: pytest.MonkeyPatch):
        monkeypatch.setenv("LIVEKIT_URL", "")
        monkeypatch.setenv("LIVEKIT_API_KEY", _TEST_API_KEY)
        monkeypatch.setenv("LIVEKIT_API_SECRET", _TEST_API_SECRET)
        monkeypatch.setenv("DEVICE_SLUG", _TEST_DEVICE_SLUG)

        with pytest.raises(ValueError, match="LIVEKIT_URL"):
            StreamConfig.from_env()

    def test_frozen(self, stream_config: StreamConfig):
        with pytest.raises(AttributeError):
            stream_config.livekit_url = "wss://other"  # type: ignore[misc]

    def test_rejects_malformed_slug(self):
        # Slugs with slashes, spaces, or non-ASCII bytes would land in
        # LiveKit room names / identities unmodified. Reject at the
        # config boundary so a malformed value never reaches the wire.
        for bad in ("cat/slash", "cat space", "", "-leading-dash", "a" * 64):
            with pytest.raises(ValueError, match="device_slug"):
                StreamConfig(
                    livekit_url=_TEST_URL,
                    api_key=_TEST_API_KEY,
                    api_secret=_TEST_API_SECRET,
                    device_slug=bad,
                )


# ---------------------------------------------------------------------------
# Token generation
# ---------------------------------------------------------------------------


class TestTokenGeneration:
    def test_publisher_token_is_valid_jwt(self, stream_config: StreamConfig):
        token = generate_publisher_token(stream_config)
        decoded = _decode_jwt(token)
        assert decoded["sub"] == f"catlaser-device-{_TEST_DEVICE_SLUG}"
        video = decoded["video"]
        assert video["roomJoin"] is True
        assert video["room"] == f"catlaser-live-{_TEST_DEVICE_SLUG}"
        assert video["canPublish"] is True
        assert video["canSubscribe"] is False

    def test_subscriber_token_is_valid_jwt(self, stream_config: StreamConfig):
        token = generate_subscriber_token(stream_config, user_spki_b64=_TEST_USER_SPKI)
        decoded = _decode_jwt(token)
        assert decoded["sub"] == _TEST_USER_SPKI
        video = decoded["video"]
        assert video["roomJoin"] is True
        assert video["room"] == f"catlaser-live-{_TEST_DEVICE_SLUG}"
        assert video["canPublish"] is False
        assert video["canSubscribe"] is True

    def test_subscriber_token_requires_non_empty_spki(
        self,
        stream_config: StreamConfig,
    ):
        with pytest.raises(ValueError, match="user_spki_b64"):
            generate_subscriber_token(stream_config, user_spki_b64="")

    def test_publisher_and_subscriber_tokens_differ(self, stream_config: StreamConfig):
        pub = generate_publisher_token(stream_config)
        sub = generate_subscriber_token(stream_config, user_spki_b64=_TEST_USER_SPKI)
        assert pub != sub

    def test_tokens_have_expiry(self, stream_config: StreamConfig):
        token = generate_publisher_token(stream_config)
        decoded = _decode_jwt(token)
        assert "exp" in decoded
        assert decoded["exp"] > time.time()
        # Publisher TTL is 15 minutes.
        assert decoded["exp"] - time.time() < 20 * 60

    def test_subscriber_token_has_short_ttl(self, stream_config: StreamConfig):
        token = generate_subscriber_token(stream_config, user_spki_b64=_TEST_USER_SPKI)
        decoded = _decode_jwt(token)
        # 5-minute TTL bounds the blast radius of a leaked token.
        assert decoded["exp"] - time.time() < 6 * 60

    def test_per_device_tokens_are_distinct(self):
        config_a = StreamConfig(
            livekit_url=_TEST_URL,
            api_key=_TEST_API_KEY,
            api_secret=_TEST_API_SECRET,
            device_slug="cat-alpha",
        )
        config_b = StreamConfig(
            livekit_url=_TEST_URL,
            api_key=_TEST_API_KEY,
            api_secret=_TEST_API_SECRET,
            device_slug="cat-beta",
        )
        token_a = generate_subscriber_token(config_a, user_spki_b64=_TEST_USER_SPKI)
        token_b = generate_subscriber_token(config_b, user_spki_b64=_TEST_USER_SPKI)
        # Same user, different device slug => different room grant.
        room_a = _decode_jwt(token_a)["video"]["room"]
        room_b = _decode_jwt(token_b)["video"]["room"]
        assert room_a != room_b
        assert room_a == "catlaser-live-cat-alpha"
        assert room_b == "catlaser-live-cat-beta"


# ---------------------------------------------------------------------------
# StreamManager
# ---------------------------------------------------------------------------


class TestStreamManager:
    def test_start_returns_credentials(self, managed_stream: StreamManager):
        creds = managed_stream.start(user_spki_b64=_TEST_USER_SPKI)

        assert isinstance(creds, StreamCredentials)
        assert creds.livekit_url == _TEST_URL
        assert creds.room_name == f"catlaser-live-{_TEST_DEVICE_SLUG}"
        assert creds.target_bitrate_bps > 0
        assert len(creds.subscriber_token) > 0
        assert len(creds.publisher_token) > 0
        assert creds.subscriber_token != creds.publisher_token

    def test_start_binds_subscriber_token_to_user_spki(
        self,
        managed_stream: StreamManager,
    ):
        creds = managed_stream.start(user_spki_b64=_TEST_USER_SPKI)
        decoded = _decode_jwt(creds.subscriber_token)
        assert decoded["sub"] == _TEST_USER_SPKI

    def test_start_twice_raises(self, managed_stream: StreamManager):
        managed_stream.start(user_spki_b64=_TEST_USER_SPKI)
        with pytest.raises(RuntimeError, match="already active"):
            managed_stream.start(user_spki_b64=_TEST_USER_SPKI)

    def test_stop_after_start(self, managed_stream: StreamManager):
        managed_stream.start(user_spki_b64=_TEST_USER_SPKI)
        assert managed_stream.is_streaming
        managed_stream.stop()
        assert not managed_stream.is_streaming

    def test_stop_when_not_streaming_is_idempotent(
        self,
        managed_stream: StreamManager,
    ):
        managed_stream.stop()
        assert not managed_stream.is_streaming

    def test_close_stops_active_stream(self, managed_stream: StreamManager):
        managed_stream.start(user_spki_b64=_TEST_USER_SPKI)
        assert managed_stream.is_streaming
        managed_stream.close()
        assert not managed_stream.is_streaming

    def test_start_after_stop_restarts(self, managed_stream: StreamManager):
        managed_stream.start(user_spki_b64=_TEST_USER_SPKI)
        managed_stream.stop()
        creds = managed_stream.start(user_spki_b64=_TEST_USER_SPKI)
        assert managed_stream.is_streaming
        assert len(creds.publisher_token) > 0


# ---------------------------------------------------------------------------
# Handler streaming integration
# ---------------------------------------------------------------------------


class TestHandlerStreaming:
    def test_start_stream_returns_offer(
        self,
        conn: Database,
        state: DeviceState,
        managed_stream: StreamManager,
    ):
        handler = RequestHandler(conn.conn, state, stream_manager=managed_stream)

        req = pb.AppRequest(
            request_id=1,
            start_stream=pb.StartStreamRequest(),
        )
        event = handler.handle(req, authorized_spki=_TEST_USER_SPKI)

        assert event.request_id == 1
        assert event.HasField("stream_offer")
        assert event.stream_offer.livekit_url == _TEST_URL
        assert len(event.stream_offer.subscriber_token) > 0
        # The subscriber token MUST be bound to the authenticated user's
        # SPKI — otherwise an attacker who acquires a token cannot be
        # distinguished from the legitimate viewer server-side.
        decoded = _decode_jwt(event.stream_offer.subscriber_token)
        assert decoded["sub"] == _TEST_USER_SPKI

    def test_start_stream_without_authorized_spki_errors(
        self,
        conn: Database,
        state: DeviceState,
        managed_stream: StreamManager,
    ):
        # Defence-in-depth: if the server ever dispatched a
        # start_stream without an SPKI we would mint an unbound
        # token. The handler refuses.
        handler = RequestHandler(conn.conn, state, stream_manager=managed_stream)
        req = pb.AppRequest(start_stream=pb.StartStreamRequest())
        event = handler.handle(req, authorized_spki=None)
        assert event.HasField("error")
        assert "authorized session" in event.error.message.lower()
        # The manager must not have started; a future request can
        # still succeed when the SPKI is supplied.
        assert not managed_stream.is_streaming

    def test_start_stream_notifies(
        self,
        conn: Database,
        state: DeviceState,
        managed_stream: StreamManager,
    ):
        notifications: list[StreamCredentials] = []

        class _Notify:
            def on_stream_start(self, credentials: StreamCredentials) -> None:
                notifications.append(credentials)

            def on_stream_stop(self) -> None:
                pass

        handler = RequestHandler(
            conn.conn,
            state,
            stream_manager=managed_stream,
            stream_notify=_Notify(),
        )

        req = pb.AppRequest(start_stream=pb.StartStreamRequest())
        handler.handle(req, authorized_spki=_TEST_USER_SPKI)

        assert len(notifications) == 1
        assert notifications[0].livekit_url == _TEST_URL
        assert len(notifications[0].publisher_token) > 0

    def test_start_stream_twice_returns_error(
        self,
        conn: Database,
        state: DeviceState,
        managed_stream: StreamManager,
    ):
        handler = RequestHandler(conn.conn, state, stream_manager=managed_stream)

        req = pb.AppRequest(start_stream=pb.StartStreamRequest())
        handler.handle(req, authorized_spki=_TEST_USER_SPKI)

        event = handler.handle(req, authorized_spki=_TEST_USER_SPKI)
        assert event.HasField("error")
        assert "already active" in event.error.message

    def test_stop_stream_returns_status(
        self,
        conn: Database,
        state: DeviceState,
        managed_stream: StreamManager,
    ):
        handler = RequestHandler(conn.conn, state, stream_manager=managed_stream)

        handler.handle(
            pb.AppRequest(start_stream=pb.StartStreamRequest()),
            authorized_spki=_TEST_USER_SPKI,
        )
        event = handler.handle(
            pb.AppRequest(stop_stream=pb.StopStreamRequest()),
        )

        assert event.HasField("status_update")
        assert not managed_stream.is_streaming

    def test_start_stream_without_manager_returns_error(
        self,
        conn: Database,
        state: DeviceState,
    ):
        handler = RequestHandler(conn.conn, state)
        req = pb.AppRequest(start_stream=pb.StartStreamRequest())
        event = handler.handle(req, authorized_spki=_TEST_USER_SPKI)
        assert event.HasField("error")
        assert "not configured" in event.error.message

    def test_stop_stream_without_manager_returns_error(
        self,
        conn: Database,
        state: DeviceState,
    ):
        handler = RequestHandler(conn.conn, state)
        req = pb.AppRequest(stop_stream=pb.StopStreamRequest())
        event = handler.handle(req)
        assert event.HasField("error")
        assert "not configured" in event.error.message
