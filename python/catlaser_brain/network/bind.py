"""Resolve the tailnet-only bind address for the app-to-device AppServer.

This module exists because a production :class:`AppServer` listen must
be pinned to the device's Tailscale interface. Defaulting the bind
address to ``0.0.0.0`` — even transiently, for a test — opens the
handshake path to every peer on the device's LAN, which is an
unreviewable decision to bake into the library. Instead,
:func:`resolve_tailscale_bind_address` is the single source of truth
for "which IPv4 address represents this device's tailnet presence,"
and the caller passes the returned string as ``bind_addr`` to the
server's constructor.

The resolver reads ``/proc/net/if_inet6`` via the ``socket`` module's
interface tooling — specifically ``socket.if_nameindex`` /
``fcntl.ioctl`` — rather than shelling out to ``ip addr``: the
resolution runs at daemon startup where a sub-process spawn is
measurably slower than a syscall, and is retried on every restart
while the device waits for its tailnet membership to settle.

Failure is fatal. If the expected interface is absent or has no IPv4
address, the resolver raises :class:`NoTailnetInterfaceError`; the
daemon's supervisor is expected to restart the process until the
interface appears. A fallback to "bind to loopback" would be a silent
product regression — callers that want to run against a non-tailnet
interface (tests, integration harnesses) pass ``"127.0.0.1"`` to the
server directly and never call into this module.
"""

from __future__ import annotations

import fcntl
import socket
import struct
from typing import Final

DEFAULT_TAILNET_INTERFACE: Final[str] = "tailscale0"
"""Interface name the production wiring binds to.

Tailscale's userspace daemon creates the interface with this name by
default on Linux. A deployment that renames it via ``TS_TUN_NAME`` must
plumb the override through to the daemon's startup wiring.
"""

_SIOCGIFADDR: Final[int] = 0x8915
"""Linux ``SIOCGIFADDR`` — fetch IPv4 address of an interface.

The numeric constant is defined in ``<linux/sockios.h>`` but not
exposed by Python's ``socket`` module across platforms. Embedding the
value here keeps the resolver self-contained; a mismatch would surface
as an ``OSError(ENOTTY)`` rather than as silent misreads because the
ioctl returns failure on unsupported kernels.
"""

_IFREQ_NAME_LEN: Final[int] = 16
"""The ``struct ifreq`` name field is 16 bytes including the trailing
``\\0``. An interface name of 15 visible bytes + a null terminator is
the historical Linux upper bound; the resolver asserts the input fits.
"""

_IFREQ_MIN_RESPONSE_LEN: Final[int] = 24
"""Minimum bytes we must see in the kernel's response to safely read
the IPv4 address out of it. ``struct ifreq`` is 40 bytes; the address
itself lives at offset 20..24. A truncated response shorter than this
means the ioctl produced garbage and we must refuse it."""


class NoTailnetInterfaceError(RuntimeError):
    """Raised when the requested interface has no IPv4 assigned.

    The daemon treats this as fatal at startup — a device that cannot
    bind to its tailnet address must not fall back to any other
    interface. The supervisor restarts the daemon, which gives
    Tailscale more time to come up before the next attempt.
    """


def resolve_tailscale_bind_address(
    interface: str = DEFAULT_TAILNET_INTERFACE,
) -> str:
    """Return the IPv4 address assigned to ``interface``.

    Raises:
        NoTailnetInterfaceError: the interface does not exist, has no
            IPv4 assigned, or is not an AF_INET address. Every failure
            mode collapses to this type so the caller has one branch
            to handle.
        ValueError: ``interface`` is too long to fit in the kernel's
            ``struct ifreq`` name field.
    """
    if not interface:
        msg = "interface name must be non-empty"
        raise ValueError(msg)
    if len(interface.encode("ascii")) >= _IFREQ_NAME_LEN:
        msg = f"interface name {interface!r} exceeds the kernel's {_IFREQ_NAME_LEN - 1}-byte limit"
        raise ValueError(msg)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # ``struct ifreq`` is 40 bytes: a 16-byte name followed by a
        # union of 24 bytes. For SIOCGIFADDR the kernel writes a
        # ``sockaddr_in`` back into the union. We pack the request
        # with only the name, then unpack the returned 16-byte
        # sockaddr after the name field.
        ifreq = struct.pack("16s16x", interface.encode("ascii"))
        try:
            response: bytes = fcntl.ioctl(sock.fileno(), _SIOCGIFADDR, ifreq)
        except OSError as exc:
            msg = f"interface {interface!r} has no IPv4 address: {exc}"
            raise NoTailnetInterfaceError(msg) from exc
    finally:
        sock.close()
    # Bytes 20..24 of ``response`` are the IPv4 address in network
    # byte order. `struct sockaddr_in` layout on Linux:
    #   bytes 0..1: sin_family (AF_INET == 2)
    #   bytes 2..3: sin_port
    #   bytes 4..7: sin_addr.s_addr
    # The ioctl places this 16-byte `sockaddr_in` at offset 16 inside
    # the returned `ifreq`, so the IPv4 address lives at 20..24.
    if len(response) < _IFREQ_MIN_RESPONSE_LEN:
        msg = f"kernel returned truncated ifreq for {interface!r}: {len(response)} bytes"
        raise NoTailnetInterfaceError(msg)
    family = struct.unpack_from("<H", response, 16)[0]
    if family != socket.AF_INET:
        msg = f"interface {interface!r} has a non-IPv4 primary address (family={family})"
        raise NoTailnetInterfaceError(msg)
    address_bytes = response[20:24]
    return socket.inet_ntoa(address_bytes)
