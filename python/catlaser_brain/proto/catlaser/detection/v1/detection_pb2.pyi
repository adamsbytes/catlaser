from google.protobuf.internal import containers as _containers
from google.protobuf.internal import enum_type_wrapper as _enum_type_wrapper
from google.protobuf import descriptor as _descriptor
from google.protobuf import message as _message
from typing import (
    ClassVar as _ClassVar,
    Iterable as _Iterable,
    Mapping as _Mapping,
    Optional as _Optional,
    Union as _Union,
)

DESCRIPTOR: _descriptor.FileDescriptor
MSG_TYPE_BEHAVIOR_COMMAND: MsgType
MSG_TYPE_DETECTION_FRAME: MsgType
MSG_TYPE_IDENTITY_RESULT: MsgType
MSG_TYPE_SESSION_ACK: MsgType
MSG_TYPE_SESSION_END: MsgType
MSG_TYPE_SESSION_REQUEST: MsgType
MSG_TYPE_STREAM_CONTROL: MsgType
MSG_TYPE_STREAM_STATUS: MsgType
MSG_TYPE_TRACK_EVENT: MsgType
MSG_TYPE_UNSPECIFIED: MsgType
SESSION_TRIGGER_CAT_DETECTED: SessionTrigger
SESSION_TRIGGER_SCHEDULED: SessionTrigger
SESSION_TRIGGER_UNSPECIFIED: SessionTrigger
SKIP_REASON_COOLDOWN: SkipReason
SKIP_REASON_HOPPER_EMPTY: SkipReason
SKIP_REASON_QUIET_HOURS: SkipReason
SKIP_REASON_UNSPECIFIED: SkipReason
STREAM_ACTION_START: StreamAction
STREAM_ACTION_STOP: StreamAction
STREAM_ACTION_UNSPECIFIED: StreamAction
STREAM_STATE_CONNECTING: StreamState
STREAM_STATE_ERROR: StreamState
STREAM_STATE_PUBLISHING: StreamState
STREAM_STATE_STOPPED: StreamState
STREAM_STATE_UNSPECIFIED: StreamState
TARGETING_MODE_DISPENSE: TargetingMode
TARGETING_MODE_IDLE: TargetingMode
TARGETING_MODE_LEAD_TO_POINT: TargetingMode
TARGETING_MODE_TRACK: TargetingMode
TARGETING_MODE_UNSPECIFIED: TargetingMode
TRACK_STATE_COASTING: TrackState
TRACK_STATE_CONFIRMED: TrackState
TRACK_STATE_TENTATIVE: TrackState
TRACK_STATE_UNSPECIFIED: TrackState

class BehaviorCommand(_message.Message):
    __slots__ = [
        "dispense_rotations",
        "laser_on",
        "lead_target_x",
        "lead_target_y",
        "max_speed",
        "mode",
        "offset_x",
        "offset_y",
        "smoothing",
        "target_track_id",
    ]
    DISPENSE_ROTATIONS_FIELD_NUMBER: _ClassVar[int]
    LASER_ON_FIELD_NUMBER: _ClassVar[int]
    LEAD_TARGET_X_FIELD_NUMBER: _ClassVar[int]
    LEAD_TARGET_Y_FIELD_NUMBER: _ClassVar[int]
    MAX_SPEED_FIELD_NUMBER: _ClassVar[int]
    MODE_FIELD_NUMBER: _ClassVar[int]
    OFFSET_X_FIELD_NUMBER: _ClassVar[int]
    OFFSET_Y_FIELD_NUMBER: _ClassVar[int]
    SMOOTHING_FIELD_NUMBER: _ClassVar[int]
    TARGET_TRACK_ID_FIELD_NUMBER: _ClassVar[int]
    dispense_rotations: int
    laser_on: bool
    lead_target_x: float
    lead_target_y: float
    max_speed: float
    mode: TargetingMode
    offset_x: float
    offset_y: float
    smoothing: float
    target_track_id: int
    def __init__(
        self,
        mode: _Optional[_Union[TargetingMode, str]] = ...,
        offset_x: _Optional[float] = ...,
        offset_y: _Optional[float] = ...,
        smoothing: _Optional[float] = ...,
        max_speed: _Optional[float] = ...,
        laser_on: bool = ...,
        target_track_id: _Optional[int] = ...,
        lead_target_x: _Optional[float] = ...,
        lead_target_y: _Optional[float] = ...,
        dispense_rotations: _Optional[int] = ...,
    ) -> None: ...

class DetectionFrame(_message.Message):
    __slots__ = [
        "ambient_brightness",
        "cats",
        "frame_number",
        "person_in_frame",
        "safety_ceiling_y",
        "timestamp_us",
    ]
    AMBIENT_BRIGHTNESS_FIELD_NUMBER: _ClassVar[int]
    CATS_FIELD_NUMBER: _ClassVar[int]
    FRAME_NUMBER_FIELD_NUMBER: _ClassVar[int]
    PERSON_IN_FRAME_FIELD_NUMBER: _ClassVar[int]
    SAFETY_CEILING_Y_FIELD_NUMBER: _ClassVar[int]
    TIMESTAMP_US_FIELD_NUMBER: _ClassVar[int]
    ambient_brightness: float
    cats: _containers.RepeatedCompositeFieldContainer[TrackedCat]
    frame_number: int
    person_in_frame: bool
    safety_ceiling_y: float
    timestamp_us: int
    def __init__(
        self,
        timestamp_us: _Optional[int] = ...,
        frame_number: _Optional[int] = ...,
        cats: _Optional[_Iterable[_Union[TrackedCat, _Mapping]]] = ...,
        safety_ceiling_y: _Optional[float] = ...,
        person_in_frame: bool = ...,
        ambient_brightness: _Optional[float] = ...,
    ) -> None: ...

class IdentityRequest(_message.Message):
    __slots__ = ["confidence", "embedding", "track_id"]
    CONFIDENCE_FIELD_NUMBER: _ClassVar[int]
    EMBEDDING_FIELD_NUMBER: _ClassVar[int]
    TRACK_ID_FIELD_NUMBER: _ClassVar[int]
    confidence: float
    embedding: bytes
    track_id: int
    def __init__(
        self,
        track_id: _Optional[int] = ...,
        embedding: _Optional[bytes] = ...,
        confidence: _Optional[float] = ...,
    ) -> None: ...

class IdentityResult(_message.Message):
    __slots__ = ["cat_id", "similarity", "track_id"]
    CAT_ID_FIELD_NUMBER: _ClassVar[int]
    SIMILARITY_FIELD_NUMBER: _ClassVar[int]
    TRACK_ID_FIELD_NUMBER: _ClassVar[int]
    cat_id: str
    similarity: float
    track_id: int
    def __init__(
        self,
        track_id: _Optional[int] = ...,
        cat_id: _Optional[str] = ...,
        similarity: _Optional[float] = ...,
    ) -> None: ...

class NewTrack(_message.Message):
    __slots__ = ["track_id"]
    TRACK_ID_FIELD_NUMBER: _ClassVar[int]
    track_id: int
    def __init__(self, track_id: _Optional[int] = ...) -> None: ...

class SessionAck(_message.Message):
    __slots__ = ["accept", "skip_reason"]
    ACCEPT_FIELD_NUMBER: _ClassVar[int]
    SKIP_REASON_FIELD_NUMBER: _ClassVar[int]
    accept: bool
    skip_reason: SkipReason
    def __init__(
        self, accept: bool = ..., skip_reason: _Optional[_Union[SkipReason, str]] = ...
    ) -> None: ...

class SessionEnd(_message.Message):
    __slots__ = []
    def __init__(self) -> None: ...

class SessionRequest(_message.Message):
    __slots__ = ["track_id", "trigger"]
    TRACK_ID_FIELD_NUMBER: _ClassVar[int]
    TRIGGER_FIELD_NUMBER: _ClassVar[int]
    track_id: int
    trigger: SessionTrigger
    def __init__(
        self, trigger: _Optional[_Union[SessionTrigger, str]] = ..., track_id: _Optional[int] = ...
    ) -> None: ...

class StreamControl(_message.Message):
    __slots__ = ["action", "livekit_url", "publisher_token", "room_name", "target_bitrate_bps"]
    ACTION_FIELD_NUMBER: _ClassVar[int]
    LIVEKIT_URL_FIELD_NUMBER: _ClassVar[int]
    PUBLISHER_TOKEN_FIELD_NUMBER: _ClassVar[int]
    ROOM_NAME_FIELD_NUMBER: _ClassVar[int]
    TARGET_BITRATE_BPS_FIELD_NUMBER: _ClassVar[int]
    action: StreamAction
    livekit_url: str
    publisher_token: str
    room_name: str
    target_bitrate_bps: int
    def __init__(
        self,
        action: _Optional[_Union[StreamAction, str]] = ...,
        livekit_url: _Optional[str] = ...,
        publisher_token: _Optional[str] = ...,
        room_name: _Optional[str] = ...,
        target_bitrate_bps: _Optional[int] = ...,
    ) -> None: ...

class StreamStatus(_message.Message):
    __slots__ = ["error_message", "state"]
    ERROR_MESSAGE_FIELD_NUMBER: _ClassVar[int]
    STATE_FIELD_NUMBER: _ClassVar[int]
    error_message: str
    state: StreamState
    def __init__(
        self, state: _Optional[_Union[StreamState, str]] = ..., error_message: _Optional[str] = ...
    ) -> None: ...

class TrackEvent(_message.Message):
    __slots__ = ["identity_request", "new_track", "track_lost"]
    IDENTITY_REQUEST_FIELD_NUMBER: _ClassVar[int]
    NEW_TRACK_FIELD_NUMBER: _ClassVar[int]
    TRACK_LOST_FIELD_NUMBER: _ClassVar[int]
    identity_request: IdentityRequest
    new_track: NewTrack
    track_lost: TrackLost
    def __init__(
        self,
        new_track: _Optional[_Union[NewTrack, _Mapping]] = ...,
        track_lost: _Optional[_Union[TrackLost, _Mapping]] = ...,
        identity_request: _Optional[_Union[IdentityRequest, _Mapping]] = ...,
    ) -> None: ...

class TrackLost(_message.Message):
    __slots__ = ["duration_ms", "track_id"]
    DURATION_MS_FIELD_NUMBER: _ClassVar[int]
    TRACK_ID_FIELD_NUMBER: _ClassVar[int]
    duration_ms: int
    track_id: int
    def __init__(
        self, track_id: _Optional[int] = ..., duration_ms: _Optional[int] = ...
    ) -> None: ...

class TrackedCat(_message.Message):
    __slots__ = [
        "cat_id",
        "center_x",
        "center_y",
        "height",
        "state",
        "track_id",
        "velocity_x",
        "velocity_y",
        "width",
    ]
    CAT_ID_FIELD_NUMBER: _ClassVar[int]
    CENTER_X_FIELD_NUMBER: _ClassVar[int]
    CENTER_Y_FIELD_NUMBER: _ClassVar[int]
    HEIGHT_FIELD_NUMBER: _ClassVar[int]
    STATE_FIELD_NUMBER: _ClassVar[int]
    TRACK_ID_FIELD_NUMBER: _ClassVar[int]
    VELOCITY_X_FIELD_NUMBER: _ClassVar[int]
    VELOCITY_Y_FIELD_NUMBER: _ClassVar[int]
    WIDTH_FIELD_NUMBER: _ClassVar[int]
    cat_id: str
    center_x: float
    center_y: float
    height: float
    state: TrackState
    track_id: int
    velocity_x: float
    velocity_y: float
    width: float
    def __init__(
        self,
        track_id: _Optional[int] = ...,
        cat_id: _Optional[str] = ...,
        center_x: _Optional[float] = ...,
        center_y: _Optional[float] = ...,
        width: _Optional[float] = ...,
        height: _Optional[float] = ...,
        velocity_x: _Optional[float] = ...,
        velocity_y: _Optional[float] = ...,
        state: _Optional[_Union[TrackState, str]] = ...,
    ) -> None: ...

class MsgType(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = []

class TrackState(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = []

class TargetingMode(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = []

class SkipReason(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = []

class SessionTrigger(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = []

class StreamAction(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = []

class StreamState(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = []
