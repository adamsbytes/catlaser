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

Every connection opens in an unauthenticated state. The first inbound
frame MUST be an :class:`AppRequest.auth` carrying a v4
``x-device-attestation`` header payload with a ``dev:<unix_seconds>``
binding. The server validates the attestation against
:class:`~catlaser_brain.auth.acl.AclStore`; a successful handshake
flips the client into the authenticated state and the server replies
with :class:`AuthResponse` ``(ok=true)``. Any other first frame — or
a failed handshake — causes the connection to be dropped after a
single :class:`AuthResponse` ``(ok=false, reason=...)`` is written so
the app can surface a specific remediation.
"""

from __future__ import annotations

import logging
import select
import socket
from typing import TYPE_CHECKING, Final, Self

from google.protobuf.message import DecodeError

from catlaser_brain.auth.handshake import HandshakeError, verify_auth_request
from catlaser_brain.network.wire import FrameReader, encode_frame
from catlaser_brain.proto.catlaser.app.v1 import app_pb2 as pb

if TYPE_CHECKING:
    from catlaser_brain.auth.acl import AclStore
    from catlaser_brain.network.handler import RequestHandler

_logger = logging.getLogger(__name__)

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
    """Internal wrapper for a connected app client.

    Tracks whether the client has completed the first-frame auth
    handshake. ``authorized_spki`` is ``None`` until the handshake
    succeeds; every frame before that is expected to be
    :class:`AppRequest.auth` and anything else triggers a
    disconnect.
    """

    __slots__ = ("addr", "authorized_spki", "reader", "sock")

    def __init__(self, sock: socket.socket, addr: tuple[str, int]) -> None:
        self.sock = sock
        self.addr = addr
        self.reader = FrameReader()
        self.authorized_spki: str | None = None

    @property
    def is_authorized(self) -> bool:
        return self.authorized_spki is not None


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

    __slots__ = ("_acl", "_bind_addr", "_clients", "_handler", "_listen_sock", "_port")

    def __init__(
        self,
        handler: RequestHandler,
        *,
        acl: AclStore,
        bind_addr: str = "0.0.0.0",  # noqa: S104
        port: int = 9820,
    ) -> None:
        self._handler = handler
        self._acl = acl
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
        """Send an event to all authorized clients.

        Used for unsolicited pushes: heartbeats, session summaries,
        new-cat-detected notifications, and hopper-empty alerts.
        Unauthorized clients (those that haven't completed the
        AuthRequest handshake yet) are skipped — they have no
        business seeing internal device state, and a handshake in
        flight during a broadcast would otherwise leak the first
        push into an attacker's socket. Authorized clients that fail
        to receive are disconnected.
        """
        frame = encode_frame(event.SerializeToString())
        dead: list[int] = []
        for fd, client in self._clients.items():
            if not client.is_authorized:
                continue
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
        if not client.is_authorized:
            # Unauthorized connections may only send AuthRequest.
            # Any other request is a protocol violation and drops
            # the connection after writing the specific reason.
            self._handle_unauthorized_frame(fd, client, request)
            return
        # Authorized clients may send any request EXCEPT a
        # subsequent AuthRequest. A re-handshake attempt after
        # success is either a client bug or an attempt to
        # re-authorize under a different identity mid-connection;
        # the clean answer is to refuse.
        if request.HasField("auth"):
            self._send_auth_response(
                client,
                ok=False,
                reason="DEVICE_AUTH_ALREADY_AUTHORIZED",
                request_id=request.request_id,
            )
            self._disconnect(fd)
            return
        event = self._handler.handle(request)
        frame = encode_frame(event.SerializeToString())
        if not self._send_to(client, frame):
            self._disconnect(fd)

    def _handle_unauthorized_frame(
        self,
        fd: int,
        client: _Client,
        request: pb.AppRequest,
    ) -> None:
        """Gate the handshake. Exactly one AuthRequest is expected."""
        if not request.HasField("auth"):
            # First frame was not an AuthRequest; disconnect without
            # surfacing any state to the attacker. No AuthResponse is
            # written — writing one would help a prober distinguish
            # "wrong frame" from "bad attestation," and the contract
            # says the first frame is ALWAYS AuthRequest.
            _logger.info(
                "app client sent non-auth first frame from %s; disconnecting",
                client.addr,
            )
            self._disconnect(fd)
            return
        attestation_header = request.auth.attestation_header
        try:
            authorized = verify_auth_request(attestation_header, self._acl)
        except HandshakeError as error:
            _logger.info(
                "app client handshake failed: %s from %s",
                error.reason.value,
                client.addr,
            )
            self._send_auth_response(
                client,
                ok=False,
                reason=error.reason.value,
                request_id=request.request_id,
            )
            self._disconnect(fd)
            return
        client.authorized_spki = authorized.user_spki_b64
        self._send_auth_response(
            client,
            ok=True,
            reason="",
            request_id=request.request_id,
        )

    def _send_auth_response(
        self,
        client: _Client,
        *,
        ok: bool,
        reason: str,
        request_id: int,
    ) -> None:
        """Emit a single AuthResponse frame back to ``client``.

        ``request_id`` is echoed from the triggering AuthRequest so
        the app's `DeviceClient` can correlate the response to the
        pending send. A zero value is valid (the app may choose not
        to correlate, in which case the frame lands on its
        unsolicited-event stream).

        Failures to write are swallowed here — the caller that knows
        the handshake outcome is the one that decides whether to
        disconnect afterward, and a socket that can't accept a
        40-byte response is about to be dropped anyway.
        """
        event = pb.DeviceEvent()
        event.request_id = request_id
        event.auth_response.ok = ok
        event.auth_response.reason = reason
        frame = encode_frame(event.SerializeToString())
        if not self._send_to(client, frame):
            # Send failures land the client in `_send_to`'s error
            # path, which the caller handles by disconnecting. The
            # outer dispatcher re-checks `_clients.get` anyway, so a
            # quiet return here is safe.
            return

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
