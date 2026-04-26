"""Catlaser daemon orchestrator.

Composes the pieces of :mod:`catlaser_brain` into a runnable process:
SQLite, the device identity, the coordination-server ACL poller, the
vision IPC client, the behavior engine, the app TCP server, the LiveKit
stream manager, and FCM push notifications.

The orchestrator is the only place that bridges Rust IPC to the
behavior engine and the app server to the vision daemon. Every other
module under :mod:`catlaser_brain` stays pure (no I/O, no globals) and
is wired together here.
"""

from __future__ import annotations

from catlaser_brain.daemon.config import ConfigError, DaemonConfig
from catlaser_brain.daemon.orchestrator import Daemon

__all__ = ["ConfigError", "Daemon", "DaemonConfig"]
