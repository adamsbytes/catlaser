"""AuthRequest verification for the AppServer handshake.

The app sends an ``AuthRequest`` as the first TCP frame on every
connection. The frame carries a v4 ``x-device-attestation`` header
payload (base64-outer, JSON-inner) with a ``bnd`` field of
``"dev:<unix_seconds>"``. This module:

1. Parses that header.
2. Asserts the binding tag is ``dev:`` and the timestamp is within
   the ±60 s skew window.
3. Verifies the ECDSA P-256 signature over ``fph || bnd_utf8``
   using the public key embedded in the frame's ``pk`` field.
4. Checks the signer's SPKI against the :class:`AclStore` — if the
   user is not in the current authorization set, rejection.

Success returns the authorized SPKI so the caller can tag the
connection with it (for per-user quota, auditing, etc.). Failure
raises a structured :class:`HandshakeError` with a machine-readable
reason; the caller turns that into an ``AuthResponse`` proto and
closes the socket.
"""

from __future__ import annotations

import base64
import json
import time
from dataclasses import dataclass
from enum import StrEnum
from typing import Final, Protocol

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

# ---------------------------------------------------------------------------
# Constants — must match iOS `DeviceAttestationEncoder` / server plugin
# ---------------------------------------------------------------------------

ATTESTATION_VERSION: Final[int] = 4
FINGERPRINT_HASH_BYTES: Final[int] = 32
MAX_ATTESTATION_HEADER_BYTES: Final[int] = 2048
MAX_BINDING_WIRE_BYTES: Final[int] = 1024
DEV_BINDING_TAG: Final[str] = "dev:"
DEV_SKEW_SECONDS: Final[int] = 60

# P-256 SPKI prefix. The iOS app signs under a P-256 Secure-Enclave
# key; Python's `cryptography` accepts DER-encoded
# SubjectPublicKeyInfo via `load_der_public_key`. iOS transmits the
# raw DER SPKI in the attestation's `pk` field (91 bytes for
# well-formed P-256), so we can hand it straight to the loader.
# Asserting on the leading 26 bytes catches obvious wrong-key-type
# errors before hitting the verify path.
ECP256_SPKI_PREFIX: Final[bytes] = bytes.fromhex(
    "3059301306072a8648ce3d020106082a8648ce3d030107034200",
)


class HandshakeReason(StrEnum):
    """Machine-readable reason codes for every rejection path.

    Placed on the wire inside :class:`~catlaser.app.v1.AuthResponse`
    so the app can surface a specific remediation (re-pair, clock
    sync, retry) rather than a generic "authentication failed."
    """

    MALFORMED_HEADER = "DEVICE_AUTH_MALFORMED_HEADER"
    WRONG_VERSION = "DEVICE_AUTH_WRONG_VERSION"
    FINGERPRINT_LENGTH = "DEVICE_AUTH_FINGERPRINT_LENGTH"
    PUBLIC_KEY_INVALID = "DEVICE_AUTH_PUBLIC_KEY_INVALID"
    BINDING_MISMATCH = "DEVICE_AUTH_BINDING_MISMATCH"
    BINDING_MALFORMED = "DEVICE_AUTH_BINDING_MALFORMED"
    SKEW_EXCEEDED = "DEVICE_AUTH_SKEW_EXCEEDED"
    SIGNATURE_INVALID = "DEVICE_AUTH_SIGNATURE_INVALID"
    NOT_AUTHORIZED = "DEVICE_AUTH_NOT_AUTHORIZED"
    ACL_NOT_READY = "DEVICE_AUTH_ACL_NOT_READY"
    # A previously-accepted ``(spki, timestamp)`` tuple is being
    # presented again within the replay-cache TTL. A legitimate client
    # would never re-sign with the same wall-clock second; the cause
    # is an on-path attacker resending the captured bytes. The iOS
    # :class:`DeviceClientError` treats this as non-terminal: the
    # connection manager's next reconnect signs a fresh attestation
    # with a new timestamp and proceeds.
    REPLAY_DETECTED = "DEVICE_AUTH_REPLAY_DETECTED"


class HandshakeError(Exception):
    """Rejection raised by :func:`verify_auth_request`.

    ``reason`` is the machine-readable code placed on the wire in
    the AuthResponse; ``detail`` is a human-oriented message for
    server-side logs only (not echoed back to the app — the reason
    code alone is the client contract).
    """

    def __init__(self, reason: HandshakeReason, detail: str) -> None:
        super().__init__(f"{reason.value}: {detail}")
        self.reason = reason
        self.detail = detail


@dataclass(frozen=True, slots=True)
class AuthorizedIdentity:
    """Returned on a successful handshake.

    Attributes:
        user_spki_b64: Standard-base64 encoding of the signer's DER
            SPKI, byte-identical to what the coordination server
            stored in ``session_attestation.public_key_spki`` and
            republished on the device's ACL. Safe to use as a
            per-user key in downstream structures.
        timestamp: The unix-seconds value from the ``dev:`` binding.
            Exposed so audit logs can record the moment the client
            claimed for this connection.
    """

    user_spki_b64: str
    timestamp: int


class _AuthorizationSource(Protocol):
    """Narrow protocol for the ACL store.

    The handshake only needs two operations, so we type against the
    minimal surface rather than the concrete :class:`AclStore` —
    that makes unit testing trivial (pass a small in-memory stub)
    and keeps the handshake module from depending on the full ACL
    polling machinery.
    """

    @property
    def is_primed(self) -> bool: ...
    def is_authorized(self, user_spki_b64: str) -> bool: ...


class _ReplayTracker(Protocol):
    """Narrow protocol for the replay cache.

    Same shape as :class:`~catlaser_brain.auth.replay_cache.ReplayCache`
    but typed as a protocol so the handshake module does not depend on
    the concrete class — tests pass a trivial stub when they want to
    assert interaction order without materialising a real cache.
    """

    def check_and_consume(
        self,
        spki_b64: str,
        timestamp: int,
        signature: bytes,
        *,
        now_seconds: int | None = None,
    ) -> bool: ...


def verify_auth_request(
    attestation_header: str,
    acl: _AuthorizationSource,
    replay_cache: _ReplayTracker,
    *,
    now_seconds: int | None = None,
) -> AuthorizedIdentity:
    """Verify the AuthRequest's attestation header against the ACL.

    Runs in order of increasing cost: structural checks first,
    signature verify next, ACL lookup, and finally replay detection.
    A malformed header never touches the crypto primitives; a
    well-formed-but-unauthorized-spki never touches the signature
    verifier; and only tuples that passed both signature verify and
    the ACL lookup ever land in the replay cache — an attacker cannot
    pollute the cache by flooding fake headers, because their fake
    sig + unknown spki would never clear the earlier checks.

    Args:
        attestation_header: Base64-of-JSON v4 payload with the
            ``dev:<unix_seconds>`` binding, exactly as emitted by the
            iOS :class:`DeviceAttestationEncoder`.
        acl: Authorization source consulted after signature verify.
        replay_cache: Consumed-once store keyed on
            ``(spki_b64, timestamp)``. A successful verify consumes
            one entry; a resent header whose tuple is still within
            the cache's TTL window raises with
            :attr:`HandshakeReason.REPLAY_DETECTED`.
        now_seconds: Override for tests. Production callers omit; the
            override is threaded into both the skew check and the
            replay cache so they share a single clock reading.

    Raises:
        HandshakeError: every rejection path wraps its specific
            :class:`HandshakeReason`. The caller maps this onto an
            AuthResponse and closes the socket.
    """
    if not acl.is_primed:
        # Fail-closed: a daemon that hasn't completed its first ACL
        # poll has no idea who to trust. Rejecting with a distinct
        # code lets the app retry gracefully rather than treating
        # this as a re-pair signal.
        raise HandshakeError(
            HandshakeReason.ACL_NOT_READY,
            "device has not completed its first ACL poll",
        )
    payload = _parse_header(attestation_header)
    _assert_version(payload)
    fph = _decode_fph(payload)
    pk_der = _decode_pk(payload)
    binding = _require_str(payload, "bnd")
    _assert_binding_tag(binding)
    timestamp = _parse_dev_timestamp(binding)
    _enforce_skew(timestamp, now_seconds)
    signature = _decode_sig(payload)
    user_spki_b64 = base64.b64encode(pk_der).decode("ascii")
    _verify_signature(pk_der, fph, binding, signature)
    if not acl.is_authorized(user_spki_b64):
        raise HandshakeError(
            HandshakeReason.NOT_AUTHORIZED,
            "signer's SPKI is not in the device ACL",
        )
    # Replay detection runs LAST so only cryptographically-verified,
    # ACL-authorized tuples ever enter the cache. The check is
    # atomic: a concurrent handshake thread attempting the same
    # replay must not observe an intermediate state where both pass.
    # The signature is part of the key because ECDSA-P256's random k
    # makes it unique per legitimate signing op; an attacker replaying
    # captured bytes cannot refresh it without the SE private key.
    if not replay_cache.check_and_consume(
        user_spki_b64,
        timestamp,
        signature,
        now_seconds=now_seconds,
    ):
        raise HandshakeError(
            HandshakeReason.REPLAY_DETECTED,
            f"(spki, ts={timestamp}) already consumed within replay TTL",
        )
    return AuthorizedIdentity(user_spki_b64=user_spki_b64, timestamp=timestamp)


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------


def _parse_header(attestation_header: str) -> dict[str, object]:
    if len(attestation_header.encode("utf-8")) > MAX_ATTESTATION_HEADER_BYTES:
        raise HandshakeError(
            HandshakeReason.MALFORMED_HEADER,
            f"attestation header exceeds {MAX_ATTESTATION_HEADER_BYTES} bytes",
        )
    try:
        outer = base64.b64decode(attestation_header, validate=True)
    except (ValueError, base64.binascii.Error) as exc:  # type: ignore[attr-defined]
        raise HandshakeError(
            HandshakeReason.MALFORMED_HEADER,
            f"outer base64 decode failed: {exc}",
        ) from exc
    try:
        parsed: object = json.loads(outer)
    except json.JSONDecodeError as exc:
        raise HandshakeError(
            HandshakeReason.MALFORMED_HEADER,
            f"payload JSON decode failed: {exc}",
        ) from exc
    if not isinstance(parsed, dict):
        raise HandshakeError(
            HandshakeReason.MALFORMED_HEADER,
            "payload is not a JSON object",
        )
    # Re-type the validated `dict[Any, Any]` from `json.loads` into
    # `dict[str, object]`. Iterating `parsed` gives keys typed as
    # `Unknown` under strict pyright — the `typing.cast` widens
    # explicitly so downstream helpers can narrow per-field.
    from typing import cast  # noqa: PLC0415 — local import for the cast

    as_raw = cast("dict[object, object]", parsed)
    return {str(key): value for key, value in as_raw.items()}


def _assert_version(payload: dict[str, object]) -> None:
    version = payload.get("v")
    if version != ATTESTATION_VERSION:
        raise HandshakeError(
            HandshakeReason.WRONG_VERSION,
            f"expected v={ATTESTATION_VERSION}, got {version!r}",
        )


def _decode_fph(payload: dict[str, object]) -> bytes:
    fph_b64url = _require_str(payload, "fph")
    # iOS emits base64url-no-pad; add padding for stdlib decoder.
    padded = fph_b64url + "=" * (-len(fph_b64url) % 4)
    try:
        fph = base64.urlsafe_b64decode(padded)
    except (ValueError, base64.binascii.Error) as exc:  # type: ignore[attr-defined]
        raise HandshakeError(
            HandshakeReason.MALFORMED_HEADER,
            f"fph base64url decode failed: {exc}",
        ) from exc
    if len(fph) != FINGERPRINT_HASH_BYTES:
        raise HandshakeError(
            HandshakeReason.FINGERPRINT_LENGTH,
            f"fph must be {FINGERPRINT_HASH_BYTES} bytes, got {len(fph)}",
        )
    return fph


def _decode_pk(payload: dict[str, object]) -> bytes:
    pk_b64 = _require_str(payload, "pk")
    try:
        pk = base64.b64decode(pk_b64, validate=True)
    except (ValueError, base64.binascii.Error) as exc:  # type: ignore[attr-defined]
        raise HandshakeError(
            HandshakeReason.PUBLIC_KEY_INVALID,
            f"pk base64 decode failed: {exc}",
        ) from exc
    if len(pk) < len(ECP256_SPKI_PREFIX) or not pk.startswith(ECP256_SPKI_PREFIX):
        raise HandshakeError(
            HandshakeReason.PUBLIC_KEY_INVALID,
            "pk is not a well-formed P-256 SubjectPublicKeyInfo",
        )
    return pk


def _decode_sig(payload: dict[str, object]) -> bytes:
    sig_b64 = _require_str(payload, "sig")
    try:
        sig = base64.b64decode(sig_b64, validate=True)
    except (ValueError, base64.binascii.Error) as exc:  # type: ignore[attr-defined]
        raise HandshakeError(
            HandshakeReason.MALFORMED_HEADER,
            f"sig base64 decode failed: {exc}",
        ) from exc
    if len(sig) == 0:
        raise HandshakeError(
            HandshakeReason.MALFORMED_HEADER,
            "sig is empty",
        )
    return sig


def _assert_binding_tag(binding: str) -> None:
    if len(binding.encode("utf-8")) > MAX_BINDING_WIRE_BYTES:
        raise HandshakeError(
            HandshakeReason.BINDING_MALFORMED,
            f"bnd exceeds {MAX_BINDING_WIRE_BYTES} bytes",
        )
    if not binding.startswith(DEV_BINDING_TAG):
        raise HandshakeError(
            HandshakeReason.BINDING_MISMATCH,
            f"expected 'dev:' binding, got {binding!r}",
        )


def _parse_dev_timestamp(binding: str) -> int:
    suffix = binding[len(DEV_BINDING_TAG) :]
    if not suffix or not suffix.isdigit():
        raise HandshakeError(
            HandshakeReason.BINDING_MALFORMED,
            "bnd timestamp is not a decimal integer",
        )
    try:
        value = int(suffix)
    except ValueError as exc:
        raise HandshakeError(
            HandshakeReason.BINDING_MALFORMED,
            f"bnd timestamp parse failed: {exc}",
        ) from exc
    if value <= 0:
        raise HandshakeError(
            HandshakeReason.BINDING_MALFORMED,
            "bnd timestamp must be positive",
        )
    return value


def _enforce_skew(timestamp: int, now_seconds: int | None) -> None:
    now = int(time.time()) if now_seconds is None else now_seconds
    if abs(now - timestamp) > DEV_SKEW_SECONDS:
        raise HandshakeError(
            HandshakeReason.SKEW_EXCEEDED,
            f"timestamp {timestamp} outside ±{DEV_SKEW_SECONDS}s skew window",
        )


def _verify_signature(pk_der: bytes, fph: bytes, binding: str, signature: bytes) -> None:
    try:
        public_key = serialization.load_der_public_key(pk_der)
    except (ValueError, TypeError) as exc:
        raise HandshakeError(
            HandshakeReason.PUBLIC_KEY_INVALID,
            f"pk does not parse as a public key: {exc}",
        ) from exc
    if not isinstance(public_key, ec.EllipticCurvePublicKey):
        raise HandshakeError(
            HandshakeReason.PUBLIC_KEY_INVALID,
            f"pk is not an EC public key (got {type(public_key).__name__})",
        )
    curve = public_key.curve
    if not isinstance(curve, ec.SECP256R1):
        raise HandshakeError(
            HandshakeReason.PUBLIC_KEY_INVALID,
            f"pk curve is not P-256 (got {curve.name})",
        )
    signed_bytes = fph + binding.encode("utf-8")
    try:
        public_key.verify(signature, signed_bytes, ec.ECDSA(hashes.SHA256()))
    except InvalidSignature as exc:
        raise HandshakeError(
            HandshakeReason.SIGNATURE_INVALID,
            "ECDSA verify failed",
        ) from exc


def _require_str(body: dict[str, object], key: str) -> str:
    value = body.get(key)
    if not isinstance(value, str) or len(value) == 0:
        raise HandshakeError(
            HandshakeReason.MALFORMED_HEADER,
            f"payload field '{key}' missing or not a non-empty string",
        )
    return value
