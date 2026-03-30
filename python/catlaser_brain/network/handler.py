"""App API request dispatcher.

Pure request handler: receives ``AppRequest`` protobuf messages, performs
the appropriate database operations, and returns ``DeviceEvent`` responses.
No network I/O -- the server layer handles framing and transport.

Session control (start/stop) and hardware operations (streaming,
diagnostics) are delegated to callback protocols that the integration
layer provides when wiring the system together.
"""

from __future__ import annotations

import dataclasses
import time
import uuid
from typing import TYPE_CHECKING, Final, Protocol

from catlaser_brain.proto.catlaser.app.v1 import app_pb2 as pb
from catlaser_brain.storage.crud import (
    ScheduleEntryRow,
    delete_cat,
    get_play_history,
    list_cats,
    list_schedule,
    resolve_pending_cat,
    set_schedule,
    update_cat,
)

if TYPE_CHECKING:
    import sqlite3
    from collections.abc import Callable

# ---------------------------------------------------------------------------
# Error codes
# ---------------------------------------------------------------------------

_ERR_EMPTY_REQUEST: Final[int] = 1
_ERR_UNKNOWN_REQUEST: Final[int] = 2
_ERR_NOT_AVAILABLE: Final[int] = 3
_ERR_NOT_FOUND: Final[int] = 4

# ---------------------------------------------------------------------------
# ISO weekday (1-7) → proto DayOfWeek enum
# ---------------------------------------------------------------------------

_DAY_OF_WEEK_MAP: Final[dict[int, pb.DayOfWeek]] = {
    1: pb.DAY_OF_WEEK_MONDAY,
    2: pb.DAY_OF_WEEK_TUESDAY,
    3: pb.DAY_OF_WEEK_WEDNESDAY,
    4: pb.DAY_OF_WEEK_THURSDAY,
    5: pb.DAY_OF_WEEK_FRIDAY,
    6: pb.DAY_OF_WEEK_SATURDAY,
    7: pb.DAY_OF_WEEK_SUNDAY,
}


# ---------------------------------------------------------------------------
# Device state
# ---------------------------------------------------------------------------


@dataclasses.dataclass(slots=True)
class DeviceState:
    """Mutable device state read by the handler for status responses.

    Updated by the integration layer as the system runs. The handler
    reads but never writes these fields.

    Attributes:
        hopper_level: ``HopperLevel`` proto enum value.
        session_active: Whether a play session is currently running.
        active_cat_ids: Cat IDs involved in the current session.
        boot_time: ``time.monotonic()`` at startup, for uptime calculation.
        firmware_version: Firmware version string reported to the app.
    """

    hopper_level: pb.HopperLevel
    session_active: bool
    active_cat_ids: list[str]
    boot_time: float
    firmware_version: str


# ---------------------------------------------------------------------------
# Session control protocol
# ---------------------------------------------------------------------------


class SessionControl(Protocol):
    """Callback protocol for session lifecycle control.

    Implemented by the integration layer to wire app commands into the
    behavior engine. The handler invokes these methods when the app sends
    ``StartSessionRequest`` or ``StopSessionRequest``.
    """

    def start_session(self) -> None:
        """Request a manual play session start."""
        ...

    def stop_session(self) -> None:
        """Request graceful session end (lead-to-treat cooldown)."""
        ...


# ---------------------------------------------------------------------------
# Request handler
# ---------------------------------------------------------------------------


class RequestHandler:
    """Dispatches ``AppRequest`` messages to typed handler methods.

    Each oneof variant in ``AppRequest`` maps to an internal handler
    method via a dispatch table. Methods perform database operations
    through :mod:`~catlaser_brain.storage.crud` and return a
    ``DeviceEvent`` response with the matching ``request_id``.

    Args:
        conn: SQLite connection with ``row_factory = sqlite3.Row``.
        state: Shared mutable device state.
        session_control: Optional session lifecycle callbacks.
    """

    __slots__ = ("_conn", "_dispatch_table", "_session_control", "_state")

    def __init__(
        self,
        conn: sqlite3.Connection,
        state: DeviceState,
        session_control: SessionControl | None = None,
    ) -> None:
        self._conn = conn
        self._state = state
        self._session_control = session_control
        self._dispatch_table: dict[str, Callable[[pb.AppRequest], pb.DeviceEvent]] = {
            "get_status": self._on_get_status,
            "get_cat_profiles": self._on_get_cat_profiles,
            "update_cat_profile": self._on_update_cat_profile,
            "delete_cat_profile": self._on_delete_cat_profile,
            "get_play_history": self._on_get_play_history,
            "set_schedule": self._on_set_schedule,
            "get_schedule": self._on_get_schedule,
            "identify_new_cat": self._on_identify_new_cat,
            "start_session": self._on_start_session,
            "stop_session": self._on_stop_session,
            "start_stream": self._on_start_stream,
            "stop_stream": self._on_stop_stream,
            "run_diagnostic": self._on_run_diagnostic,
        }

    def handle(self, request: pb.AppRequest) -> pb.DeviceEvent:
        """Dispatch a request and return the corresponding event.

        The response's ``request_id`` is set to match the request's,
        allowing the app to correlate responses to in-flight requests.
        """
        event = self._dispatch(request)
        event.request_id = request.request_id
        return event

    # -------------------------------------------------------------------
    # Dispatch
    # -------------------------------------------------------------------

    def _dispatch(self, request: pb.AppRequest) -> pb.DeviceEvent:
        variant = request.WhichOneof("request")
        if variant is None:
            return _error(_ERR_EMPTY_REQUEST, "empty request")
        handler = self._dispatch_table.get(variant)
        if handler is None:
            return _error(_ERR_UNKNOWN_REQUEST, f"unknown request: {variant}")
        return handler(request)

    # -------------------------------------------------------------------
    # Status
    # -------------------------------------------------------------------

    def _on_get_status(self, _request: pb.AppRequest) -> pb.DeviceEvent:
        return pb.DeviceEvent(status_update=self._build_status())

    def _build_status(self) -> pb.StatusUpdate:
        s = self._state
        return pb.StatusUpdate(
            hopper_level=s.hopper_level,
            session_active=s.session_active,
            active_cat_ids=s.active_cat_ids,
            uptime_sec=int(time.monotonic() - s.boot_time),
            firmware_version=s.firmware_version,
        )

    # -------------------------------------------------------------------
    # Cat profiles
    # -------------------------------------------------------------------

    def _on_get_cat_profiles(self, _request: pb.AppRequest) -> pb.DeviceEvent:
        return pb.DeviceEvent(cat_profile_list=self._build_cat_list())

    def _on_update_cat_profile(self, request: pb.AppRequest) -> pb.DeviceEvent:
        profile = request.update_cat_profile.profile
        name = profile.name or None
        thumbnail = profile.thumbnail or None
        try:
            update_cat(self._conn, profile.cat_id, name=name, thumbnail=thumbnail)
        except LookupError:
            return _error(_ERR_NOT_FOUND, f"cat {profile.cat_id} not found")
        return pb.DeviceEvent(cat_profile_list=self._build_cat_list())

    def _on_delete_cat_profile(self, request: pb.AppRequest) -> pb.DeviceEvent:
        delete_cat(self._conn, request.delete_cat_profile.cat_id)
        return pb.DeviceEvent(cat_profile_list=self._build_cat_list())

    def _build_cat_list(self) -> pb.CatProfileList:
        cats = list_cats(self._conn)
        profiles = [
            pb.CatProfile(
                cat_id=c.cat_id,
                name=c.name,
                thumbnail=c.thumbnail,
                preferred_speed=c.preferred_speed,
                preferred_smoothing=c.preferred_smoothing,
                pattern_randomness=c.pattern_randomness,
                total_sessions=c.total_sessions,
                total_play_time_sec=c.total_play_time_sec,
                total_treats=c.total_treats,
                created_at=c.created_at,
            )
            for c in cats
        ]
        return pb.CatProfileList(profiles=profiles)

    # -------------------------------------------------------------------
    # Play history
    # -------------------------------------------------------------------

    def _on_get_play_history(self, request: pb.AppRequest) -> pb.DeviceEvent:
        req = request.get_play_history
        sessions = get_play_history(self._conn, req.start_time, req.end_time)
        proto_sessions = [
            pb.PlaySession(
                session_id=s.session_id,
                start_time=s.start_time,
                end_time=s.end_time,
                cat_ids=list(s.cat_ids),
                duration_sec=s.duration_sec,
                engagement_score=s.engagement_score,
                treats_dispensed=s.treats_dispensed,
                pounce_count=s.pounce_count,
            )
            for s in sessions
        ]
        return pb.DeviceEvent(
            play_history=pb.PlayHistoryResponse(sessions=proto_sessions),
        )

    # -------------------------------------------------------------------
    # Schedule
    # -------------------------------------------------------------------

    def _on_set_schedule(self, request: pb.AppRequest) -> pb.DeviceEvent:
        entries = [
            ScheduleEntryRow(
                entry_id=e.entry_id,
                start_minute=e.start_minute,
                duration_min=e.duration_min,
                days=tuple(int(d) for d in e.days),
                enabled=e.enabled,
            )
            for e in request.set_schedule.entries
        ]
        set_schedule(self._conn, entries)
        return pb.DeviceEvent(schedule=self._build_schedule_list())

    def _on_get_schedule(self, _request: pb.AppRequest) -> pb.DeviceEvent:
        return pb.DeviceEvent(schedule=self._build_schedule_list())

    def _build_schedule_list(self) -> pb.ScheduleList:
        entries = list_schedule(self._conn)
        proto_entries = [
            pb.ScheduleEntry(
                entry_id=e.entry_id,
                start_minute=e.start_minute,
                duration_min=e.duration_min,
                days=[_DAY_OF_WEEK_MAP[d] for d in e.days],
                enabled=e.enabled,
            )
            for e in entries
        ]
        return pb.ScheduleList(entries=proto_entries)

    # -------------------------------------------------------------------
    # Cat identification
    # -------------------------------------------------------------------

    def _on_identify_new_cat(self, request: pb.AppRequest) -> pb.DeviceEvent:
        req = request.identify_new_cat
        cat_id = str(uuid.uuid4())
        try:
            resolve_pending_cat(self._conn, req.track_id_hint, cat_id, req.name)
        except LookupError:
            return _error(
                _ERR_NOT_FOUND,
                f"no pending cat with track_id_hint {req.track_id_hint}",
            )
        return pb.DeviceEvent(cat_profile_list=self._build_cat_list())

    # -------------------------------------------------------------------
    # Session control
    # -------------------------------------------------------------------

    def _on_start_session(self, _request: pb.AppRequest) -> pb.DeviceEvent:
        if self._session_control is None:
            return _error(_ERR_NOT_AVAILABLE, "session control not available")
        self._session_control.start_session()
        return pb.DeviceEvent(status_update=self._build_status())

    def _on_stop_session(self, _request: pb.AppRequest) -> pb.DeviceEvent:
        if self._session_control is None:
            return _error(_ERR_NOT_AVAILABLE, "session control not available")
        self._session_control.stop_session()
        return pb.DeviceEvent(status_update=self._build_status())

    # -------------------------------------------------------------------
    # Stubs (implemented in later build steps)
    # -------------------------------------------------------------------

    def _on_start_stream(self, _request: pb.AppRequest) -> pb.DeviceEvent:
        return _error(_ERR_NOT_AVAILABLE, "streaming not yet implemented")

    def _on_stop_stream(self, _request: pb.AppRequest) -> pb.DeviceEvent:
        return _error(_ERR_NOT_AVAILABLE, "streaming not yet implemented")

    def _on_run_diagnostic(self, _request: pb.AppRequest) -> pb.DeviceEvent:
        return _error(_ERR_NOT_AVAILABLE, "diagnostics not yet implemented")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _error(code: int, message: str) -> pb.DeviceEvent:
    return pb.DeviceEvent(error=pb.DeviceError(code=code, message=message))
