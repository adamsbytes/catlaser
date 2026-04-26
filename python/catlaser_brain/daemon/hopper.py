"""Hopper sensor read for autonomous-session gating.

The treat hopper has an IR break-beam sensor at the base. The MCU
reads it for the status LED (see :mod:`catlaser-mcu/hopper.rs`); the
compute module reads the SAME GPIO line via sysfs for session gating
so a freshly-empty hopper blocks autonomous sessions until the owner
refills.

This module is a thin wrapper. The default implementation reads
``/sys/class/gpio/gpioN/value``: ``0`` = beam blocked = treats present,
``1`` = beam clear = empty. The orchestrator constructs a
:class:`HopperSensor` from the daemon config — when the env var is
unset the sensor returns "OK" and never blocks anything, which is the
correct behaviour for tests and dev hosts without the GPIO wired in.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Final

from catlaser_brain.proto.catlaser.app.v1 import app_pb2 as pb

_logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_BEAM_CLEAR: Final[bytes] = b"1"
"""Sysfs read value when the IR break-beam is unbroken (no treats overhead)."""


class HopperSensor:
    """Reads the hopper IR break-beam GPIO via sysfs.

    Construction never reads the file; reads happen lazily on every
    :meth:`is_empty` / :meth:`level` call so a transient sysfs error
    surfaces as "assume OK" without blocking session start
    permanently. A persistent error gets logged once per process via
    the ``_warned_once`` flag — repeated polls do not flood the log.

    Args:
        gpio_path: Sysfs ``value`` file path (e.g.
            ``/sys/class/gpio/gpio42/value``). Empty string disables
            the sensor; :meth:`is_empty` then always returns ``False``
            and :meth:`level` returns ``HOPPER_LEVEL_OK``.
    """

    __slots__ = ("_path", "_warned_once")

    def __init__(self, gpio_path: str) -> None:
        self._path = Path(gpio_path) if gpio_path else None
        self._warned_once = False

    @property
    def enabled(self) -> bool:
        """Whether this sensor reads a real GPIO file."""
        return self._path is not None

    def is_empty(self) -> bool:
        """Returns ``True`` if the hopper currently reads as empty.

        Sysfs read errors are treated as "not empty" to avoid blocking
        sessions when the GPIO is misconfigured — false-empty is more
        disruptive than false-OK (the dispenser short-cycles a couple
        of times before the user refills).
        """
        if self._path is None:
            return False
        try:
            data = self._path.read_bytes().strip()
        except OSError as exc:
            if not self._warned_once:
                _logger.warning(
                    "hopper sensor read failed at %s: %s; defaulting to OK",
                    self._path,
                    exc,
                )
                self._warned_once = True
            return False
        # Accept either "0\n" / "1\n" or just "0" / "1".
        return data == _BEAM_CLEAR

    def level(self) -> pb.HopperLevel:
        """Returns the proto-encoded hopper level for ``StatusUpdate``.

        Two-state for now: ``HOPPER_LEVEL_OK`` or ``HOPPER_LEVEL_EMPTY``.
        ``HOPPER_LEVEL_LOW`` is reserved for a future multi-sensor
        configuration that can distinguish "almost empty."
        """
        return pb.HOPPER_LEVEL_EMPTY if self.is_empty() else pb.HOPPER_LEVEL_OK
