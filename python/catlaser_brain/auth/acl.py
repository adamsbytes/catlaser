"""In-memory ACL cache for the device's AppServer handshake.

The cache is written by a background poll loop that calls
:meth:`CoordClient.fetch_acl` on a configurable cadence, and read by
the AppServer's handshake code on every inbound TCP connection. The
store is thread-safe — the AppServer runs on the main event loop,
while the poll loop runs on its own thread, and a polling-window
flip must not race with a handshake read.

## Failure-open vs fail-closed

Short-term network failures between the device and the coordination
server are expected on a product that sits on someone's Wi-Fi. The
poll loop logs and retries; the cached ACL continues to serve until
a newer one arrives. A coordination-server outage therefore does
NOT lock legitimate users out — the device keeps accepting whoever
was on the ACL at the last successful poll.

The one case where a cache is deliberately empty is the boot window
before the first successful poll. The AppServer rejects ALL inbound
handshakes until the store has seen at least one snapshot — a fresh
device that cannot reach the coordination server has no known-good
ACL and MUST NOT accept anyone. The store surfaces this via
:attr:`is_primed`.
"""

from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Callable

    from catlaser_brain.auth.coord_client import AclSnapshot, CoordClient

_logger = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class AclState:
    """Snapshot of the current cache state for diagnostics.

    Exposed via :meth:`AclStore.state` so tests and observability
    tooling can inspect the cache without poking private fields.
    """

    is_primed: bool
    revision: int
    allowed_spkis: frozenset[str]
    last_success_monotonic: float | None


class AclStore:
    """Thread-safe authorization set the handshake reads on every connection.

    Typical lifecycle:

    >>> store = AclStore()
    >>> poll = AclPoller(store, client, interval_seconds=60)
    >>> poll.start()
    >>> # ... later, on handshake:
    >>> if store.is_authorized(client_spki_b64):
    ...     accept()

    A fresh store returns ``False`` from :meth:`is_authorized` for
    every SPKI until the poller has successfully written the first
    snapshot. :attr:`is_primed` is the signal to distinguish "no
    users authorized" (happens on a just-provisioned device with no
    active pair) from "cache not yet initialized."
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._allowed: frozenset[str] = frozenset()
        self._revision: int = 0
        self._is_primed: bool = False
        self._last_success: float | None = None

    def apply(self, snapshot: AclSnapshot) -> frozenset[str]:
        """Install ``snapshot`` as the current ACL.

        Every call is authoritative: the new allowed-set entirely
        replaces the previous one. This matches the server's
        "return the full active set" contract rather than a diff, so
        a revoked user disappears from the cache the next time the
        poller runs.

        Returns the set of SPKIs that appeared in the PREVIOUS snapshot
        but are NOT in this one — the users whose access was just
        revoked. The caller (typically :class:`AclPoller`) forwards
        this set to the :class:`AppServer`, which force-closes any
        currently-authenticated TCP session whose SPKI matches.
        Without the eviction hook a revoked user would keep their
        already-open session alive indefinitely (heartbeats are just
        ordinary requests; the SPKI is only checked at handshake
        time). Returning the diff from :meth:`apply` keeps the
        compute-and-notify step atomic under the store's lock.
        """
        allowed = frozenset(grant.user_spki_b64 for grant in snapshot.grants)
        with self._lock:
            # Only record "primed" and "last success" when the
            # poller ACTUALLY wrote — a polling error path that
            # squirreled away a stale snapshot would otherwise be
            # indistinguishable from a real success. The set of
            # revoked SPKIs is computed against the OLD cache under
            # the same lock so a concurrent handshake can't observe
            # a half-swapped state.
            revoked = self._allowed - allowed
            # On the first successful poll ``self._allowed`` was an
            # empty frozenset, so ``revoked`` is empty — there's no
            # one to evict at priming. Only prior-snapshot SPKIs
            # that disappeared count as revocations.
            self._allowed = allowed
            self._revision = snapshot.revision
            self._is_primed = True
            self._last_success = time.monotonic()
            return revoked

    def is_authorized(self, user_spki_b64: str) -> bool:
        """Return True iff the cache is primed AND ``user_spki_b64`` is active."""
        with self._lock:
            return self._is_primed and user_spki_b64 in self._allowed

    @property
    def is_primed(self) -> bool:
        """True once at least one ACL snapshot has been applied."""
        with self._lock:
            return self._is_primed

    def state(self) -> AclState:
        """Read-only snapshot of the current cache state."""
        with self._lock:
            return AclState(
                is_primed=self._is_primed,
                revision=self._revision,
                allowed_spkis=self._allowed,
                last_success_monotonic=self._last_success,
            )


class AclPoller:
    """Background thread that refreshes :class:`AclStore` on a fixed cadence.

    The thread owns a single :class:`CoordClient` and calls
    :meth:`CoordClient.fetch_acl` every ``interval_seconds``. On
    success, it writes the snapshot into the store. On failure, it
    logs and continues — the prior snapshot survives so a network
    blip doesn't lock legitimate users out.

    The poller is started explicitly via :meth:`start` (not in
    ``__init__``) so tests can instantiate without kicking off a
    thread. :meth:`stop` signals the loop to exit and joins the
    thread; idempotent, so double-stop during daemon shutdown is
    fine.
    """

    def __init__(
        self,
        store: AclStore,
        client: CoordClient,
        *,
        interval_seconds: float = 60.0,
        first_poll_deadline_seconds: float = 30.0,
        on_revoked: Callable[[frozenset[str]], None] | None = None,
    ) -> None:
        if interval_seconds <= 0:
            msg = "interval_seconds must be positive"
            raise ValueError(msg)
        self._store = store
        self._client = client
        self._interval = interval_seconds
        # Shorter deadline for the first poll so a just-booted device
        # doesn't sit in "unprimed, rejecting everyone" for a full
        # regular interval when the server is immediately reachable.
        self._first_deadline = first_poll_deadline_seconds
        # Optional hook fired whenever a snapshot *removes* SPKIs.
        # The poller forwards the diff to the wired-up :class:`AppServer`,
        # which force-closes any currently-authenticated session whose
        # SPKI was revoked. The callback runs on the poller's thread;
        # the receiver (AppServer) must enqueue and drain on its own
        # event loop rather than touching sockets directly.
        self._on_revoked = on_revoked
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        """Launch the background poll thread.

        Calling twice raises — a running poller writes to a shared
        store and a duplicate thread would double-write. If you
        want to restart a poller, stop the old one first.
        """
        if self._thread is not None:
            msg = "AclPoller is already running"
            raise RuntimeError(msg)
        thread = threading.Thread(
            target=self._run,
            name="catlaser-acl-poller",
            daemon=True,
        )
        self._thread = thread
        thread.start()

    def stop(self, *, timeout_seconds: float = 5.0) -> None:
        """Signal the loop to exit and join the thread."""
        self._stop.set()
        thread = self._thread
        if thread is not None and thread.is_alive():
            thread.join(timeout=timeout_seconds)

    def poll_once(self) -> bool:
        """Perform a single poll synchronously. Returns success.

        Exposed for tests and for the daemon's "kick the poller"
        surface (e.g. a user just paired; the UI wants the ACL to
        refresh before the app tries to connect). Does NOT sleep and
        does NOT touch the stop event; callers drive the cadence.
        """
        try:
            snapshot = self._client.fetch_acl()
        except Exception:  # noqa: BLE001
            # Broad catch is intentional: every poll error is
            # "log and try again later," and we don't want a
            # transient TLS hiccup to take the whole daemon down.
            _logger.warning("ACL poll failed", exc_info=True)
            return False
        revoked = self._store.apply(snapshot)
        if revoked and self._on_revoked is not None:
            # Swallow callback errors: the poller's job is to keep
            # the cache fresh. A misbehaving subscriber must not
            # stop future snapshots from landing.
            try:
                self._on_revoked(revoked)
            except Exception:
                _logger.exception("ACL revocation callback raised")
        return True

    def _run(self) -> None:
        # First poll runs immediately (up to the shorter deadline) so
        # a booted device becomes primed fast when the server is
        # reachable. Subsequent polls run on the regular interval.
        first_success = self.poll_once()
        deadline = time.monotonic() + (self._interval if first_success else self._first_deadline)
        while not self._stop.is_set():
            wait = max(0.0, deadline - time.monotonic())
            if self._stop.wait(wait):
                return
            ok = self.poll_once()
            deadline = time.monotonic() + (self._interval if ok else self._first_deadline)
