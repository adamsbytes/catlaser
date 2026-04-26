"""Top-level daemon orchestrator.

Builds every subsystem from :class:`DaemonConfig`, wires them together,
and runs the main loop until SIGTERM/SIGINT. The orchestrator is the
ONLY place that touches the network, the database, the IPC socket, and
the Rust vision daemon at runtime — everything else stays pure.

Lifecycle:

1. Load device identity (or generate on first boot).
2. Optionally provision with the coordination server.
3. Start the ACL poller thread (refreshes the in-memory ACL cache).
4. Optionally instantiate the LiveKit :class:`StreamManager` and the
   FCM :class:`PushNotifier` from their env-var configs.
5. Open SQLite, build the cat catalog, and construct the
   :class:`SessionBridge`.
6. Resolve the tailnet bind address (or use the override from config),
   build the app server, attach the bridge as :class:`SessionControl`
   and the :class:`StreamBridge` as :class:`StreamNotify`.
7. Connect the vision IPC client (with retry — the Rust daemon may
   not be up yet on cold boot).
8. Enter the main loop:

   * drain inbound vision IPC, dispatch via the bridge;
   * ship outbound IPC frames returned by the bridge;
   * run :meth:`AppServer.poll`;
   * on a steady cadence, emit ``StatusUpdate`` heartbeats.

9. On signal (SIGTERM/SIGINT) clean up: stop the ACL poller, close the
   IPC client, close the app server, close the database.
"""

from __future__ import annotations

import logging
import signal
import socket
import threading
import time
from typing import TYPE_CHECKING, Final

from catlaser_brain.auth.acl import AclPoller, AclStore
from catlaser_brain.auth.coord_client import CoordClient, CoordClientError
from catlaser_brain.auth.identity import DeviceIdentityStore
from catlaser_brain.daemon.hopper import HopperSensor
from catlaser_brain.daemon.session_bridge import (
    OutboundMessages,
    SessionBridge,
    SessionFinalized,
)
from catlaser_brain.daemon.stream_bridge import StreamBridge
from catlaser_brain.identity.catalog import CatCatalog
from catlaser_brain.ipc.client import IncomingMessage, IpcClient
from catlaser_brain.ipc.wire import MsgType
from catlaser_brain.network.bind import (
    NoTailnetInterfaceError,
    resolve_tailscale_bind_address,
)
from catlaser_brain.network.handler import DeviceState, RequestHandler
from catlaser_brain.network.push import PushConfig, PushNotifier
from catlaser_brain.network.server import AppServer
from catlaser_brain.network.streaming import StreamConfig, StreamManager
from catlaser_brain.proto.catlaser.app.v1 import app_pb2 as app_pb
from catlaser_brain.proto.catlaser.detection.v1 import detection_pb2 as det
from catlaser_brain.storage.db import Database

if TYPE_CHECKING:
    import sqlite3

    from catlaser_brain.daemon.config import DaemonConfig

_logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Loop tuning
# ---------------------------------------------------------------------------

_LOOP_TICK_SEC: Final[float] = 0.01
"""Sleep between main-loop iterations when no IPC frames are pending.

100 Hz is fine-grained enough that the latency between a vision-side
DetectionFrame arriving and a BehaviorCommand going back is a single
loop iteration; coarse enough that an idle daemon does not consume
measurable CPU.
"""

_HEARTBEAT_INTERVAL_SEC: Final[float] = 5.0
"""How often to broadcast a ``StatusUpdate`` to all connected app
clients. The app uses these as both a connection-liveness signal and
a place to read the hopper level.
"""

_IPC_RECONNECT_INTERVAL_SEC: Final[float] = 1.0
"""Seconds between IPC reconnect attempts when the vision daemon is
unreachable. The Rust side binds the socket synchronously at startup;
1 s gives a fast first attempt without busy-looping.
"""


# ---------------------------------------------------------------------------
# Daemon
# ---------------------------------------------------------------------------


class Daemon:
    """Long-running orchestrator for the catlaser Python sidecar.

    Construct from a validated :class:`DaemonConfig`. Call :meth:`run`
    to start the main loop; the loop returns when a TERM/INT signal
    arrives or :meth:`request_shutdown` is invoked from a test.

    Args:
        config: Validated daemon configuration.
    """

    def __init__(self, config: DaemonConfig) -> None:
        self._config = config
        self._shutdown = threading.Event()

    def request_shutdown(self) -> None:
        """Signal the main loop to exit at the next iteration.

        Tests use this to terminate a running daemon deterministically;
        production triggers it via SIGTERM/SIGINT handlers.
        """
        self._shutdown.set()

    def run(self) -> None:
        """Build subsystems, wire them, and run the loop until shutdown.

        Any failure during the bring-up phase raises and propagates to
        :func:`__main__.main`, which logs it and exits non-zero.
        Failures inside the loop are caught per-message and logged; a
        broken IPC connection triggers a reconnect attempt instead of
        unwinding the daemon.
        """
        identity_store = DeviceIdentityStore(self._config.device_key_path)
        identity = identity_store.load_or_create()

        coord_client = CoordClient(
            self._config.coord_base_url,
            identity,
            self._config.device_slug,
        )
        try:
            self._maybe_provision(coord_client)

            acl_store = AclStore()
            stream_manager = self._build_stream_manager()
            push_notifier_factory = self._build_push_factory()

            self._install_signal_handlers()

            with Database.connect(self._config.database_path) as database:
                push_notifier = (
                    push_notifier_factory(database.conn)
                    if push_notifier_factory is not None
                    else None
                )
                catalog = CatCatalog(database)
                hopper = HopperSensor(self._config.hopper_gpio_path)
                bridge = SessionBridge(
                    conn=database.conn,
                    catalog=catalog,
                    hopper=hopper,
                )
                stream_bridge = StreamBridge(ipc=None)

                device_state = DeviceState(
                    hopper_level=hopper.level(),
                    session_active=False,
                    active_cat_ids=[],
                    boot_time=time.monotonic(),
                    firmware_version=self._config.firmware_version,
                )

                handler = RequestHandler(
                    database.conn,
                    device_state,
                    session_control=bridge,
                    stream_manager=stream_manager,
                    stream_notify=stream_bridge,
                )

                app_server = self._build_app_server(
                    handler=handler,
                    acl_store=acl_store,
                    identity=identity,
                )

                # The ACL poller forwards revocations to the app
                # server's eviction queue. Constructing the poller AFTER
                # the server lets us thread the callback in cleanly,
                # without a re-binding step.
                acl_poller = AclPoller(
                    acl_store,
                    coord_client,
                    interval_seconds=self._config.acl_poll_interval,
                    on_revoked=app_server.notify_spkis_revoked,
                )

                acl_poller.start()
                try:
                    app_server.start()
                    try:
                        self._main_loop(
                            bridge=bridge,
                            stream_bridge=stream_bridge,
                            app_server=app_server,
                            device_state=device_state,
                            hopper=hopper,
                            push=push_notifier,
                            stream_manager=stream_manager,
                        )
                    finally:
                        app_server.close()
                finally:
                    acl_poller.stop()
                    if stream_manager is not None:
                        stream_manager.close()
        finally:
            coord_client.close()

    # -------------------------------------------------------------------
    # Bring-up
    # -------------------------------------------------------------------

    def _maybe_provision(self, coord_client: CoordClient) -> None:
        if not self._config.provisioning_token:
            return
        try:
            created = coord_client.provision(
                self._config.provisioning_token,
                self._config.tailscale_host,
                self._config.app_port,
                device_name=self._config.device_name or None,
            )
        except CoordClientError:
            _logger.exception("device provisioning failed; continuing without re-publishing key")
            return
        _logger.info(
            "device provisioned (created=%s, slug=%s)",
            created,
            self._config.device_slug,
        )

    def _build_stream_manager(self) -> StreamManager | None:
        if not self._config.livekit_enabled:
            return None
        try:
            stream_config = StreamConfig.from_env()
        except ValueError:
            _logger.exception("LiveKit env vars present but invalid; streaming disabled")
            return None
        return StreamManager(stream_config)

    def _build_push_factory(self):
        if not self._config.push_enabled:
            return None
        try:
            push_config = PushConfig.from_env()
        except (ValueError, FileNotFoundError):
            _logger.exception("FCM env vars present but invalid; push disabled")
            return None

        def factory(conn: sqlite3.Connection) -> PushNotifier:
            return PushNotifier(push_config, conn)

        return factory

    def _build_app_server(
        self,
        *,
        handler: RequestHandler,
        acl_store: AclStore,
        identity: object,
    ) -> AppServer:
        bind_address = self._config.bind_address or self._resolve_bind_address()
        bind_interface = self._config.bind_interface or None
        return AppServer(
            handler,
            acl=acl_store,
            device_identity=identity,  # pyright: ignore[reportArgumentType]
            bind_addr=bind_address,
            bind_interface=bind_interface,
            port=self._config.app_port,
        )

    def _resolve_bind_address(self) -> str:
        try:
            return resolve_tailscale_bind_address(
                self._config.bind_interface or "tailscale0",
            )
        except NoTailnetInterfaceError:
            _logger.exception("tailnet interface not ready; daemon cannot start")
            raise

    def _install_signal_handlers(self) -> None:
        # Two signals only: TERM is what supervisors send, INT is for
        # an interactive Ctrl-C in dev. Handlers set the shutdown event
        # and return; the main loop checks it on every iteration.
        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, self._on_signal)

    def _on_signal(self, _signum: int, _frame: object) -> None:
        self._shutdown.set()

    # -------------------------------------------------------------------
    # Main loop
    # -------------------------------------------------------------------

    def _main_loop(  # noqa: PLR0913 — top-level orchestrator
        self,
        *,
        bridge: SessionBridge,
        stream_bridge: StreamBridge,
        app_server: AppServer,
        device_state: DeviceState,
        hopper: HopperSensor,
        push: PushNotifier | None,
        stream_manager: StreamManager | None,
    ) -> None:
        _logger.info("daemon main loop starting")

        ipc: IpcClient | None = None
        next_reconnect = 0.0
        next_heartbeat = time.monotonic() + _HEARTBEAT_INTERVAL_SEC

        while not self._shutdown.is_set():
            now = time.monotonic()

            ipc, next_reconnect = self._ensure_ipc(
                ipc=ipc,
                next_reconnect=next_reconnect,
                now=now,
                stream_bridge=stream_bridge,
                bridge=bridge,
            )

            if ipc is not None:
                ipc, next_reconnect = self._drain_ipc(
                    ipc=ipc,
                    bridge=bridge,
                    stream_bridge=stream_bridge,
                    next_reconnect=next_reconnect,
                    now=now,
                )

            app_server.poll()

            self._broadcast_finalised(
                bridge=bridge,
                app_server=app_server,
                push=push,
                stream_manager=stream_manager,
                stream_bridge=stream_bridge,
            )

            if now >= next_heartbeat:
                self._refresh_state(device_state, hopper, bridge)
                self._broadcast_status(app_server, device_state)
                next_heartbeat = now + _HEARTBEAT_INTERVAL_SEC

            if self._shutdown.wait(_LOOP_TICK_SEC):
                break

        if ipc is not None:
            ipc.close()
        _logger.info("daemon main loop exiting")

    def _ensure_ipc(
        self,
        *,
        ipc: IpcClient | None,
        next_reconnect: float,
        now: float,
        stream_bridge: StreamBridge,
        bridge: SessionBridge,
    ) -> tuple[IpcClient | None, float]:
        if ipc is not None:
            return ipc, next_reconnect
        if now < next_reconnect:
            return None, next_reconnect
        try:
            new_ipc = IpcClient.connect(self._config.vision_socket_path)
        except (FileNotFoundError, ConnectionRefusedError, OSError):
            _logger.debug(
                "vision IPC unavailable at %s; will retry",
                self._config.vision_socket_path,
            )
            return None, now + _IPC_RECONNECT_INTERVAL_SEC
        _logger.info("vision IPC connected at %s", self._config.vision_socket_path)
        # Reset bridge state on connect so any session that was active
        # before a previous disconnect cannot leak into the new session.
        bridge.handle_disconnect()
        stream_bridge.set_ipc(new_ipc)
        return new_ipc, now

    def _drain_ipc(
        self,
        *,
        ipc: IpcClient,
        bridge: SessionBridge,
        stream_bridge: StreamBridge,
        next_reconnect: float,
        now: float,
    ) -> tuple[IpcClient | None, float]:
        # Pull every queued message in a single tick; bounded by
        # vision daemon's emission rate (~15 frames/sec plus sporadic
        # events). Stops on the first None or on connection loss.
        for _ in range(64):
            try:
                msg = ipc.try_recv()
            except (ConnectionError, ValueError):
                _logger.warning("vision IPC connection broken; reconnecting", exc_info=True)
                ipc.close()
                bridge.handle_disconnect()
                stream_bridge.set_ipc(None)
                return None, now + _IPC_RECONNECT_INTERVAL_SEC
            if msg is None:
                break
            if not self._dispatch_ipc_message(ipc, bridge, msg):
                _logger.warning("vision IPC send failed; reconnecting")
                ipc.close()
                bridge.handle_disconnect()
                stream_bridge.set_ipc(None)
                return None, now + _IPC_RECONNECT_INTERVAL_SEC
        return ipc, next_reconnect

    def _dispatch_ipc_message(
        self,
        ipc: IpcClient,
        bridge: SessionBridge,
        msg: IncomingMessage,
    ) -> bool:
        """Dispatch a single inbound IPC message.

        Returns ``True`` if processing succeeded. Returns ``False`` if
        an outbound send failed and the caller must reconnect.
        """
        outgoing = _bridge_dispatch(bridge, msg)
        if outgoing is None:
            return True
        return _send_outgoing(ipc, outgoing)

    def _broadcast_finalised(
        self,
        *,
        bridge: SessionBridge,
        app_server: AppServer,
        push: PushNotifier | None,
        stream_manager: StreamManager | None,
        stream_bridge: StreamBridge,
    ) -> None:
        finalized = bridge.take_finalized()
        if finalized is None:
            return
        _broadcast_session_summary(app_server, finalized)
        if push is not None:
            _send_session_summary_push(push, finalized)
        # End-of-session is a natural stop point for an active stream:
        # no cat is being targeted, so the live view degrades to "home
        # position laser off" anyway. Stop the stream so a new one can
        # be requested cleanly. No-op if no stream is active.
        if stream_manager is not None and stream_manager.is_streaming:
            stream_manager.stop()
            stream_bridge.on_stream_stop()

    def _refresh_state(
        self,
        device_state: DeviceState,
        hopper: HopperSensor,
        bridge: SessionBridge,
    ) -> None:
        device_state.hopper_level = hopper.level()
        device_state.session_active = bridge.is_active
        device_state.active_cat_ids = bridge.active_cat_ids

    def _broadcast_status(self, app_server: AppServer, state: DeviceState) -> None:
        update = app_pb.StatusUpdate(
            hopper_level=state.hopper_level,
            session_active=state.session_active,
            active_cat_ids=state.active_cat_ids,
            uptime_sec=int(time.monotonic() - state.boot_time),
            firmware_version=state.firmware_version,
        )
        app_server.broadcast(app_pb.DeviceEvent(status_update=update))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _bridge_dispatch(
    bridge: SessionBridge,
    msg: IncomingMessage,
) -> OutboundMessages | None:
    """Route an inbound IPC message to the matching bridge method.

    Returns the bridge's outbound batch or ``None`` for messages that
    produce no outbound work (or for malformed messages whose proto
    decode does not match the wire-type byte).
    """
    match msg.msg_type:
        case MsgType.DETECTION_FRAME:
            if isinstance(msg.message, det.DetectionFrame):
                return bridge.handle_detection_frame(msg.message)
        case MsgType.TRACK_EVENT:
            if isinstance(msg.message, det.TrackEvent):
                return bridge.handle_track_event(msg.message)
        case MsgType.SESSION_REQUEST:
            if isinstance(msg.message, det.SessionRequest):
                return bridge.handle_session_request(msg.message)
        case MsgType.STREAM_STATUS:
            if isinstance(msg.message, det.StreamStatus):
                bridge.handle_stream_status(msg.message)
            return None
        case _:
            _logger.warning("unexpected inbound msg_type: %s", msg.msg_type)
    return None


def _send_outgoing(ipc: IpcClient, outgoing: OutboundMessages) -> bool:
    """Ship every frame in an :class:`OutboundMessages` over IPC.

    Returns ``False`` if a send fails — the caller treats that as a
    broken connection and reconnects.
    """
    try:
        for cmd in outgoing.behavior_commands:
            ipc.send_behavior_command(cmd)
        for ack in outgoing.session_acks:
            ipc.send_session_ack(ack)
        for result in outgoing.identity_results:
            ipc.send_identity_result(result)
        for _ in range(outgoing.session_ends):
            ipc.send_session_end()
    except (ConnectionError, OSError):
        return False
    return True


def _broadcast_session_summary(
    app_server: AppServer,
    finalized: SessionFinalized,
) -> None:
    summary = app_pb.SessionSummary(
        cat_ids=list(finalized.cat_ids),
        duration_sec=finalized.duration_sec,
        engagement_score=finalized.engagement_score,
        treats_dispensed=finalized.treats_dispensed,
        pounce_count=finalized.pounce_count,
        ended_at=finalized.ended_at,
    )
    app_server.broadcast(app_pb.DeviceEvent(session_summary=summary))


def _send_session_summary_push(
    push: PushNotifier,
    finalized: SessionFinalized,
) -> None:
    # The push payload only needs the high-level numbers; cat names
    # are looked up by the app from its local profile cache.
    push.notify_session_summary(
        cat_names=list(finalized.cat_ids),
        duration_sec=finalized.duration_sec,
        engagement_score=finalized.engagement_score,
        treats_dispensed=finalized.treats_dispensed,
        pounce_count=finalized.pounce_count,
    )


# Reference `socket` so the module-level import is visible to the type
# checker — we keep it imported because future TCP-tuning hooks (e.g.
# setting TCP_NODELAY on the listen socket from the orchestrator)
# belong here, and importing once at module load is preferable to a
# late import.
_ = socket
