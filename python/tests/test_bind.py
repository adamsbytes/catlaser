"""Tests for :mod:`catlaser_brain.network.bind`.

The resolver reads a kernel-level ioctl that's unavailable on test
runners without a `tailscale0` interface. Tests mock ``fcntl.ioctl``
with stubbed byte strings matching the kernel's `struct ifreq` layout
so every success and failure path is exercised deterministically.
"""

from __future__ import annotations

import socket
import struct
from typing import Any
from unittest.mock import patch

import pytest

from catlaser_brain.network.bind import (
    NoTailnetInterfaceError,
    resolve_tailscale_bind_address,
)


def _packed_ifreq(ip: str, family: int = socket.AF_INET) -> bytes:
    """Build the 40-byte `ifreq` response the kernel writes on success.

    Layout:

    * bytes 0..15: name (ignored on the read path, kernel echoes it)
    * bytes 16..17: sin_family (AF_INET on the happy path)
    * bytes 18..19: sin_port (unused for this ioctl)
    * bytes 20..23: sin_addr.s_addr (IPv4, network byte order)
    * bytes 24..39: padding
    """
    head = struct.pack("16s", b"tailscale0")
    family_bytes = struct.pack("<H", family)
    port_bytes = b"\x00\x00"
    addr_bytes = socket.inet_aton(ip)
    pad = b"\x00" * 16
    return head + family_bytes + port_bytes + addr_bytes + pad


class TestResolveTailscaleBindAddress:
    def test_returns_ipv4_for_valid_interface(self) -> None:
        # 100.64.0.0/10 is the CGNAT range Tailscale uses by default.
        # Any address in that range is a plausible real response.
        expected = "100.64.5.42"
        response = _packed_ifreq(expected)
        with patch("catlaser_brain.network.bind.fcntl.ioctl", return_value=response):
            assert resolve_tailscale_bind_address() == expected

    def test_raises_when_interface_does_not_exist(self) -> None:
        def raise_enodev(*_: Any) -> bytes:  # pragma: no cover - tested via mock
            raise OSError(19, "No such device")

        with (
            patch("catlaser_brain.network.bind.fcntl.ioctl", side_effect=raise_enodev),
            pytest.raises(NoTailnetInterfaceError, match="No such device"),
        ):
            resolve_tailscale_bind_address()

    def test_raises_when_interface_has_no_ipv4(self) -> None:
        # Linux's SIOCGIFADDR returns EADDRNOTAVAIL for a link-local
        # interface that has only IPv6. Resolver must surface this as
        # NoTailnetInterfaceError so the supervisor can retry.
        def raise_eaddrnotavail(*_: Any) -> bytes:  # pragma: no cover - mock
            raise OSError(99, "Cannot assign requested address")

        with (
            patch(
                "catlaser_brain.network.bind.fcntl.ioctl",
                side_effect=raise_eaddrnotavail,
            ),
            pytest.raises(NoTailnetInterfaceError),
        ):
            resolve_tailscale_bind_address()

    def test_rejects_non_ipv4_family(self) -> None:
        # If the kernel ever returned an AF_INET6 sockaddr here, the
        # resolver must refuse rather than misread bytes as IPv4.
        response = _packed_ifreq("100.64.5.42", family=socket.AF_INET6)
        with (
            patch("catlaser_brain.network.bind.fcntl.ioctl", return_value=response),
            pytest.raises(NoTailnetInterfaceError, match="non-IPv4"),
        ):
            resolve_tailscale_bind_address()

    def test_rejects_truncated_response(self) -> None:
        # A cosmically-unlikely kernel bug that truncates the response
        # must not be silently treated as a zero IP.
        response = b"\x00" * 20
        with (
            patch("catlaser_brain.network.bind.fcntl.ioctl", return_value=response),
            pytest.raises(NoTailnetInterfaceError, match="truncated"),
        ):
            resolve_tailscale_bind_address()

    def test_empty_interface_name_raises(self) -> None:
        with pytest.raises(ValueError, match="non-empty"):
            resolve_tailscale_bind_address("")

    def test_oversized_interface_name_raises(self) -> None:
        with pytest.raises(ValueError, match="exceeds"):
            resolve_tailscale_bind_address("a" * 64)

    def test_custom_interface_name_is_passed_through(self) -> None:
        # A deployment that renamed the TUN to `ts0` via TS_TUN_NAME
        # must be able to override. The name is packed into the ioctl
        # request; assert the ioctl is called at all.
        response = _packed_ifreq("100.64.1.1")
        called_with: dict[str, bytes] = {}

        def spy(fd: int, op: int, arg: bytes) -> bytes:  # pragma: no cover - mock
            called_with["arg"] = arg
            _ = fd, op
            return response

        with patch("catlaser_brain.network.bind.fcntl.ioctl", side_effect=spy):
            assert resolve_tailscale_bind_address("ts0") == "100.64.1.1"
        assert called_with["arg"][:3] == b"ts0"
