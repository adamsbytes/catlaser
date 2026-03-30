"""TCP server for the app-to-device API.

Manages multiple concurrent app connections (up to ``MAX_CLIENTS``) over
TCP/Tailscale. Non-blocking poll-based design for integration with the
Python behavior engine's main event loop.

Each connected client speaks the length-prefixed protobuf wire protocol
defined in :mod:`~catlaser_brain.network.wire`. Incoming ``AppRequest``
messages are dispatched to the :class:`~catlaser_brain.network.handler.RequestHandler`;
responses go back to the originating client. Unsolicited ``DeviceEvent``
messages (heartbeats, session summaries, notifications) are broadcast to
all connected clients.
"""

from __future__ import annotations

import select
import socket
from typing import TYPE_CHECKING, Final, Self

from google.protobuf.message import DecodeError

from catlaser_brain.network.wire import FrameReader, encode_frame
from catlaser_brain.proto.catlaser.app.v1 import app_pb2 as pb

if TYPE_CHECKING:
    from catlaser_brain.network.handler import RequestHandler

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

MAX_CLIENTS: Final[int] = 4
"""Maximum simultaneous app connections."""

_RECV_BUF_SIZE: Final[int] = 8192
"""Socket receive buffer size per ``recv()`` call."""

_SEND_TIMEOUT: Final[float] = 1.0
"""Send timeout in seconds. Prevents a stalled client from blocking
the main loop. Clients that cannot receive within this window are
disconnected.
"""


# ---------------------------------------------------------------------------
# Client wrapper
# ---------------------------------------------------------------------------


class _Client:
    """Internal wrapper for a connected app client."""

    __slots__ = ("addr", "reader", "sock")

    def __init__(self, sock: socket.socket, addr: tuple[str, int]) -> None:
        self.sock = sock
        self.addr = addr
        self.reader = FrameReader()


# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------


class AppServer:
    """TCP server for the app-to-device API.

    Binds to the given address and listens for connections from mobile
    apps. Up to :data:`MAX_CLIENTS` clients can be connected simultaneously;
    excess connections are accepted and immediately closed.

    All I/O is non-blocking. Call :meth:`poll` periodically from the main
    event loop to accept new connections, read incoming requests, dispatch
    them to the handler, and send responses. Use :meth:`broadcast` to push
    unsolicited events (heartbeats, notifications) to all clients.

    Args:
        handler: Request dispatcher for incoming ``AppRequest`` messages.
        bind_addr: IP address to bind to.
        port: TCP port to listen on. Use ``0`` for OS-assigned (tests).
    """

    __slots__ = ("_bind_addr", "_clients", "_handler", "_listen_sock", "_port")

    def __init__(
        self,
        handler: RequestHandler,
        bind_addr: str = "0.0.0.0",  # noqa: S104
        port: int = 9820,
    ) -> None:
        self._handler = handler
        self._bind_addr = bind_addr
        self._port = port
        self._listen_sock: socket.socket | None = None
        self._clients: dict[int, _Client] = {}

    # -------------------------------------------------------------------
    # Lifecycle
    # -------------------------------------------------------------------

    def start(self) -> None:
        """Bind and begin listening for connections."""
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.settimeout(0)
        sock.bind((self._bind_addr, self._port))
        sock.listen(MAX_CLIENTS)
        self._listen_sock = sock

    @property
    def address(self) -> tuple[str, int]:
        """Bound ``(host, port)`` address. Available after :meth:`start`."""
        if self._listen_sock is None:
            msg = "server not started"
            raise RuntimeError(msg)
        host: str
        port: int
        host, port = self._listen_sock.getsockname()
        return (host, port)

    @property
    def client_count(self) -> int:
        """Number of currently connected clients."""
        return len(self._clients)

    def close(self) -> None:
        """Disconnect all clients and close the listening socket."""
        for client in self._clients.values():
            client.sock.close()
        self._clients.clear()
        if self._listen_sock is not None:
            self._listen_sock.close()
            self._listen_sock = None

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    # -------------------------------------------------------------------
    # Main loop integration
    # -------------------------------------------------------------------

    def poll(self) -> None:
        """Process all pending network events.

        Accepts new connections, reads from all clients, dispatches
        incoming requests to the handler, and sends responses. Call
        this periodically from the main event loop. Non-blocking.
        """
        if self._listen_sock is None:
            return
        self._accept_pending()
        self._read_clients()

    def broadcast(self, event: pb.DeviceEvent) -> None:
        """Send an event to all connected clients.

        Used for unsolicited pushes: heartbeats, session summaries,
        new-cat-detected notifications, and hopper-empty alerts. Clients
        that fail to receive are disconnected.
        """
        frame = encode_frame(event.SerializeToString())
        dead: list[int] = []
        for fd, client in self._clients.items():
            if not self._send_to(client, frame):
                dead.append(fd)
        for fd in dead:
            self._disconnect(fd)

    # -------------------------------------------------------------------
    # Accept
    # -------------------------------------------------------------------

    def _accept_pending(self) -> None:
        """Accept all pending connections, respecting the client limit.

        Drains the listen backlog. Connections beyond ``MAX_CLIENTS``
        are accepted and immediately closed to prevent backlog buildup.
        """
        if self._listen_sock is None:
            return
        while True:
            try:
                client_sock, addr = self._listen_sock.accept()
            except BlockingIOError:
                return
            if len(self._clients) >= MAX_CLIENTS:
                client_sock.close()
                continue
            client_sock.settimeout(0)
            fd = client_sock.fileno()
            self._clients[fd] = _Client(client_sock, addr)

    # -------------------------------------------------------------------
    # Read
    # -------------------------------------------------------------------

    def _read_clients(self) -> None:
        """Non-blocking read from all connected clients."""
        if not self._clients:
            return
        client_socks = [c.sock for c in self._clients.values()]
        readable: list[socket.socket]
        readable, _, _ = select.select(client_socks, [], [], 0)
        for sock in readable:
            self._on_readable(sock.fileno())

    def _on_readable(self, fd: int) -> None:
        """Read available data from a client and process complete frames."""
        client = self._clients.get(fd)
        if client is None:
            return
        try:
            data = client.sock.recv(_RECV_BUF_SIZE)
        except BlockingIOError:
            return
        except OSError:
            self._disconnect(fd)
            return
        if not data:
            self._disconnect(fd)
            return
        client.reader.feed(data)
        while True:
            try:
                payload = client.reader.next_frame()
            except ValueError:
                self._disconnect(fd)
                return
            if payload is None:
                break
            self._dispatch_and_respond(fd, payload)

    def _dispatch_and_respond(self, fd: int, payload: bytes) -> None:
        """Parse a request, dispatch to handler, send the response."""
        client = self._clients.get(fd)
        if client is None:
            return
        request = pb.AppRequest()
        try:
            request.ParseFromString(payload)
        except DecodeError:
            self._disconnect(fd)
            return
        event = self._handler.handle(request)
        frame = encode_frame(event.SerializeToString())
        if not self._send_to(client, frame):
            self._disconnect(fd)

    # -------------------------------------------------------------------
    # Send
    # -------------------------------------------------------------------

    def _send_to(self, client: _Client, frame: bytes) -> bool:
        """Send a frame to a client. Returns ``False`` on failure."""
        prev = client.sock.gettimeout()
        client.sock.settimeout(_SEND_TIMEOUT)
        try:
            client.sock.sendall(frame)
        except OSError:
            return False
        finally:
            client.sock.settimeout(prev)
        return True

    # -------------------------------------------------------------------
    # Disconnect
    # -------------------------------------------------------------------

    def _disconnect(self, fd: int) -> None:
        """Remove and close a client connection."""
        client = self._clients.pop(fd, None)
        if client is not None:
            client.sock.close()
