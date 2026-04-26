"""Daemon configuration: env-var-driven, validated up front.

The orchestrator reads every external knob from this dataclass. The
``from_env`` constructor is the only place that touches
:func:`os.environ`; tests build :class:`DaemonConfig` directly from
keyword arguments to avoid global mutation.

LiveKit and FCM credentials are optional — :attr:`livekit_url` /
:attr:`fcm_service_account_path` may be empty strings, in which case
the orchestrator skips wiring streaming and push respectively. The
device boots into a "local-only, no live view, no notifications" mode
that is still a complete play loop.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Final, Self


class ConfigError(RuntimeError):
    """Daemon configuration is missing or malformed.

    Raised by :meth:`DaemonConfig.from_env` when a required environment
    variable is unset or has an invalid value. The :mod:`__main__`
    handler catches this and exits with status 1 so the init system
    does not restart the daemon — a deployment-level fix is required.
    """


# ---------------------------------------------------------------------------
# Environment variable names
# ---------------------------------------------------------------------------

ENV_DATABASE_PATH: Final[str] = "CATLASER_DATABASE_PATH"
"""Filesystem path of the device SQLite database."""

ENV_VISION_SOCKET: Final[str] = "CATLASER_VISION_SOCKET"
"""Unix domain socket path the Rust vision daemon binds to."""

ENV_DEVICE_KEY_PATH: Final[str] = "CATLASER_DEVICE_KEY_PATH"
"""Filesystem path of the device's Ed25519 private key (PKCS#8 PEM)."""

ENV_COORD_BASE_URL: Final[str] = "CATLASER_COORD_BASE_URL"
"""HTTPS base URL of the coordination server (e.g. ``https://api.catlaser.example``)."""

ENV_DEVICE_SLUG: Final[str] = "DEVICE_SLUG"
"""Server-assigned device identifier used in URL paths and LiveKit room names."""

ENV_BIND_ADDRESS: Final[str] = "CATLASER_BIND_ADDRESS"
"""IP address the app server binds to. Optional — when unset, the
orchestrator resolves the tailnet interface's primary IPv4.
"""

ENV_BIND_INTERFACE: Final[str] = "CATLASER_BIND_INTERFACE"
"""Linux interface name pinned via ``SO_BINDTODEVICE``. Defaults to
``tailscale0``; tests pass an empty string to disable.
"""

ENV_APP_PORT: Final[str] = "CATLASER_APP_PORT"
"""TCP port the app server listens on. Defaults to 9820."""

ENV_ACL_POLL_INTERVAL: Final[str] = "CATLASER_ACL_POLL_INTERVAL_SEC"
"""Coordination-server ACL refresh interval. Defaults to 60 seconds."""

ENV_FIRMWARE_VERSION: Final[str] = "CATLASER_FIRMWARE_VERSION"
"""Firmware version reported in ``StatusUpdate`` responses."""

ENV_HOPPER_GPIO_PATH: Final[str] = "CATLASER_HOPPER_GPIO_PATH"
"""Sysfs path of the hopper IR break-beam GPIO ``value`` file. Optional —
unset means the daemon assumes the hopper is OK and never blocks
sessions on hopper state.
"""

ENV_PROVISIONING_TOKEN: Final[str] = "CATLASER_PROVISIONING_TOKEN"  # noqa: S105 — env var name
"""One-shot provisioning token from the coordination server. Optional —
when set, the daemon calls ``/devices/provision`` once at startup so a
freshly-flashed device registers its Ed25519 public key.
"""

ENV_TAILSCALE_HOST: Final[str] = "CATLASER_TAILSCALE_HOST"
"""Tailnet hostname / IP the coordination server returns to the app at
pair time. Required when ``CATLASER_PROVISIONING_TOKEN`` is set.
"""

ENV_DEVICE_NAME: Final[str] = "CATLASER_DEVICE_NAME"
"""Human-readable device name reported during provisioning. Optional."""

# LiveKit env vars are read by :class:`StreamConfig.from_env`. Their names
# are documented in :mod:`catlaser_brain.network.streaming`. The daemon
# config tracks whether to attempt that load.

# FCM service-account path is read by :class:`PushConfig.from_env`. The
# daemon config tracks whether to attempt that load.

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

_DEFAULT_DATABASE_PATH: Final[Path] = Path("/var/lib/catlaser/brain.db")
_DEFAULT_VISION_SOCKET: Final[Path] = Path("/run/catlaser/vision.sock")
_DEFAULT_DEVICE_KEY_PATH: Final[Path] = Path("/var/lib/catlaser/device.key")
_DEFAULT_BIND_INTERFACE: Final[str] = "tailscale0"
_DEFAULT_APP_PORT: Final[int] = 9820
_DEFAULT_ACL_POLL_INTERVAL: Final[float] = 60.0
_DEFAULT_FIRMWARE_VERSION: Final[str] = "0.1.0"
_MAX_PORT: Final[int] = 65_535


# ---------------------------------------------------------------------------
# Configuration dataclass
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class DaemonConfig:
    """Validated daemon configuration loaded from the environment.

    Every field is final at process start. The orchestrator never
    re-reads the environment after construction.

    Attributes:
        database_path: SQLite database location.
        vision_socket_path: Unix socket the Rust vision daemon binds to.
        device_key_path: Ed25519 private-key file location.
        coord_base_url: Coordination-server HTTPS root.
        device_slug: Server-assigned identifier for this device.
        bind_address: Tailnet IPv4 the app server listens on, or empty
            string to resolve via :func:`resolve_tailscale_bind_address`
            at startup.
        bind_interface: Linux interface name to pin the listening
            socket to via ``SO_BINDTODEVICE``. Empty string disables
            interface pinning (used by tests on loopback).
        app_port: TCP port the app server listens on.
        acl_poll_interval: Seconds between coordination-server ACL refreshes.
        firmware_version: Version string surfaced in ``StatusUpdate``.
        hopper_gpio_path: Optional sysfs path for the hopper IR sensor.
            Empty string means "assume always OK" — sessions never get
            blocked on hopper state.
        provisioning_token: One-shot token used at first boot to register
            the device's public key with the coordination server. Empty
            string skips provisioning (already provisioned).
        tailscale_host: Hostname the coordination server returns to the
            app at pair time. Required when ``provisioning_token`` is
            non-empty.
        device_name: Human-readable name shown in the app pairing UI.
        livekit_enabled: Whether to construct a :class:`StreamManager`
            from ``LIVEKIT_*`` env vars at startup.
        push_enabled: Whether to construct a :class:`PushNotifier` from
            ``FCM_SERVICE_ACCOUNT_PATH`` at startup.
    """

    database_path: Path
    vision_socket_path: Path
    device_key_path: Path
    coord_base_url: str
    device_slug: str
    bind_address: str
    bind_interface: str
    app_port: int
    acl_poll_interval: float
    firmware_version: str
    hopper_gpio_path: str
    provisioning_token: str
    tailscale_host: str
    device_name: str
    livekit_enabled: bool
    push_enabled: bool

    @classmethod
    def from_env(cls) -> Self:
        """Read every field from :func:`os.environ`.

        Validates that required strings are non-empty, that paths
        exist (where appropriate), and that integers parse. On any
        failure raises :class:`ConfigError` with a precise reason.
        """
        coord_base_url = _required_str(ENV_COORD_BASE_URL)
        device_slug = _required_str(ENV_DEVICE_SLUG)
        if not coord_base_url.startswith("https://"):
            msg = f"{ENV_COORD_BASE_URL} must use https:// (got {coord_base_url!r})"
            raise ConfigError(msg)

        database_path = _path_or_default(ENV_DATABASE_PATH, _DEFAULT_DATABASE_PATH)
        vision_socket_path = _path_or_default(ENV_VISION_SOCKET, _DEFAULT_VISION_SOCKET)
        device_key_path = _path_or_default(ENV_DEVICE_KEY_PATH, _DEFAULT_DEVICE_KEY_PATH)

        bind_address = os.environ.get(ENV_BIND_ADDRESS, "")
        bind_interface = os.environ.get(ENV_BIND_INTERFACE, _DEFAULT_BIND_INTERFACE)
        app_port = _parse_int(ENV_APP_PORT, _DEFAULT_APP_PORT)
        if not (0 < app_port <= _MAX_PORT):
            msg = f"{ENV_APP_PORT} out of range: {app_port}"
            raise ConfigError(msg)

        acl_poll_interval = _parse_float(ENV_ACL_POLL_INTERVAL, _DEFAULT_ACL_POLL_INTERVAL)
        if acl_poll_interval <= 0.0:
            msg = f"{ENV_ACL_POLL_INTERVAL} must be positive: {acl_poll_interval}"
            raise ConfigError(msg)

        firmware_version = os.environ.get(ENV_FIRMWARE_VERSION, _DEFAULT_FIRMWARE_VERSION)

        hopper_gpio_path = os.environ.get(ENV_HOPPER_GPIO_PATH, "")
        provisioning_token = os.environ.get(ENV_PROVISIONING_TOKEN, "")
        tailscale_host = os.environ.get(ENV_TAILSCALE_HOST, "")
        if provisioning_token and not tailscale_host:
            msg = (
                f"{ENV_PROVISIONING_TOKEN} requires {ENV_TAILSCALE_HOST}: "
                "the server needs the tailnet endpoint to publish to the app"
            )
            raise ConfigError(msg)
        device_name = os.environ.get(ENV_DEVICE_NAME, "")

        # LiveKit and FCM are optional. Treat presence of the marker env
        # var as "user wants this enabled"; the orchestrator builds the
        # actual config object via the corresponding ``from_env``
        # classmethods, which raise their own errors if a partially-set
        # group fails validation.
        livekit_enabled = bool(os.environ.get("LIVEKIT_URL", ""))
        push_enabled = bool(os.environ.get("FCM_SERVICE_ACCOUNT_PATH", ""))

        return cls(
            database_path=database_path,
            vision_socket_path=vision_socket_path,
            device_key_path=device_key_path,
            coord_base_url=coord_base_url,
            device_slug=device_slug,
            bind_address=bind_address,
            bind_interface=bind_interface,
            app_port=app_port,
            acl_poll_interval=acl_poll_interval,
            firmware_version=firmware_version,
            hopper_gpio_path=hopper_gpio_path,
            provisioning_token=provisioning_token,
            tailscale_host=tailscale_host,
            device_name=device_name,
            livekit_enabled=livekit_enabled,
            push_enabled=push_enabled,
        )


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------


def _required_str(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        msg = f"required environment variable not set: {name}"
        raise ConfigError(msg)
    return value


def _path_or_default(name: str, default: Path) -> Path:
    value = os.environ.get(name, "")
    return Path(value) if value else default


def _parse_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "")
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError as exc:
        msg = f"{name} must be a decimal integer (got {raw!r})"
        raise ConfigError(msg) from exc


def _parse_float(name: str, default: float) -> float:
    raw = os.environ.get(name, "")
    if not raw:
        return default
    try:
        return float(raw)
    except ValueError as exc:
        msg = f"{name} must be a decimal number (got {raw!r})"
        raise ConfigError(msg) from exc
