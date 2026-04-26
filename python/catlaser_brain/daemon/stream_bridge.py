"""Bridge from the app handler's :class:`StreamNotify` to vision IPC.

Sits between :class:`RequestHandler` (which calls into ``StreamNotify``
when the app sends ``StartStreamRequest`` / ``StopStreamRequest``) and
:class:`IpcClient` (which ships ``StreamControl`` frames to the Rust
vision daemon over the Unix socket). The handler does not import the
IPC client directly so the wiring stays in the orchestrator.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from catlaser_brain.proto.catlaser.detection.v1 import detection_pb2 as det

if TYPE_CHECKING:
    from catlaser_brain.ipc.client import IpcClient
    from catlaser_brain.network.streaming import StreamCredentials

_logger = logging.getLogger(__name__)


class StreamBridge:
    """:class:`StreamNotify` implementation that forwards to vision IPC.

    The :class:`RequestHandler` invokes :meth:`on_stream_start` and
    :meth:`on_stream_stop` synchronously from the app server's poll
    thread. Both methods translate the call into a ``StreamControl``
    frame and send it over the IPC client. A failed send is logged but
    not raised — the app already received credentials, and the
    orchestrator's IPC reconnect loop will re-establish the channel.

    Args:
        ipc: IPC client connected to the Rust vision daemon. Mutates
            on reconnect; the bridge captures ``None`` paths gracefully.
    """

    __slots__ = ("_ipc",)

    def __init__(self, ipc: IpcClient | None) -> None:
        self._ipc = ipc

    def set_ipc(self, ipc: IpcClient | None) -> None:
        """Update the IPC client reference after a reconnect.

        Called by the orchestrator whenever the vision IPC connection
        is re-established (or torn down). Passing ``None`` makes
        subsequent ``on_stream_*`` calls log-and-drop rather than
        raise.
        """
        self._ipc = ipc

    def on_stream_start(self, credentials: StreamCredentials) -> None:
        """App requested a live stream; forward credentials to Rust.

        Builds a ``StreamControl`` frame with action START and the
        publisher token. Rust's pipeline initialises the RKMPI encoder
        and spawns the WebRTC publisher thread.
        """
        ctrl = det.StreamControl(
            action=det.STREAM_ACTION_START,
            livekit_url=credentials.livekit_url,
            publisher_token=credentials.publisher_token,
            room_name=credentials.room_name,
            target_bitrate_bps=credentials.target_bitrate_bps,
        )
        self._send(ctrl, "start")

    def on_stream_stop(self) -> None:
        """App requested stream stop; tell Rust to tear down the publisher."""
        ctrl = det.StreamControl(action=det.STREAM_ACTION_STOP)
        self._send(ctrl, "stop")

    def _send(self, ctrl: det.StreamControl, action: str) -> None:
        if self._ipc is None:
            _logger.warning(
                "stream %s requested but vision IPC is disconnected; "
                "Rust will not receive the control frame",
                action,
            )
            return
        try:
            self._ipc.send_stream_control(ctrl)
        except (ConnectionError, OSError):
            _logger.warning(
                "stream %s send failed; vision IPC is broken",
                action,
                exc_info=True,
            )
