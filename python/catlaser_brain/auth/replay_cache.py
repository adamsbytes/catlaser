"""Replay-detection cache for the AppServer handshake.

Stores ``(user_spki_b64, timestamp)`` tuples that the handshake verifier
has already consumed. Used to reject an on-path attacker who captures
the raw bytes of a legitimate handshake and resends them within the
±60 s skew window.

The cache is thread-safe: the handshake runs on the AppServer's event
loop thread, but the ACL poller and other background threads may
share the store in future. A single mutex guards every read+write.

## Keying

The tuple is ``(spki_b64, timestamp_seconds, signature_bytes)``. The
signature component is load-bearing: ECDSA-P256-SHA256 is randomised
(a fresh nonce ``k`` per signing op), so two legitimate handshakes
from the same Secure-Enclave key at the same wall-clock second
produce distinct signatures and therefore distinct cache entries. A
captured-bytes replay cannot refresh the signature without the SE
private key, so its ``(spki, ts, sig)`` tuple collides with the one
stored by the original legitimate use.

Keying on ``(spki, ts)`` alone would false-positive on legitimate
sub-second reconnects (e.g., a ``ConnectionManager`` backoff of
250 ms that lands in the same wall-clock second as the drop) and on
a household running the app on two devices under one account
(same SPKI, possibly same second). Keying on ``signature`` alone
would work but loses the per-user diagnostic hook that ``spki_b64``
provides; bundling all three keeps debug logs useful without
weakening the check.

## TTL

Entries expire ``2 * DEV_SKEW_SECONDS`` (120 s) after the consumed
timestamp. The factor of two gives a comfortable margin over the
skew-check window: a timestamp past ``now - DEV_SKEW_SECONDS`` would
fail the skew check anyway, so a 120 s TTL is the smallest bound that
keeps us safe from an attacker aligning a replay right at the edge of
the skew window. Expired entries are swept lazily on every
``check_and_consume`` call; no background thread is required.
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from typing import Final

DEFAULT_TTL_SECONDS: Final[int] = 120
"""Default time-to-live for a consumed ``(spki, ts)`` entry.

Twice the handshake skew window (``DEV_SKEW_SECONDS`` = 60). A smaller
TTL would leave a gap at the trailing edge of the skew window where a
replay could sneak through; a larger TTL just bloats the cache.
"""


@dataclass(frozen=True, slots=True)
class _Entry:
    """A single cache entry.

    Stored in a dict keyed by ``(spki_b64, timestamp)`` — ``expires_at``
    is the wall-clock second at which the entry should be evicted.
    """

    expires_at: int


class ReplayCache:
    """Thread-safe TTL set of consumed handshake ``(spki, ts)`` tuples.

    The primary operation is :meth:`check_and_consume`, which atomically
    sweeps expired entries, rejects any already-seen tuple, and records
    the new one. The atomicity is load-bearing: a concurrent handshake
    thread attempting the same replay must not observe an intermediate
    state that lets both pass.

    Args:
        ttl_seconds: Entry lifetime. Defaults to :data:`DEFAULT_TTL_SECONDS`.
            Tests inject a smaller value to exercise expiry without
            sleeping.
    """

    __slots__ = ("_entries", "_lock", "_ttl")

    def __init__(self, *, ttl_seconds: int = DEFAULT_TTL_SECONDS) -> None:
        if ttl_seconds <= 0:
            msg = f"ttl_seconds must be positive, got {ttl_seconds}"
            raise ValueError(msg)
        self._ttl = ttl_seconds
        self._entries: dict[tuple[str, int, bytes], _Entry] = {}
        self._lock = threading.Lock()

    def check_and_consume(
        self,
        spki_b64: str,
        timestamp: int,
        signature: bytes,
        *,
        now_seconds: int | None = None,
    ) -> bool:
        """Atomically record a fresh ``(spki, ts, sig)`` or detect a replay.

        Returns ``True`` when the tuple was unseen within the TTL
        window and has now been recorded; returns ``False`` when the
        tuple is a replay of an already-consumed entry that has not
        yet expired.

        Expired entries are swept in the same critical section, so a
        long-idle process cannot accumulate dead entries past the TTL
        window.

        Args:
            spki_b64: Standard-base64 DER SPKI of the signer. Already
                derived by the caller from the verified ``pk`` field.
                Included in the key so diagnostic logs can name the
                user whose handshake was replayed.
            timestamp: Wall-clock seconds from the ``dev:<ts>`` binding.
                Already validated against the skew window by the
                caller.
            signature: Raw DER-encoded ECDSA signature bytes. The
                randomised-``k`` component of ECDSA-P256 means two
                legitimate signing ops over the same inputs produce
                distinct signatures; an attacker replaying captured
                bytes cannot refresh this without the SE private key.
            now_seconds: Override for tests that need to advance the
                clock without sleeping. Production callers omit.
        """
        now = int(time.time()) if now_seconds is None else now_seconds
        key = (spki_b64, timestamp, bytes(signature))
        expires_at = now + self._ttl
        with self._lock:
            self._sweep(now)
            if key in self._entries:
                return False
            self._entries[key] = _Entry(expires_at=expires_at)
            return True

    def size(self) -> int:
        """Number of entries currently held. Diagnostic only."""
        with self._lock:
            return len(self._entries)

    def _sweep(self, now: int) -> None:
        """Evict entries whose ``expires_at`` is in the past.

        Must be called under ``self._lock``. O(N) over the cache, but
        N is bounded by the rate of successful handshakes within the
        TTL window — in the single-household product, at most a handful
        of SPKIs, each reconnecting at most every few seconds. Any
        larger deployment would use a min-heap; we deliberately do not
        pre-optimise for it.
        """
        stale = [key for key, entry in self._entries.items() if entry.expires_at <= now]
        for key in stale:
            del self._entries[key]
