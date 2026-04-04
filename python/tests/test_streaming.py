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
_TEST_API_SECRET = "thisisaverylongsecretkeythatmustbeatleast32bytes"  # noqa: S105
_TEST_URL = "wss://livekit.test.local"


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

        config = StreamConfig.from_env()
        assert config.livekit_url == _TEST_URL
        assert config.api_key == _TEST_API_KEY
        assert config.api_secret == _TEST_API_SECRET

    def test_from_env_missing_all(self, monkeypatch: pytest.MonkeyPatch):
        monkeypatch.delenv("LIVEKIT_URL", raising=False)
        monkeypatch.delenv("LIVEKIT_API_KEY", raising=False)
        monkeypatch.delenv("LIVEKIT_API_SECRET", raising=False)

        with pytest.raises(ValueError, match="LIVEKIT_URL"):
            StreamConfig.from_env()

    def test_from_env_missing_one(self, monkeypatch: pytest.MonkeyPatch):
        monkeypatch.setenv("LIVEKIT_URL", _TEST_URL)
        monkeypatch.setenv("LIVEKIT_API_KEY", _TEST_API_KEY)
        monkeypatch.delenv("LIVEKIT_API_SECRET", raising=False)

        with pytest.raises(ValueError, match="LIVEKIT_API_SECRET"):
            StreamConfig.from_env()

    def test_from_env_empty_value(self, monkeypatch: pytest.MonkeyPatch):
        monkeypatch.setenv("LIVEKIT_URL", "")
        monkeypatch.setenv("LIVEKIT_API_KEY", _TEST_API_KEY)
        monkeypatch.setenv("LIVEKIT_API_SECRET", _TEST_API_SECRET)

        with pytest.raises(ValueError, match="LIVEKIT_URL"):
            StreamConfig.from_env()

    def test_frozen(self, stream_config: StreamConfig):
        with pytest.raises(AttributeError):
            stream_config.livekit_url = "wss://other"  # type: ignore[misc]


# ---------------------------------------------------------------------------
# Token generation
# ---------------------------------------------------------------------------


class TestTokenGeneration:
    def test_publisher_token_is_valid_jwt(self, stream_config: StreamConfig):
        token = generate_publisher_token(stream_config)
        decoded = _decode_jwt(token)
        assert decoded["sub"] == "catlaser-device"
        video = decoded["video"]
        assert video["roomJoin"] is True
        assert video["room"] == "catlaser-live"
        assert video["canPublish"] is True
        assert video["canSubscribe"] is False

    def test_subscriber_token_is_valid_jwt(self, stream_config: StreamConfig):
        token = generate_subscriber_token(stream_config)
        decoded = _decode_jwt(token)
        assert decoded["sub"] == "catlaser-app"
        video = decoded["video"]
        assert video["roomJoin"] is True
        assert video["room"] == "catlaser-live"
        assert video["canPublish"] is False
        assert video["canSubscribe"] is True

    def test_publisher_and_subscriber_tokens_differ(self, stream_config: StreamConfig):
        pub = generate_publisher_token(stream_config)
        sub = generate_subscriber_token(stream_config)
        assert pub != sub

    def test_tokens_have_expiry(self, stream_config: StreamConfig):
        token = generate_publisher_token(stream_config)
        decoded = _decode_jwt(token)
        assert "exp" in decoded
        assert decoded["exp"] > time.time()


# ---------------------------------------------------------------------------
# StreamManager
# ---------------------------------------------------------------------------


class TestStreamManager:
    def test_start_returns_credentials(self, managed_stream: StreamManager):
        creds = managed_stream.start()

        assert isinstance(creds, StreamCredentials)
        assert creds.livekit_url == _TEST_URL
        assert creds.room_name == "catlaser-live"
        assert creds.target_bitrate_bps > 0
        assert len(creds.subscriber_token) > 0
        assert len(creds.publisher_token) > 0
        assert creds.subscriber_token != creds.publisher_token

    def test_start_twice_raises(self, managed_stream: StreamManager):
        managed_stream.start()
        with pytest.raises(RuntimeError, match="already active"):
            managed_stream.start()

    def test_stop_after_start(self, managed_stream: StreamManager):
        managed_stream.start()
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
        managed_stream.start()
        assert managed_stream.is_streaming
        managed_stream.close()
        assert not managed_stream.is_streaming

    def test_start_after_stop_restarts(self, managed_stream: StreamManager):
        managed_stream.start()
        managed_stream.stop()
        creds = managed_stream.start()
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
        event = handler.handle(req)

        assert event.request_id == 1
        assert event.HasField("stream_offer")
        assert event.stream_offer.livekit_url == _TEST_URL
        assert len(event.stream_offer.subscriber_token) > 0

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
        handler.handle(req)

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
        handler.handle(req)

        event = handler.handle(req)
        assert event.HasField("error")
        assert "already active" in event.error.message

    def test_stop_stream_returns_status(
        self,
        conn: Database,
        state: DeviceState,
        managed_stream: StreamManager,
    ):
        handler = RequestHandler(conn.conn, state, stream_manager=managed_stream)

        handler.handle(pb.AppRequest(start_stream=pb.StartStreamRequest()))
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
        event = handler.handle(req)
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
