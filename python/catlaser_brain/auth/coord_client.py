r"""HTTPS client for the coordination server's device-facing routes.

Owns two concerns:

1. Attaching the three device-attestation headers
   (``x-device-id``, ``x-device-timestamp``, ``x-device-signature``)
   on every outbound call. The signed bytes are
   ``"dvc:" || METHOD || "\n" || pathname || "\n" || timestamp``,
   matching the server's :mod:`server/src/lib/device-attestation.ts`
   verifier byte-for-byte.
2. Parsing the three call responses this module needs:
   :meth:`provision` (one-shot), :meth:`issue_pairing_code`, and
   :meth:`fetch_acl`.

The client stays intentionally thin — no retry policy, no backoff,
no circuit breaker. The caller (the ACL poll loop, the
pairing-code renderer) owns the retry cadence because the right
behaviour is task-specific: the ACL poll can tolerate a minute of
staleness, a pair-refresh QR cannot. Pushing retry policy into the
HTTP client would make every caller wrong in at least one
direction.
"""

from __future__ import annotations

import base64
import json
import time
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any, Final, Self

import httpx

if TYPE_CHECKING:
    from catlaser_brain.auth.identity import DeviceIdentity

DEVICE_ID_HEADER: Final[str] = "x-device-id"
DEVICE_TIMESTAMP_HEADER: Final[str] = "x-device-timestamp"
DEVICE_SIGNATURE_HEADER: Final[str] = "x-device-signature"
PROVISIONING_TOKEN_HEADER: Final[str] = "x-provisioning-token"  # noqa: S105 — header name, not a secret

DEFAULT_TIMEOUT_SECONDS: Final[float] = 10.0
"""Per-request timeout. The coordination server is fronted by
Cloudflare Tunnel; a request that takes longer than ten seconds to
return a response is either the tunnel being unavailable or the DB
being badly overloaded. In either case, failing fast and letting the
caller drive the retry cadence is better than a blocking call that
stalls the daemon's main loop."""


class CoordClientError(RuntimeError):
    """Base class for every coord-client failure surface."""


class CoordAuthError(CoordClientError):
    """HTTP 401/403 from the server.

    The device's attestation was rejected. Any caller must treat
    this as a provisioning regression, not a transient condition.
    """


class CoordHTTPError(CoordClientError):
    """Any other non-2xx response. The caller decides retryability."""

    def __init__(self, status: int, message: str) -> None:
        super().__init__(f"HTTP {status}: {message}")
        self.status = status


@dataclass(frozen=True, slots=True)
class IssuedPairingCode:
    """Response payload from ``POST /api/v1/devices/<slug>/pairing-code``."""

    code: str
    device_id: str
    expires_at_iso: str


@dataclass(frozen=True, slots=True)
class AclGrant:
    """One entry in the ACL response."""

    user_spki_b64: str
    revision: int
    granted_at_iso: str


@dataclass(frozen=True, slots=True)
class AclSnapshot:
    """Full ACL response for a given device slug."""

    device_id: str
    revision: int
    grants: tuple[AclGrant, ...]


class CoordClient:
    """Synchronous HTTPS client for the coordination server.

    ``base_url`` is the server root (e.g. ``https://api.catlaser.example``).
    ``identity`` is the device's loaded Ed25519 keypair. ``slug`` is
    the device's on-the-wire identifier used in the URL path and in
    the ``x-device-id`` header.

    The client owns an :class:`httpx.Client` for connection reuse;
    :meth:`close` must be called at daemon shutdown to release the
    connection pool cleanly.
    """

    def __init__(
        self,
        base_url: str,
        identity: DeviceIdentity,
        slug: str,
        *,
        timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._identity = identity
        self._slug = slug
        # `verify=True` is the default but making it explicit
        # documents the intent — this client MUST NOT run against an
        # unverified TLS chain. A misconfigured production deploy
        # that flipped this to False would be a silent downgrade.
        client_kwargs: dict[str, Any] = {
            "base_url": self._base_url,
            "timeout": timeout_seconds,
            "verify": True,
        }
        if transport is not None:
            client_kwargs["transport"] = transport
        self._http = httpx.Client(**client_kwargs)

    def close(self) -> None:
        """Release the underlying HTTP connection pool."""
        self._http.close()

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def _signed_bytes(self, method: str, pathname: str, timestamp: int) -> bytes:
        body = f"dvc:{method.upper()}\n{pathname}\n{timestamp}"
        return body.encode("utf-8")

    def _attestation_headers(self, method: str, pathname: str) -> dict[str, str]:
        timestamp = int(time.time())
        signed = self._signed_bytes(method, pathname, timestamp)
        signature = self._identity.sign(signed)
        return {
            DEVICE_ID_HEADER: self._slug,
            DEVICE_TIMESTAMP_HEADER: str(timestamp),
            DEVICE_SIGNATURE_HEADER: base64.b64encode(signature).decode("ascii"),
        }

    def provision(
        self,
        provisioning_token: str,
        tailscale_host: str,
        tailscale_port: int,
        device_name: str | None = None,
    ) -> bool:
        """Register this device with the coordination server.

        Called once on first boot, and idempotently on every
        subsequent boot where the device's registration needs to be
        refreshed (e.g. after a tailnet IP change or a re-provisioning
        cycle). The server matches on slug and updates the stored
        Ed25519 public key — this is the only path by which a key
        rotation reaches the server.

        Authenticated by ``PROVISIONING_TOKEN``, NOT by
        device-attestation — the call publishes the public key that
        subsequent attestations will be verified against.

        Returns:
            True if the server reports a fresh registration (HTTP
            201), False if an existing registration was updated
            (HTTP 200). Either outcome is success from the caller's
            perspective.
        """
        payload: dict[str, Any] = {
            "device_id": self._slug,
            "public_key_ed25519": self._identity.public_key_b64url,
            "tailscale_host": tailscale_host,
            "tailscale_port": tailscale_port,
        }
        if device_name is not None:
            payload["device_name"] = device_name
        response = self._http.post(
            "/api/v1/devices/provision",
            content=json.dumps(payload).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                PROVISIONING_TOKEN_HEADER: provisioning_token,
            },
        )
        return self._parse_bool_created(response)

    def _parse_bool_created(self, response: httpx.Response) -> bool:
        if response.status_code in (401, 403):
            msg = f"provisioning rejected: status {response.status_code}"
            raise CoordAuthError(msg)
        if response.status_code not in (200, 201):
            raise CoordHTTPError(response.status_code, response.text[:512])
        body = response.json()
        return bool(body.get("data", {}).get("created", False))

    def issue_pairing_code(self) -> IssuedPairingCode:
        """Request a fresh pairing code for this device.

        Server mints a 160-bit opaque secret, stores the hash, and
        returns the plaintext to this (attested) caller. The device
        renders the plaintext into the QR shown to the user for the
        duration of ``expires_at``.
        """
        path = f"/api/v1/devices/{self._slug}/pairing-code"
        response = self._http.post(
            path,
            headers=self._attestation_headers("POST", path),
        )
        self._assert_ok(response)
        data = response.json().get("data", {})
        return IssuedPairingCode(
            code=_require_str(data, "code"),
            device_id=_require_str(data, "device_id"),
            expires_at_iso=_require_str(data, "expires_at"),
        )

    def fetch_acl(self) -> AclSnapshot:
        """Pull the current ACL for this device.

        Called periodically by the ACL poll loop. Every grant in the
        response is active as of the server's read; any user SPKI
        that appeared in a previous snapshot but not this one has
        been revoked (or the grant is a compaction artifact the
        server cleaned up). The caller is responsible for comparing
        snapshots and reacting to change.
        """
        path = f"/api/v1/devices/{self._slug}/acl"
        response = self._http.get(
            path,
            headers=self._attestation_headers("GET", path),
        )
        self._assert_ok(response)
        data = response.json().get("data", {})
        raw_grants: list[dict[str, Any]] = list(data.get("grants", []))
        grants = tuple(
            AclGrant(
                user_spki_b64=_require_str(grant, "user_spki_b64"),
                revision=int(grant["revision"]),
                granted_at_iso=_require_str(grant, "granted_at"),
            )
            for grant in raw_grants
        )
        return AclSnapshot(
            device_id=_require_str(data, "device_id"),
            revision=int(data["revision"]),
            grants=grants,
        )

    _CLIENT_ERROR_MIN_STATUS: Final[int] = 400

    def _assert_ok(self, response: httpx.Response) -> None:
        if response.status_code in (401, 403):
            msg = f"device-attested call rejected: status {response.status_code}"
            raise CoordAuthError(msg)
        if response.status_code >= self._CLIENT_ERROR_MIN_STATUS:
            raise CoordHTTPError(response.status_code, response.text[:512])


def _require_str(body: dict[str, Any], key: str) -> str:
    value = body.get(key)
    if not isinstance(value, str) or len(value) == 0:
        msg = f"response body missing required string field '{key}'"
        raise CoordHTTPError(200, msg)
    return value
