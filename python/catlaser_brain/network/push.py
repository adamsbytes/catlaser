"""Push notifications via Firebase Cloud Messaging HTTP v1 API.

Sends push notifications to registered mobile apps for play session
summaries, session start alerts, hopper-empty reminders, and new-cat
detections. Both iOS (via APNs routing through FCM) and Android apps
register FCM tokens with the device; this module sends to all registered
tokens when notification-worthy events occur.

All send operations are best-effort: failures are logged but never
raised. The primary notification path is the data channel broadcast
via :class:`~catlaser_brain.network.server.AppServer`; push
notifications supplement that for backgrounded/disconnected apps.

Configuration is read from environment variables:
    ``FCM_SERVICE_ACCOUNT_PATH`` -- path to the Firebase service account
    JSON file. The file must contain a ``project_id`` field.
"""

from __future__ import annotations

import dataclasses
import json
import logging
import os
import urllib.error
import urllib.request
from pathlib import Path
from typing import TYPE_CHECKING, Any, Final

from google.auth.exceptions import GoogleAuthError
from google.oauth2 import service_account

from catlaser_brain.storage.crud import list_push_tokens, unregister_push_token

if TYPE_CHECKING:
    import sqlite3

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_FCM_MESSAGING_SCOPE: Final[str] = "https://www.googleapis.com/auth/firebase.messaging"
"""OAuth2 scope required for the FCM v1 send API."""

_FCM_SEND_URL: Final[str] = "https://fcm.googleapis.com/v1/projects/{project_id}/messages:send"
"""FCM v1 API endpoint template. ``project_id`` is interpolated from the
service account JSON at construction time.
"""

_SEND_TIMEOUT_SEC: Final[int] = 10
"""HTTP timeout per FCM API call in seconds."""


# ---------------------------------------------------------------------------
# Stdlib HTTP transport for google-auth token refresh
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True, slots=True)
class _HttpResponse:
    """Minimal HTTP response satisfying ``google.auth.transport.Response``."""

    status: int
    headers: dict[str, str]
    data: bytes


class _UrllibTransport:
    """``google.auth.transport.Request`` implementation using stdlib.

    Avoids pulling in ``requests`` or ``urllib3`` as dependencies.
    Used only for OAuth2 token exchange with Google's token endpoint
    (``https://oauth2.googleapis.com/token``).
    """

    def __call__(
        self,
        url: str,
        method: str = "GET",
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
        timeout: int | None = None,
        **_kwargs: object,
    ) -> _HttpResponse:
        """Execute an HTTP request and return the response."""
        req = urllib.request.Request(  # noqa: S310
            url,
            data=body,
            headers=headers or {},
            method=method,
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
                return _HttpResponse(resp.status, dict(resp.headers), resp.read())
        except urllib.error.HTTPError as e:
            return _HttpResponse(e.code, dict(e.headers), e.read())


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True, slots=True)
class PushConfig:
    """FCM push notification configuration.

    Read from a Firebase service account JSON file whose path is
    specified by the ``FCM_SERVICE_ACCOUNT_PATH`` environment variable.

    Attributes:
        project_id: Firebase project ID (from the service account JSON).
        service_account_path: Filesystem path to the service account JSON.
    """

    project_id: str
    service_account_path: str

    @classmethod
    def from_env(cls) -> PushConfig:
        """Construct from ``FCM_SERVICE_ACCOUNT_PATH``.

        Validates that the file exists, is valid JSON, and contains
        a ``project_id`` field.

        Raises:
            ValueError: If the env var is missing/empty or the JSON
                lacks ``project_id``.
            FileNotFoundError: If the service account file does not exist.
        """
        path = os.environ.get("FCM_SERVICE_ACCOUNT_PATH", "")
        if not path:
            msg = "missing required environment variable: FCM_SERVICE_ACCOUNT_PATH"
            raise ValueError(msg)

        with Path(path).open() as f:
            sa_info: dict[str, Any] = json.load(f)

        project_id: str = sa_info.get("project_id", "")
        if not project_id:
            msg = f"service account JSON at {path} missing 'project_id' field"
            raise ValueError(msg)

        return cls(project_id=project_id, service_account_path=path)


# ---------------------------------------------------------------------------
# FCM message builder (pure function)
# ---------------------------------------------------------------------------


def build_fcm_message(
    token: str,
    platform: str,
    notification: dict[str, str],
    data: dict[str, str],
) -> dict[str, Any]:
    """Build a complete FCM v1 API message payload.

    Adds platform-specific overrides for notification sound routing.

    Args:
        token: FCM device registration token.
        platform: ``'fcm'`` or ``'apns'``.
        notification: Display notification with ``title`` and ``body``.
        data: String key-value payload for the app to process.

    Returns:
        Complete ``{"message": {...}}`` dict ready for JSON serialization.
    """
    msg: dict[str, Any] = {
        "token": token,
        "notification": notification,
        "data": data,
    }
    if platform == "apns":
        msg["apns"] = {"payload": {"aps": {"sound": "default"}}}
    elif platform == "fcm":
        msg["android"] = {"notification": {"sound": "default"}}
    return {"message": msg}


# ---------------------------------------------------------------------------
# Credential loading
# ---------------------------------------------------------------------------


def _load_credentials(path: str) -> service_account.Credentials:
    """Load FCM service account credentials from a JSON file.

    Scoped to the Firebase Cloud Messaging send permission.
    """
    return service_account.Credentials.from_service_account_file(  # pyright: ignore[reportUnknownMemberType]
        path,
        scopes=[_FCM_MESSAGING_SCOPE],
    )


# ---------------------------------------------------------------------------
# Push notifier
# ---------------------------------------------------------------------------


class PushNotifier:
    """Sends push notifications to all registered FCM tokens.

    Manages OAuth2 credentials for the FCM HTTP v1 API and sends
    notifications for session summaries, session starts, hopper-empty
    alerts, and new-cat detections.

    Invalid tokens (HTTP 404/410 from FCM) are automatically pruned
    from the database.

    Args:
        config: FCM configuration with project ID and service account path.
        conn: SQLite connection for reading/pruning push tokens.
    """

    __slots__ = ("_conn", "_credentials", "_transport", "_url")

    def __init__(self, config: PushConfig, conn: sqlite3.Connection) -> None:
        self._conn = conn
        self._credentials = _load_credentials(config.service_account_path)
        self._transport = _UrllibTransport()
        self._url = _FCM_SEND_URL.format(project_id=config.project_id)

    # -------------------------------------------------------------------
    # Public notification methods
    # -------------------------------------------------------------------

    def notify_session_summary(
        self,
        cat_names: list[str],
        duration_sec: int,
        engagement_score: float,
        treats_dispensed: int,
        pounce_count: int,
    ) -> None:
        """Push a play session summary to all registered devices.

        Args:
            cat_names: Display names of cats in the session.
            duration_sec: Total session duration in seconds.
            engagement_score: Engagement score (0.0--1.0).
            treats_dispensed: Number of treats given.
            pounce_count: Number of pounces detected.
        """
        cats = ", ".join(cat_names) if cat_names else "Your cat"
        minutes = duration_sec // 60
        seconds = duration_sec % 60
        time_str = f"{minutes}m{seconds}s" if minutes else f"{seconds}s"
        body = f"{cats} played for {time_str}. {treats_dispensed} treats dispensed."

        notification = {"title": "Play Session Complete", "body": body}
        data = {
            "type": "session_summary",
            "cat_names": ",".join(cat_names),
            "duration_sec": str(duration_sec),
            "engagement_score": f"{engagement_score:.2f}",
            "treats_dispensed": str(treats_dispensed),
            "pounce_count": str(pounce_count),
        }
        self._send_to_all(notification, data)

    def notify_session_started(
        self,
        cat_names: list[str],
        trigger: str,
    ) -> None:
        """Push a live session alert to all registered devices.

        Args:
            cat_names: Display names of cats in the session.
            trigger: How the session was initiated
                (``'scheduled'``, ``'cat_detected'``, or ``'manual'``).
        """
        cats = ", ".join(cat_names) if cat_names else "A cat"
        body = f"{cats} is playing! Open the app to watch live."

        notification = {"title": "Play Session Active", "body": body}
        data = {
            "type": "session_started",
            "cat_names": ",".join(cat_names),
            "trigger": trigger,
        }
        self._send_to_all(notification, data)

    def notify_hopper_empty(self) -> None:
        """Push a hopper-empty alert to all registered devices."""
        notification = {
            "title": "Hopper Empty",
            "body": "Time to refill the treat hopper. Auto-play is paused.",
        }
        data: dict[str, str] = {"type": "hopper_empty"}
        self._send_to_all(notification, data)

    def notify_new_cat_detected(
        self,
        track_id_hint: int,
        confidence: float,
    ) -> None:
        """Push a new-cat-detected alert to all registered devices.

        The thumbnail is not included in the push payload (FCM size
        limits). The app fetches it via the data channel when opened.

        Args:
            track_id_hint: SORT tracker ID for the detected cat.
            confidence: Embedding model confidence score.
        """
        notification = {
            "title": "New Cat Spotted",
            "body": "An unknown cat was detected. Open the app to name it.",
        }
        data = {
            "type": "new_cat_detected",
            "track_id_hint": str(track_id_hint),
            "confidence": f"{confidence:.2f}",
        }
        self._send_to_all(notification, data)

    # -------------------------------------------------------------------
    # Internal: token management
    # -------------------------------------------------------------------

    def _get_access_token(self) -> str | None:
        """Return a valid OAuth2 access token, refreshing if expired.

        Returns:
            The access token string, or ``None`` if refresh failed.
        """
        if not self._credentials.valid:
            try:
                self._credentials.refresh(self._transport)  # pyright: ignore[reportUnknownMemberType]
            except GoogleAuthError:
                logger.warning(
                    "failed to refresh FCM access token",
                    exc_info=True,
                )
                return None
        token: str | None = self._credentials.token  # pyright: ignore[reportUnknownMemberType, reportUnknownVariableType]
        return token  # pyright: ignore[reportUnknownVariableType]

    # -------------------------------------------------------------------
    # Internal: send logic
    # -------------------------------------------------------------------

    def _send_to_all(
        self,
        notification: dict[str, str],
        data: dict[str, str],
    ) -> None:
        """Build and send an FCM message to every registered token.

        Prunes tokens that FCM reports as unregistered (HTTP 404/410).
        """
        tokens = list_push_tokens(self._conn)
        if not tokens:
            return

        access_token = self._get_access_token()
        if access_token is None:
            return

        for token_row in tokens:
            message = build_fcm_message(
                token_row.token,
                token_row.platform,
                notification,
                data,
            )
            status = self._send_one(access_token, message)
            if status in (404, 410):
                unregister_push_token(self._conn, token_row.token)
                logger.info(
                    "pruned unregistered push token %.10s...",
                    token_row.token,
                )

    def _send_one(self, access_token: str, message: dict[str, Any]) -> int:
        """POST a single FCM message.

        Returns:
            HTTP status code on response, ``0`` on network error.
        """
        body = json.dumps(message).encode()
        req = urllib.request.Request(  # noqa: S310
            self._url,
            data=body,
            headers={
                "Authorization": f"Bearer {access_token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=_SEND_TIMEOUT_SEC) as resp:  # noqa: S310
                return int(resp.status)
        except urllib.error.HTTPError as e:
            fcm_token = message.get("message", {}).get("token", "?")
            logger.warning(
                "FCM send failed: HTTP %d for token %.10s...",
                e.code,
                fcm_token,
            )
            return int(e.code)
        except urllib.error.URLError:
            logger.warning("FCM send failed: network error", exc_info=True)
            return 0
