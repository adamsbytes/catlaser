"""Device-side Ed25519 identity.

Every Catlaser holds an Ed25519 keypair generated on first boot. The
public key is uploaded to the coordination server via the one-shot
``/api/v1/devices/provision`` call; the private key never leaves the
device filesystem. Every subsequent device-to-server call is
authenticated by signing a canonical message string with this key
(see :mod:`~catlaser_brain.auth.coord_client`).

Key file layout:

* Path: ``/var/lib/catlaser/device.key`` (override via the
  ``device_key_path`` arg for tests).
* Mode: ``0o600`` — owner read/write only. The file is created with
  this mode and the mode is re-asserted on every load to catch a
  filesystem that fell back to a permissive default.
* Format: PKCS#8 PEM — ``cryptography``'s canonical private-key
  encoding. No password; the disk-level permission is the
  confidentiality boundary.

A device that cannot read or write its key file cannot register with
the coordination server — every caller of this module surfaces that as
a fail-fast error so the init system supervises the daemon into a
restart loop rather than letting it run half-authenticated.
"""

from __future__ import annotations

import os
import stat
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Final

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)

DEFAULT_DEVICE_KEY_PATH: Final[Path] = Path("/var/lib/catlaser/device.key")
"""Production location of the device private-key file."""

_KEY_FILE_MODE: Final[int] = 0o600
_KEY_DIR_MODE: Final[int] = 0o700


def _base64url_nopad(raw: bytes) -> str:
    """Encode bytes as base64url without padding. Matches the server."""
    import base64  # noqa: PLC0415 — stdlib import kept local for a pure helper.

    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


@dataclass(frozen=True, slots=True)
class DeviceIdentity:
    """Device-side Ed25519 keypair in memory.

    Attributes:
        private_key: ``cryptography`` private-key handle. Use
            :meth:`sign` rather than accessing directly.
        public_key_raw: 32-byte raw Ed25519 public key.
        public_key_b64url: ``base64url`` (no padding) encoding of the
            raw public key. Matches the shape the server's
            ``device.public_key_ed25519`` column stores.
    """

    private_key: Ed25519PrivateKey
    public_key_raw: bytes
    public_key_b64url: str

    def sign(self, message: bytes) -> bytes:
        """Sign ``message`` with the device's Ed25519 key."""
        return self.private_key.sign(message)

    @classmethod
    def from_private_key(cls, private_key: Ed25519PrivateKey) -> DeviceIdentity:
        """Build an in-memory :class:`DeviceIdentity` from a private key.

        Callers that already hold an :class:`Ed25519PrivateKey` — fresh
        from :meth:`Ed25519PrivateKey.generate` in a test, or loaded
        from a bespoke storage path — bypass the on-disk
        :class:`DeviceIdentityStore` entirely. Production code goes
        through :class:`DeviceIdentityStore.load_or_create` so the
        file-mode + atomic-write invariants hold; this classmethod
        exists for tests and for coord-client integration code that
        receives a key through other means.
        """
        return _identity_from_private(private_key)


class DeviceIdentityStore:
    """Load or generate the device's Ed25519 keypair on disk.

    First call to :meth:`load_or_create` reads the PKCS#8 PEM at
    ``device_key_path``. If the file doesn't exist, a fresh Ed25519
    keypair is generated and written atomically. Subsequent calls
    within the process return a cached handle — key generation is
    expensive, loading from disk is cheap but still worth caching for
    predictable latency on ACL-poll-heavy paths.

    Thread-safe: the internal cache is guarded by a lock. The daemon
    only has one caller today (the main event loop), but the coord
    client and the AppServer share this store, and a future
    multi-threaded service shouldn't race on key generation.
    """

    def __init__(self, device_key_path: Path = DEFAULT_DEVICE_KEY_PATH) -> None:
        self._path = device_key_path
        self._lock = threading.Lock()
        self._cached: DeviceIdentity | None = None

    @property
    def path(self) -> Path:
        """Path to the on-disk key file (read-only public view)."""
        return self._path

    def load_or_create(self) -> DeviceIdentity:
        """Return the device identity, loading from disk or creating.

        If the key file doesn't exist, a fresh Ed25519 keypair is
        generated and persisted. If it exists, it's loaded. Either
        way, the file permissions are normalized to ``0o600`` and the
        in-memory handle is cached for subsequent calls.

        Raises:
            OSError: the key file exists but is unreadable, or the
                parent directory cannot be created, or the written
                file cannot be mode-restricted. Every such failure
                is fatal — the daemon must be unable to reach the
                coordination server without a stable identity.
            ValueError: the file exists but does not decode as a
                well-formed PKCS#8 Ed25519 private key.
        """
        with self._lock:
            if self._cached is not None:
                return self._cached
            if self._path.exists():
                identity = self._load_existing()
            else:
                identity = self._generate_and_persist()
            self._cached = identity
            return identity

    def _load_existing(self) -> DeviceIdentity:
        self._ensure_key_file_mode()
        pem = self._path.read_bytes()
        private = serialization.load_pem_private_key(pem, password=None)
        if not isinstance(private, Ed25519PrivateKey):
            msg = (
                f"device key at {self._path} is not an Ed25519 private key "
                f"(got {type(private).__name__})"
            )
            raise TypeError(msg)
        return _identity_from_private(private)

    def _generate_and_persist(self) -> DeviceIdentity:
        private = Ed25519PrivateKey.generate()
        pem = private.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
        parent = self._path.parent
        parent.mkdir(mode=_KEY_DIR_MODE, parents=True, exist_ok=True)
        # Write with `O_CREAT | O_EXCL` so we refuse to overwrite a
        # key file that someone else (or a race) slipped in between
        # the `exists()` check and here. Atomic-ish: if the file
        # appears, `open` fails with `FileExistsError` and the caller
        # retries `load_or_create` to pick up the existing key.
        fd = os.open(self._path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, _KEY_FILE_MODE)
        try:
            os.write(fd, pem)
        finally:
            os.close(fd)
        self._ensure_key_file_mode()
        return _identity_from_private(private)

    def _ensure_key_file_mode(self) -> None:
        """Normalize the key-file permission to ``0o600``.

        A mode drift (e.g. someone ran ``chmod +r`` during debugging)
        is a confidentiality concern — the private key becomes
        world-readable. Rather than silently accept, we re-chmod on
        every load. If that fails we bail; the daemon must not run
        with a key file in an unknown permission state.
        """
        current = stat.S_IMODE(self._path.stat().st_mode)
        if current != _KEY_FILE_MODE:
            self._path.chmod(_KEY_FILE_MODE)


def _identity_from_private(private: Ed25519PrivateKey) -> DeviceIdentity:
    public: Ed25519PublicKey = private.public_key()
    raw = public.public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    return DeviceIdentity(
        private_key=private,
        public_key_raw=raw,
        public_key_b64url=_base64url_nopad(raw),
    )
