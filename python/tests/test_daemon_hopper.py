"""Tests for :class:`HopperSensor`: sysfs reads, error handling, level mapping."""

from __future__ import annotations

from pathlib import Path

from catlaser_brain.daemon.hopper import HopperSensor
from catlaser_brain.proto.catlaser.app.v1 import app_pb2 as pb


class TestEnabled:
    def test_disabled_when_path_empty(self) -> None:
        sensor = HopperSensor("")
        # An empty path means "no GPIO is wired in" — used by tests and
        # dev hosts. The sensor never blocks anything.
        assert sensor.enabled is False
        assert sensor.is_empty() is False
        assert sensor.level() == pb.HOPPER_LEVEL_OK

    def test_enabled_when_path_set(self, tmp_path: Path) -> None:
        gpio = tmp_path / "value"
        gpio.write_bytes(b"0\n")
        sensor = HopperSensor(str(gpio))
        assert sensor.enabled is True


class TestSysfsReads:
    def test_beam_blocked_reads_as_full(self, tmp_path: Path) -> None:
        gpio = tmp_path / "value"
        gpio.write_bytes(b"0\n")  # beam blocked → treats present
        sensor = HopperSensor(str(gpio))
        assert sensor.is_empty() is False
        assert sensor.level() == pb.HOPPER_LEVEL_OK

    def test_beam_clear_reads_as_empty(self, tmp_path: Path) -> None:
        gpio = tmp_path / "value"
        gpio.write_bytes(b"1\n")  # beam clear → empty
        sensor = HopperSensor(str(gpio))
        assert sensor.is_empty() is True
        assert sensor.level() == pb.HOPPER_LEVEL_EMPTY

    def test_no_trailing_newline_supported(self, tmp_path: Path) -> None:
        gpio = tmp_path / "value"
        gpio.write_bytes(b"1")
        sensor = HopperSensor(str(gpio))
        # Some kernel versions omit the trailing newline; the sensor
        # strips before comparison so both forms work.
        assert sensor.is_empty() is True

    def test_lazy_read_picks_up_changes(self, tmp_path: Path) -> None:
        gpio = tmp_path / "value"
        gpio.write_bytes(b"0\n")
        sensor = HopperSensor(str(gpio))
        assert sensor.is_empty() is False
        gpio.write_bytes(b"1\n")
        # Each call re-reads — the user refilling treats while the
        # daemon is running must immediately unblock sessions.
        assert sensor.is_empty() is True


class TestErrorHandling:
    def test_missing_file_defaults_to_ok(self, tmp_path: Path) -> None:
        sensor = HopperSensor(str(tmp_path / "missing"))
        # A missing sysfs path is a deployment misconfiguration. We
        # report OK so the daemon still allows sessions while logging
        # the issue.
        assert sensor.is_empty() is False
        assert sensor.level() == pb.HOPPER_LEVEL_OK

    def test_garbage_content_defaults_to_ok(self, tmp_path: Path) -> None:
        gpio = tmp_path / "value"
        gpio.write_bytes(b"unexpected")
        sensor = HopperSensor(str(gpio))
        # Anything that is not exactly "1" or "1\n" reads as full.
        # Conservative — false-empty (blocks sessions) is more
        # disruptive than false-full (a dry dispense cycle).
        assert sensor.is_empty() is False
