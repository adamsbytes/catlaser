"""Tests for push notifications: config, CRUD, payload construction,
send logic, handler integration, and edge cases.
"""

from __future__ import annotations

import json
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any
from unittest.mock import patch

import pytest

from catlaser_brain.network.handler import DeviceState, RequestHandler
from catlaser_brain.network.push import (
    PushConfig,
    PushNotifier,
    build_fcm_message,
)
from catlaser_brain.proto.catlaser.app.v1 import app_pb2 as pb
from catlaser_brain.storage.crud import (
    list_push_tokens,
    register_push_token,
    unregister_push_token,
)
from catlaser_brain.storage.db import Database

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


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


@pytest.fixture
def handler(conn: Database, state: DeviceState) -> RequestHandler:
    return RequestHandler(conn.conn, state)


def _write_service_account(tmp_path: Path, project_id: str = "test-project") -> Path:
    """Write a minimal service account JSON for config tests."""
    sa_path = tmp_path / "sa.json"
    sa_path.write_text(json.dumps({"project_id": project_id}))
    return sa_path


def _last_fcm_message(notifier: PushNotifier) -> dict[str, Any]:
    """Extract the FCM message payload from the last ``_send_one`` mock call."""
    obj: Any = notifier
    result: dict[str, Any] = obj._send_one.call_args[0][1]
    return result


@pytest.fixture
def notifier(conn: Database, tmp_path: Path) -> Iterator[PushNotifier]:
    """PushNotifier with credential loading and send logic mocked."""
    sa_path = _write_service_account(tmp_path)
    config = PushConfig(project_id="test-project", service_account_path=str(sa_path))
    with (
        patch(
            "catlaser_brain.network.push._load_credentials",
        ),
        patch.object(PushNotifier, "_get_access_token", return_value="fake-token"),
        patch.object(PushNotifier, "_send_one", return_value=200),
    ):
        yield PushNotifier(config, conn.conn)


# ===========================================================================
# PushConfig tests
# ===========================================================================


class TestPushConfig:
    def test_from_env(self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
        sa_path = _write_service_account(tmp_path, "my-project")
        monkeypatch.setenv("FCM_SERVICE_ACCOUNT_PATH", str(sa_path))

        config = PushConfig.from_env()
        assert config.project_id == "my-project"
        assert config.service_account_path == str(sa_path)

    def test_from_env_missing_var(self, monkeypatch: pytest.MonkeyPatch):
        monkeypatch.delenv("FCM_SERVICE_ACCOUNT_PATH", raising=False)
        with pytest.raises(ValueError, match="FCM_SERVICE_ACCOUNT_PATH"):
            PushConfig.from_env()

    def test_from_env_empty_var(self, monkeypatch: pytest.MonkeyPatch):
        monkeypatch.setenv("FCM_SERVICE_ACCOUNT_PATH", "")
        with pytest.raises(ValueError, match="FCM_SERVICE_ACCOUNT_PATH"):
            PushConfig.from_env()

    def test_from_env_missing_project_id(self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
        sa_path = tmp_path / "sa.json"
        sa_path.write_text(json.dumps({"client_email": "test@test.iam"}))
        monkeypatch.setenv("FCM_SERVICE_ACCOUNT_PATH", str(sa_path))
        with pytest.raises(ValueError, match="project_id"):
            PushConfig.from_env()

    def test_from_env_file_not_found(self, monkeypatch: pytest.MonkeyPatch):
        monkeypatch.setenv("FCM_SERVICE_ACCOUNT_PATH", "/nonexistent/sa.json")
        with pytest.raises(FileNotFoundError):
            PushConfig.from_env()

    def test_frozen(self, tmp_path: Path):
        sa_path = _write_service_account(tmp_path)
        config = PushConfig(project_id="p", service_account_path=str(sa_path))
        with pytest.raises(AttributeError):
            config.project_id = "q"  # type: ignore[misc]


# ===========================================================================
# Push token CRUD tests (real SQLite)
# ===========================================================================


class TestPushTokenCrud:
    def test_register_and_list(self, conn: Database):
        register_push_token(conn.conn, "tok-1", "fcm")
        tokens = list_push_tokens(conn.conn)
        assert len(tokens) == 1
        assert tokens[0].token == "tok-1"
        assert tokens[0].platform == "fcm"
        assert tokens[0].registered_at > 0

    def test_register_multiple(self, conn: Database):
        register_push_token(conn.conn, "tok-1", "fcm")
        register_push_token(conn.conn, "tok-2", "apns")
        tokens = list_push_tokens(conn.conn)
        assert len(tokens) == 2

    def test_upsert_updates_platform(self, conn: Database):
        register_push_token(conn.conn, "tok-1", "fcm")
        register_push_token(conn.conn, "tok-1", "apns")
        tokens = list_push_tokens(conn.conn)
        assert len(tokens) == 1
        assert tokens[0].platform == "apns"

    def test_unregister(self, conn: Database):
        register_push_token(conn.conn, "tok-1", "fcm")
        unregister_push_token(conn.conn, "tok-1")
        assert list_push_tokens(conn.conn) == []

    def test_unregister_nonexistent_is_idempotent(self, conn: Database):
        unregister_push_token(conn.conn, "nonexistent")
        assert list_push_tokens(conn.conn) == []

    def test_list_empty(self, conn: Database):
        assert list_push_tokens(conn.conn) == []

    def test_list_ordered_by_registration_time(self, conn: Database):
        register_push_token(conn.conn, "tok-a", "fcm")
        register_push_token(conn.conn, "tok-b", "fcm")
        register_push_token(conn.conn, "tok-c", "apns")
        tokens = list_push_tokens(conn.conn)
        assert [t.token for t in tokens] == ["tok-a", "tok-b", "tok-c"]


# ===========================================================================
# FCM message builder tests
# ===========================================================================


class TestBuildFcmMessage:
    def test_basic_structure(self):
        msg = build_fcm_message(
            "device-token",
            "fcm",
            {"title": "Test", "body": "Hello"},
            {"type": "test"},
        )
        assert msg["message"]["token"] == "device-token"
        assert msg["message"]["notification"]["title"] == "Test"
        assert msg["message"]["notification"]["body"] == "Hello"
        assert msg["message"]["data"]["type"] == "test"

    def test_fcm_platform_adds_android_sound(self):
        msg = build_fcm_message(
            "tok",
            "fcm",
            {"title": "T", "body": "B"},
            {"type": "t"},
        )
        assert msg["message"]["android"]["notification"]["sound"] == "default"
        assert "apns" not in msg["message"]

    def test_apns_platform_adds_apns_sound(self):
        msg = build_fcm_message(
            "tok",
            "apns",
            {"title": "T", "body": "B"},
            {"type": "t"},
        )
        assert msg["message"]["apns"]["payload"]["aps"]["sound"] == "default"
        assert "android" not in msg["message"]

    def test_unknown_platform_no_overrides(self):
        msg = build_fcm_message(
            "tok",
            "unknown",
            {"title": "T", "body": "B"},
            {"type": "t"},
        )
        assert "android" not in msg["message"]
        assert "apns" not in msg["message"]

    def test_data_values_are_strings(self):
        msg = build_fcm_message(
            "tok",
            "fcm",
            {"title": "T", "body": "B"},
            {"count": "42", "score": "0.75"},
        )
        for value in msg["message"]["data"].values():
            assert isinstance(value, str)


# ===========================================================================
# PushNotifier tests
# ===========================================================================


class TestNotifierSessionSummary:
    def test_sends_to_registered_token(self, notifier: PushNotifier, conn: Database):
        register_push_token(conn.conn, "tok-1", "fcm")
        notifier.notify_session_summary(
            cat_names=["Luna"],
            duration_sec=300,
            engagement_score=0.85,
            treats_dispensed=5,
            pounce_count=12,
        )
        notifier._send_one.assert_called_once()  # type: ignore[union-attr]
        message = _last_fcm_message(notifier)
        assert message["message"]["token"] == "tok-1"
        assert message["message"]["data"]["type"] == "session_summary"
        assert message["message"]["data"]["duration_sec"] == "300"
        assert message["message"]["data"]["treats_dispensed"] == "5"
        assert message["message"]["data"]["pounce_count"] == "12"
        assert message["message"]["data"]["engagement_score"] == "0.85"

    def test_notification_body_with_single_cat(self, notifier: PushNotifier, conn: Database):
        register_push_token(conn.conn, "tok-1", "fcm")
        notifier.notify_session_summary(["Luna"], 300, 0.8, 5, 12)
        message = _last_fcm_message(notifier)
        body: str = message["message"]["notification"]["body"]
        assert "Luna" in body
        assert "5m0s" in body
        assert "5 treats" in body

    def test_notification_body_with_multiple_cats(self, notifier: PushNotifier, conn: Database):
        register_push_token(conn.conn, "tok-1", "fcm")
        notifier.notify_session_summary(["Luna", "Milo"], 65, 0.9, 3, 8)
        message = _last_fcm_message(notifier)
        body: str = message["message"]["notification"]["body"]
        assert "Luna, Milo" in body
        assert "1m5s" in body

    def test_notification_body_with_no_cats(self, notifier: PushNotifier, conn: Database):
        register_push_token(conn.conn, "tok-1", "fcm")
        notifier.notify_session_summary([], 30, 0.5, 1, 2)
        message = _last_fcm_message(notifier)
        body: str = message["message"]["notification"]["body"]
        assert "Your cat" in body

    def test_notification_body_short_session(self, notifier: PushNotifier, conn: Database):
        register_push_token(conn.conn, "tok-1", "fcm")
        notifier.notify_session_summary(["Luna"], 45, 0.5, 1, 2)
        message = _last_fcm_message(notifier)
        body: str = message["message"]["notification"]["body"]
        assert "45s" in body


class TestNotifierSessionStarted:
    def test_sends_session_started(self, notifier: PushNotifier, conn: Database):
        register_push_token(conn.conn, "tok-1", "fcm")
        notifier.notify_session_started(["Luna"], "scheduled")
        message = _last_fcm_message(notifier)
        assert message["message"]["data"]["type"] == "session_started"
        assert message["message"]["data"]["trigger"] == "scheduled"
        assert "Luna" in message["message"]["notification"]["body"]

    def test_session_started_no_cats(self, notifier: PushNotifier, conn: Database):
        register_push_token(conn.conn, "tok-1", "fcm")
        notifier.notify_session_started([], "cat_detected")
        message = _last_fcm_message(notifier)
        assert "A cat" in message["message"]["notification"]["body"]


class TestNotifierHopperEmpty:
    def test_sends_hopper_empty(self, notifier: PushNotifier, conn: Database):
        register_push_token(conn.conn, "tok-1", "fcm")
        notifier.notify_hopper_empty()
        message = _last_fcm_message(notifier)
        assert message["message"]["data"]["type"] == "hopper_empty"
        assert "Hopper Empty" in message["message"]["notification"]["title"]
        body: str = message["message"]["notification"]["body"]
        assert "refill" in body.lower()


class TestNotifierNewCatDetected:
    def test_sends_new_cat_detected(self, notifier: PushNotifier, conn: Database):
        register_push_token(conn.conn, "tok-1", "fcm")
        notifier.notify_new_cat_detected(track_id_hint=42, confidence=0.85)
        message = _last_fcm_message(notifier)
        assert message["message"]["data"]["type"] == "new_cat_detected"
        assert message["message"]["data"]["track_id_hint"] == "42"
        assert message["message"]["data"]["confidence"] == "0.85"
        assert "New Cat" in message["message"]["notification"]["title"]


class TestNotifierMultiToken:
    def test_sends_to_all_tokens(self, notifier: PushNotifier, conn: Database):
        register_push_token(conn.conn, "tok-1", "fcm")
        register_push_token(conn.conn, "tok-2", "apns")
        register_push_token(conn.conn, "tok-3", "fcm")
        notifier.notify_hopper_empty()
        assert notifier._send_one.call_count == 3  # type: ignore[union-attr]

    def test_no_tokens_is_noop(self, notifier: PushNotifier):
        notifier.notify_hopper_empty()
        notifier._send_one.assert_not_called()  # type: ignore[union-attr]


class TestNotifierTokenPruning:
    def test_prunes_unregistered_token_on_404(self, notifier: PushNotifier, conn: Database):
        # Explicit timestamps to guarantee iteration order (oldest first).
        conn.conn.execute(
            "INSERT INTO push_tokens (token, platform, registered_at) VALUES (?, ?, ?)",
            ("tok-stale", "fcm", 1000),
        )
        conn.conn.execute(
            "INSERT INTO push_tokens (token, platform, registered_at) VALUES (?, ?, ?)",
            ("tok-good", "fcm", 2000),
        )
        conn.conn.commit()
        notifier._send_one.side_effect = [404, 200]  # type: ignore[union-attr]

        notifier.notify_hopper_empty()

        tokens = list_push_tokens(conn.conn)
        assert len(tokens) == 1
        assert tokens[0].token == "tok-good"

    def test_prunes_unregistered_token_on_410(self, notifier: PushNotifier, conn: Database):
        register_push_token(conn.conn, "tok-gone", "fcm")
        notifier._send_one.return_value = 410  # type: ignore[union-attr]

        notifier.notify_hopper_empty()

        assert list_push_tokens(conn.conn) == []

    def test_keeps_token_on_server_error(self, notifier: PushNotifier, conn: Database):
        register_push_token(conn.conn, "tok-1", "fcm")
        notifier._send_one.return_value = 500  # type: ignore[union-attr]

        notifier.notify_hopper_empty()

        tokens = list_push_tokens(conn.conn)
        assert len(tokens) == 1

    def test_keeps_token_on_network_error(self, notifier: PushNotifier, conn: Database):
        register_push_token(conn.conn, "tok-1", "fcm")
        notifier._send_one.return_value = 0  # type: ignore[union-attr]

        notifier.notify_hopper_empty()

        tokens = list_push_tokens(conn.conn)
        assert len(tokens) == 1


class TestNotifierAccessTokenFailure:
    def test_skips_send_when_token_unavailable(self, conn: Database, tmp_path: Path):
        sa_path = _write_service_account(tmp_path)
        config = PushConfig(project_id="test-project", service_account_path=str(sa_path))
        with (
            patch("catlaser_brain.network.push._load_credentials"),
            patch.object(PushNotifier, "_get_access_token", return_value=None),
            patch.object(PushNotifier, "_send_one", return_value=200) as mock_send,
        ):
            n = PushNotifier(config, conn.conn)
            register_push_token(conn.conn, "tok-1", "fcm")
            n.notify_hopper_empty()
            mock_send.assert_not_called()


# ===========================================================================
# Handler integration tests
# ===========================================================================


class TestHandlerRegisterPushToken:
    def test_register_fcm_token(self, handler: RequestHandler, conn: Database):
        req = pb.AppRequest(
            request_id=1,
            register_push_token=pb.RegisterPushTokenRequest(
                token="fcm-token-abc",
                platform=pb.PUSH_PLATFORM_FCM,
            ),
        )
        event = handler.handle(req)
        assert event.request_id == 1
        assert event.HasField("push_token_ack")

        tokens = list_push_tokens(conn.conn)
        assert len(tokens) == 1
        assert tokens[0].token == "fcm-token-abc"
        assert tokens[0].platform == "fcm"

    def test_register_apns_token(self, handler: RequestHandler, conn: Database):
        req = pb.AppRequest(
            register_push_token=pb.RegisterPushTokenRequest(
                token="apns-token-xyz",
                platform=pb.PUSH_PLATFORM_APNS,
            ),
        )
        event = handler.handle(req)
        assert event.HasField("push_token_ack")

        tokens = list_push_tokens(conn.conn)
        assert len(tokens) == 1
        assert tokens[0].platform == "apns"

    def test_register_unspecified_platform_returns_error(self, handler: RequestHandler):
        req = pb.AppRequest(
            register_push_token=pb.RegisterPushTokenRequest(
                token="some-token",
                platform=pb.PUSH_PLATFORM_UNSPECIFIED,
            ),
        )
        event = handler.handle(req)
        assert event.HasField("error")
        assert "platform" in event.error.message.lower()

    def test_register_overwrites_existing_token(self, handler: RequestHandler, conn: Database):
        register_push_token(conn.conn, "tok-1", "fcm")

        req = pb.AppRequest(
            register_push_token=pb.RegisterPushTokenRequest(
                token="tok-1",
                platform=pb.PUSH_PLATFORM_APNS,
            ),
        )
        handler.handle(req)

        tokens = list_push_tokens(conn.conn)
        assert len(tokens) == 1
        assert tokens[0].platform == "apns"


class TestHandlerUnregisterPushToken:
    def test_unregister_token(self, handler: RequestHandler, conn: Database):
        register_push_token(conn.conn, "tok-1", "fcm")

        req = pb.AppRequest(
            request_id=2,
            unregister_push_token=pb.UnregisterPushTokenRequest(token="tok-1"),
        )
        event = handler.handle(req)
        assert event.request_id == 2
        assert event.HasField("push_token_ack")
        assert list_push_tokens(conn.conn) == []

    def test_unregister_nonexistent_is_idempotent(self, handler: RequestHandler):
        req = pb.AppRequest(
            unregister_push_token=pb.UnregisterPushTokenRequest(token="nope"),
        )
        event = handler.handle(req)
        assert event.HasField("push_token_ack")
