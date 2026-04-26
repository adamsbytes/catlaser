"""Tests for :class:`DaemonConfig`: env loading + validation."""

from __future__ import annotations

from pathlib import Path

import pytest

from catlaser_brain.daemon.config import (
    ENV_ACL_POLL_INTERVAL,
    ENV_APP_PORT,
    ENV_BIND_ADDRESS,
    ENV_BIND_INTERFACE,
    ENV_COORD_BASE_URL,
    ENV_DATABASE_PATH,
    ENV_DEVICE_KEY_PATH,
    ENV_DEVICE_NAME,
    ENV_DEVICE_SLUG,
    ENV_FIRMWARE_VERSION,
    ENV_HOPPER_GPIO_PATH,
    ENV_PROVISIONING_TOKEN,
    ENV_TAILSCALE_HOST,
    ENV_VISION_SOCKET,
    ConfigError,
    DaemonConfig,
)


@pytest.fixture
def cleared_env(monkeypatch: pytest.MonkeyPatch) -> pytest.MonkeyPatch:
    """Yield a clean env where every catlaser var is unset.

    Tests then set only the vars they care about, so an unrelated
    leak in a CI environment never makes a test pass for the wrong
    reason.
    """
    for name in (
        ENV_ACL_POLL_INTERVAL,
        ENV_APP_PORT,
        ENV_BIND_ADDRESS,
        ENV_BIND_INTERFACE,
        ENV_COORD_BASE_URL,
        ENV_DATABASE_PATH,
        ENV_DEVICE_KEY_PATH,
        ENV_DEVICE_NAME,
        ENV_DEVICE_SLUG,
        ENV_FIRMWARE_VERSION,
        ENV_HOPPER_GPIO_PATH,
        ENV_PROVISIONING_TOKEN,
        ENV_TAILSCALE_HOST,
        ENV_VISION_SOCKET,
        "LIVEKIT_URL",
        "FCM_SERVICE_ACCOUNT_PATH",
    ):
        monkeypatch.delenv(name, raising=False)
    return monkeypatch


def _set_required(env: pytest.MonkeyPatch) -> None:
    env.setenv(ENV_COORD_BASE_URL, "https://api.catlaser.test")
    env.setenv(ENV_DEVICE_SLUG, "cat-test-01")


class TestRequiredFields:
    def test_missing_coord_url_raises(self, cleared_env: pytest.MonkeyPatch) -> None:
        cleared_env.setenv(ENV_DEVICE_SLUG, "cat-test-01")
        with pytest.raises(ConfigError, match=ENV_COORD_BASE_URL):
            DaemonConfig.from_env()

    def test_missing_device_slug_raises(self, cleared_env: pytest.MonkeyPatch) -> None:
        cleared_env.setenv(ENV_COORD_BASE_URL, "https://api.catlaser.test")
        with pytest.raises(ConfigError, match=ENV_DEVICE_SLUG):
            DaemonConfig.from_env()

    def test_https_required(self, cleared_env: pytest.MonkeyPatch) -> None:
        cleared_env.setenv(ENV_COORD_BASE_URL, "http://insecure.example")
        cleared_env.setenv(ENV_DEVICE_SLUG, "cat-test-01")
        # Plain HTTP would defeat the device attestation's MITM
        # resistance; the loader rejects upfront.
        with pytest.raises(ConfigError, match="https://"):
            DaemonConfig.from_env()


class TestDefaults:
    def test_defaults_filled_when_env_minimal(
        self,
        cleared_env: pytest.MonkeyPatch,
    ) -> None:
        _set_required(cleared_env)
        config = DaemonConfig.from_env()
        assert config.coord_base_url == "https://api.catlaser.test"
        assert config.device_slug == "cat-test-01"
        assert config.app_port == 9820
        assert config.acl_poll_interval == 60.0
        # Bind address is left empty — orchestrator resolves at startup.
        assert config.bind_address == ""
        # Default interface is the tailnet interface.
        assert config.bind_interface == "tailscale0"
        # Optional fields default to "disabled" rather than required.
        assert config.hopper_gpio_path == ""
        assert config.provisioning_token == ""
        assert config.livekit_enabled is False
        assert config.push_enabled is False


class TestValidation:
    def test_port_out_of_range_raises(self, cleared_env: pytest.MonkeyPatch) -> None:
        _set_required(cleared_env)
        cleared_env.setenv(ENV_APP_PORT, "70000")
        with pytest.raises(ConfigError, match=ENV_APP_PORT):
            DaemonConfig.from_env()

    def test_port_zero_raises(self, cleared_env: pytest.MonkeyPatch) -> None:
        _set_required(cleared_env)
        cleared_env.setenv(ENV_APP_PORT, "0")
        with pytest.raises(ConfigError, match=ENV_APP_PORT):
            DaemonConfig.from_env()

    def test_negative_acl_interval_raises(self, cleared_env: pytest.MonkeyPatch) -> None:
        _set_required(cleared_env)
        cleared_env.setenv(ENV_ACL_POLL_INTERVAL, "-1")
        with pytest.raises(ConfigError, match=ENV_ACL_POLL_INTERVAL):
            DaemonConfig.from_env()

    def test_non_integer_port_raises(self, cleared_env: pytest.MonkeyPatch) -> None:
        _set_required(cleared_env)
        cleared_env.setenv(ENV_APP_PORT, "not-a-number")
        with pytest.raises(ConfigError):
            DaemonConfig.from_env()

    def test_provisioning_without_tailscale_host_raises(
        self,
        cleared_env: pytest.MonkeyPatch,
    ) -> None:
        _set_required(cleared_env)
        cleared_env.setenv(ENV_PROVISIONING_TOKEN, "pv-secret")
        # The server needs the tailnet endpoint to publish to the app
        # at pair time. Without it, provisioning is meaningless.
        with pytest.raises(ConfigError, match=ENV_TAILSCALE_HOST):
            DaemonConfig.from_env()

    def test_provisioning_with_tailscale_host_succeeds(
        self,
        cleared_env: pytest.MonkeyPatch,
    ) -> None:
        _set_required(cleared_env)
        cleared_env.setenv(ENV_PROVISIONING_TOKEN, "pv-secret")
        cleared_env.setenv(ENV_TAILSCALE_HOST, "100.64.0.5")
        config = DaemonConfig.from_env()
        assert config.provisioning_token == "pv-secret"
        assert config.tailscale_host == "100.64.0.5"


class TestPathOverrides:
    def test_database_path_override(
        self,
        cleared_env: pytest.MonkeyPatch,
        tmp_path: Path,
    ) -> None:
        _set_required(cleared_env)
        custom = tmp_path / "custom.db"
        cleared_env.setenv(ENV_DATABASE_PATH, str(custom))
        config = DaemonConfig.from_env()
        assert config.database_path == custom

    def test_vision_socket_override(
        self,
        cleared_env: pytest.MonkeyPatch,
        tmp_path: Path,
    ) -> None:
        _set_required(cleared_env)
        sock = tmp_path / "v.sock"
        cleared_env.setenv(ENV_VISION_SOCKET, str(sock))
        config = DaemonConfig.from_env()
        assert config.vision_socket_path == sock


class TestOptionalIntegrations:
    def test_livekit_enabled_when_url_set(
        self,
        cleared_env: pytest.MonkeyPatch,
    ) -> None:
        _set_required(cleared_env)
        cleared_env.setenv("LIVEKIT_URL", "wss://livekit.example")
        config = DaemonConfig.from_env()
        # The DaemonConfig only sets the marker — actual StreamConfig
        # construction happens later. Validation of the full LiveKit
        # quartet is the responsibility of StreamConfig.from_env.
        assert config.livekit_enabled is True

    def test_push_enabled_when_path_set(
        self,
        cleared_env: pytest.MonkeyPatch,
    ) -> None:
        _set_required(cleared_env)
        cleared_env.setenv("FCM_SERVICE_ACCOUNT_PATH", "/run/secrets/fcm.json")
        config = DaemonConfig.from_env()
        assert config.push_enabled is True
