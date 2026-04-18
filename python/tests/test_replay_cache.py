"""Tests for the handshake replay cache.

The cache is a primitive under :mod:`catlaser_brain.auth.handshake`; the
end-to-end "replayed bytes get ``REPLAY_DETECTED``" assertion lives in
``test_app_api.py`` alongside the other handshake tests. This file
covers the cache's own invariants: atomic check-and-consume, TTL
expiry, independence across users, independence across timestamps,
and the signature component of the key.
"""

from __future__ import annotations

import pytest

from catlaser_brain.auth.replay_cache import DEFAULT_TTL_SECONDS, ReplayCache

_SPKI_A = "spki-user-a"
_SPKI_B = "spki-user-b"
_SIG_1 = b"\x30\x44\x02\x20" + (b"\xaa" * 32) + (b"\xbb" * 32)
_SIG_2 = b"\x30\x44\x02\x20" + (b"\xcc" * 32) + (b"\xdd" * 32)


class TestReplayCacheBasic:
    def test_first_consume_returns_true(self) -> None:
        cache = ReplayCache()
        assert cache.check_and_consume(_SPKI_A, 1_000_000, _SIG_1, now_seconds=1_000_000) is True

    def test_exact_replay_returns_false(self) -> None:
        cache = ReplayCache()
        cache.check_and_consume(_SPKI_A, 1_000_000, _SIG_1, now_seconds=1_000_000)
        assert cache.check_and_consume(_SPKI_A, 1_000_000, _SIG_1, now_seconds=1_000_000) is False

    def test_different_signatures_same_spki_same_ts_both_accepted(self) -> None:
        """Legit same-second reconnect: ECDSA random ``k`` yields distinct sigs."""
        cache = ReplayCache()
        assert cache.check_and_consume(_SPKI_A, 1_000_000, _SIG_1, now_seconds=1_000_000) is True
        assert cache.check_and_consume(_SPKI_A, 1_000_000, _SIG_2, now_seconds=1_000_000) is True

    def test_different_spkis_do_not_interfere(self) -> None:
        cache = ReplayCache()
        assert cache.check_and_consume(_SPKI_A, 1_000_000, _SIG_1, now_seconds=1_000_000) is True
        assert cache.check_and_consume(_SPKI_B, 1_000_000, _SIG_1, now_seconds=1_000_000) is True

    def test_different_timestamps_same_spki_same_sig_both_accepted(self) -> None:
        cache = ReplayCache()
        assert cache.check_and_consume(_SPKI_A, 1_000_000, _SIG_1, now_seconds=1_000_000) is True
        assert cache.check_and_consume(_SPKI_A, 1_000_001, _SIG_1, now_seconds=1_000_001) is True


class TestReplayCacheExpiry:
    def test_entry_expires_exactly_at_ttl_boundary(self) -> None:
        # Entries whose expires_at <= now are swept; TTL is inclusive at
        # the boundary so after exactly ``ttl`` seconds the slot is free
        # and the tuple can be re-consumed (by a fresh legitimate call —
        # in practice a replay attacker can no longer reach the replay
        # check because the skew-check rejects a ts that old).
        cache = ReplayCache(ttl_seconds=10)
        cache.check_and_consume(_SPKI_A, 1_000_000, _SIG_1, now_seconds=1_000_000)
        # Still within TTL.
        assert cache.check_and_consume(_SPKI_A, 1_000_000, _SIG_1, now_seconds=1_000_009) is False
        # At TTL boundary the entry is swept.
        assert cache.check_and_consume(_SPKI_A, 1_000_000, _SIG_1, now_seconds=1_000_010) is True

    def test_default_ttl_is_twice_the_handshake_skew_window(self) -> None:
        # Locks the TTL constant against accidental drift. The TTL is
        # the smallest bound that keeps the cache safe across the full
        # ±60 s skew window that the handshake accepts.
        assert DEFAULT_TTL_SECONDS == 120

    def test_sweep_removes_only_expired_entries(self) -> None:
        cache = ReplayCache(ttl_seconds=10)
        # First entry: consumed at t=1_000_000, expires at 1_000_010.
        cache.check_and_consume(_SPKI_A, 1_000_000, _SIG_1, now_seconds=1_000_000)
        # Second entry: consumed at t=1_000_005, expires at 1_000_015.
        cache.check_and_consume(_SPKI_B, 1_000_005, _SIG_2, now_seconds=1_000_005)
        assert cache.size() == 2
        # Advance to t=1_000_010: the first entry's expires_at equals
        # now and is swept (inclusive boundary); the second entry's
        # expires_at is still 5 s in the future. Insert a third entry
        # so we can distinguish "swept + inserted" (size 2) from
        # "swept, insert failed" (size 1).
        cache.check_and_consume(_SPKI_A, 1_000_010, _SIG_1, now_seconds=1_000_010)
        assert cache.size() == 2

    def test_expired_entry_accepts_reconsume(self) -> None:
        cache = ReplayCache(ttl_seconds=10)
        cache.check_and_consume(_SPKI_A, 1_000_000, _SIG_1, now_seconds=1_000_000)
        assert cache.check_and_consume(_SPKI_A, 1_000_000, _SIG_1, now_seconds=1_000_020) is True


class TestReplayCacheConstruction:
    def test_zero_ttl_rejected(self) -> None:
        with pytest.raises(ValueError, match="ttl_seconds must be positive"):
            ReplayCache(ttl_seconds=0)

    def test_negative_ttl_rejected(self) -> None:
        with pytest.raises(ValueError, match="ttl_seconds must be positive"):
            ReplayCache(ttl_seconds=-1)

    def test_size_starts_at_zero(self) -> None:
        assert ReplayCache().size() == 0
