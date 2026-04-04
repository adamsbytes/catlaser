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

DAY_OF_WEEK_FRIDAY: DayOfWeek
DAY_OF_WEEK_MONDAY: DayOfWeek
DAY_OF_WEEK_SATURDAY: DayOfWeek
DAY_OF_WEEK_SUNDAY: DayOfWeek
DAY_OF_WEEK_THURSDAY: DayOfWeek
DAY_OF_WEEK_TUESDAY: DayOfWeek
DAY_OF_WEEK_UNSPECIFIED: DayOfWeek
DAY_OF_WEEK_WEDNESDAY: DayOfWeek
DESCRIPTOR: _descriptor.FileDescriptor
DIAGNOSTIC_TYPE_CAMERA_CHECK: DiagnosticType
DIAGNOSTIC_TYPE_DISPENSER_CYCLE: DiagnosticType
DIAGNOSTIC_TYPE_FULL: DiagnosticType
DIAGNOSTIC_TYPE_LASER_TEST: DiagnosticType
DIAGNOSTIC_TYPE_SERVO_SWEEP: DiagnosticType
DIAGNOSTIC_TYPE_UNSPECIFIED: DiagnosticType
HOPPER_LEVEL_EMPTY: HopperLevel
HOPPER_LEVEL_LOW: HopperLevel
HOPPER_LEVEL_OK: HopperLevel
HOPPER_LEVEL_UNSPECIFIED: HopperLevel
PUSH_PLATFORM_APNS: PushPlatform
PUSH_PLATFORM_FCM: PushPlatform
PUSH_PLATFORM_UNSPECIFIED: PushPlatform

class AppRequest(_message.Message):
    __slots__ = [
        "delete_cat_profile",
        "get_cat_profiles",
        "get_play_history",
        "get_schedule",
        "get_status",
        "identify_new_cat",
        "register_push_token",
        "request_id",
        "run_diagnostic",
        "set_schedule",
        "start_session",
        "start_stream",
        "stop_session",
        "stop_stream",
        "unregister_push_token",
        "update_cat_profile",
    ]
    DELETE_CAT_PROFILE_FIELD_NUMBER: _ClassVar[int]
    GET_CAT_PROFILES_FIELD_NUMBER: _ClassVar[int]
    GET_PLAY_HISTORY_FIELD_NUMBER: _ClassVar[int]
    GET_SCHEDULE_FIELD_NUMBER: _ClassVar[int]
    GET_STATUS_FIELD_NUMBER: _ClassVar[int]
    IDENTIFY_NEW_CAT_FIELD_NUMBER: _ClassVar[int]
    REGISTER_PUSH_TOKEN_FIELD_NUMBER: _ClassVar[int]
    REQUEST_ID_FIELD_NUMBER: _ClassVar[int]
    RUN_DIAGNOSTIC_FIELD_NUMBER: _ClassVar[int]
    SET_SCHEDULE_FIELD_NUMBER: _ClassVar[int]
    START_SESSION_FIELD_NUMBER: _ClassVar[int]
    START_STREAM_FIELD_NUMBER: _ClassVar[int]
    STOP_SESSION_FIELD_NUMBER: _ClassVar[int]
    STOP_STREAM_FIELD_NUMBER: _ClassVar[int]
    UNREGISTER_PUSH_TOKEN_FIELD_NUMBER: _ClassVar[int]
    UPDATE_CAT_PROFILE_FIELD_NUMBER: _ClassVar[int]
    delete_cat_profile: DeleteCatProfileRequest
    get_cat_profiles: GetCatProfilesRequest
    get_play_history: GetPlayHistoryRequest
    get_schedule: GetScheduleRequest
    get_status: GetStatusRequest
    identify_new_cat: IdentifyNewCatRequest
    register_push_token: RegisterPushTokenRequest
    request_id: int
    run_diagnostic: RunDiagnosticRequest
    set_schedule: SetScheduleRequest
    start_session: StartSessionRequest
    start_stream: StartStreamRequest
    stop_session: StopSessionRequest
    stop_stream: StopStreamRequest
    unregister_push_token: UnregisterPushTokenRequest
    update_cat_profile: UpdateCatProfileRequest
    def __init__(
        self,
        request_id: _Optional[int] = ...,
        start_session: _Optional[_Union[StartSessionRequest, _Mapping]] = ...,
        stop_session: _Optional[_Union[StopSessionRequest, _Mapping]] = ...,
        get_status: _Optional[_Union[GetStatusRequest, _Mapping]] = ...,
        get_cat_profiles: _Optional[_Union[GetCatProfilesRequest, _Mapping]] = ...,
        update_cat_profile: _Optional[_Union[UpdateCatProfileRequest, _Mapping]] = ...,
        delete_cat_profile: _Optional[_Union[DeleteCatProfileRequest, _Mapping]] = ...,
        get_play_history: _Optional[_Union[GetPlayHistoryRequest, _Mapping]] = ...,
        start_stream: _Optional[_Union[StartStreamRequest, _Mapping]] = ...,
        stop_stream: _Optional[_Union[StopStreamRequest, _Mapping]] = ...,
        set_schedule: _Optional[_Union[SetScheduleRequest, _Mapping]] = ...,
        identify_new_cat: _Optional[_Union[IdentifyNewCatRequest, _Mapping]] = ...,
        run_diagnostic: _Optional[_Union[RunDiagnosticRequest, _Mapping]] = ...,
        get_schedule: _Optional[_Union[GetScheduleRequest, _Mapping]] = ...,
        register_push_token: _Optional[_Union[RegisterPushTokenRequest, _Mapping]] = ...,
        unregister_push_token: _Optional[_Union[UnregisterPushTokenRequest, _Mapping]] = ...,
    ) -> None: ...

class CatProfile(_message.Message):
    __slots__ = [
        "cat_id",
        "created_at",
        "name",
        "pattern_randomness",
        "preferred_smoothing",
        "preferred_speed",
        "thumbnail",
        "total_play_time_sec",
        "total_sessions",
        "total_treats",
    ]
    CAT_ID_FIELD_NUMBER: _ClassVar[int]
    CREATED_AT_FIELD_NUMBER: _ClassVar[int]
    NAME_FIELD_NUMBER: _ClassVar[int]
    PATTERN_RANDOMNESS_FIELD_NUMBER: _ClassVar[int]
    PREFERRED_SMOOTHING_FIELD_NUMBER: _ClassVar[int]
    PREFERRED_SPEED_FIELD_NUMBER: _ClassVar[int]
    THUMBNAIL_FIELD_NUMBER: _ClassVar[int]
    TOTAL_PLAY_TIME_SEC_FIELD_NUMBER: _ClassVar[int]
    TOTAL_SESSIONS_FIELD_NUMBER: _ClassVar[int]
    TOTAL_TREATS_FIELD_NUMBER: _ClassVar[int]
    cat_id: str
    created_at: int
    name: str
    pattern_randomness: float
    preferred_smoothing: float
    preferred_speed: float
    thumbnail: bytes
    total_play_time_sec: int
    total_sessions: int
    total_treats: int
    def __init__(
        self,
        cat_id: _Optional[str] = ...,
        name: _Optional[str] = ...,
        thumbnail: _Optional[bytes] = ...,
        preferred_speed: _Optional[float] = ...,
        preferred_smoothing: _Optional[float] = ...,
        pattern_randomness: _Optional[float] = ...,
        total_sessions: _Optional[int] = ...,
        total_play_time_sec: _Optional[int] = ...,
        total_treats: _Optional[int] = ...,
        created_at: _Optional[int] = ...,
    ) -> None: ...

class CatProfileList(_message.Message):
    __slots__ = ["profiles"]
    PROFILES_FIELD_NUMBER: _ClassVar[int]
    profiles: _containers.RepeatedCompositeFieldContainer[CatProfile]
    def __init__(
        self, profiles: _Optional[_Iterable[_Union[CatProfile, _Mapping]]] = ...
    ) -> None: ...

class DeleteCatProfileRequest(_message.Message):
    __slots__ = ["cat_id"]
    CAT_ID_FIELD_NUMBER: _ClassVar[int]
    cat_id: str
    def __init__(self, cat_id: _Optional[str] = ...) -> None: ...

class DeviceError(_message.Message):
    __slots__ = ["code", "message"]
    CODE_FIELD_NUMBER: _ClassVar[int]
    MESSAGE_FIELD_NUMBER: _ClassVar[int]
    code: int
    message: str
    def __init__(self, code: _Optional[int] = ..., message: _Optional[str] = ...) -> None: ...

class DeviceEvent(_message.Message):
    __slots__ = [
        "cat_profile_list",
        "diagnostic_result",
        "error",
        "hopper_empty",
        "new_cat_detected",
        "play_history",
        "push_token_ack",
        "request_id",
        "schedule",
        "session_summary",
        "status_update",
        "stream_offer",
    ]
    CAT_PROFILE_LIST_FIELD_NUMBER: _ClassVar[int]
    DIAGNOSTIC_RESULT_FIELD_NUMBER: _ClassVar[int]
    ERROR_FIELD_NUMBER: _ClassVar[int]
    HOPPER_EMPTY_FIELD_NUMBER: _ClassVar[int]
    NEW_CAT_DETECTED_FIELD_NUMBER: _ClassVar[int]
    PLAY_HISTORY_FIELD_NUMBER: _ClassVar[int]
    PUSH_TOKEN_ACK_FIELD_NUMBER: _ClassVar[int]
    REQUEST_ID_FIELD_NUMBER: _ClassVar[int]
    SCHEDULE_FIELD_NUMBER: _ClassVar[int]
    SESSION_SUMMARY_FIELD_NUMBER: _ClassVar[int]
    STATUS_UPDATE_FIELD_NUMBER: _ClassVar[int]
    STREAM_OFFER_FIELD_NUMBER: _ClassVar[int]
    cat_profile_list: CatProfileList
    diagnostic_result: DiagnosticResult
    error: DeviceError
    hopper_empty: HopperEmpty
    new_cat_detected: NewCatDetected
    play_history: PlayHistoryResponse
    push_token_ack: PushTokenAck
    request_id: int
    schedule: ScheduleList
    session_summary: SessionSummary
    status_update: StatusUpdate
    stream_offer: StreamOffer
    def __init__(
        self,
        request_id: _Optional[int] = ...,
        status_update: _Optional[_Union[StatusUpdate, _Mapping]] = ...,
        cat_profile_list: _Optional[_Union[CatProfileList, _Mapping]] = ...,
        play_history: _Optional[_Union[PlayHistoryResponse, _Mapping]] = ...,
        stream_offer: _Optional[_Union[StreamOffer, _Mapping]] = ...,
        session_summary: _Optional[_Union[SessionSummary, _Mapping]] = ...,
        new_cat_detected: _Optional[_Union[NewCatDetected, _Mapping]] = ...,
        hopper_empty: _Optional[_Union[HopperEmpty, _Mapping]] = ...,
        diagnostic_result: _Optional[_Union[DiagnosticResult, _Mapping]] = ...,
        error: _Optional[_Union[DeviceError, _Mapping]] = ...,
        schedule: _Optional[_Union[ScheduleList, _Mapping]] = ...,
        push_token_ack: _Optional[_Union[PushTokenAck, _Mapping]] = ...,
    ) -> None: ...

class DiagnosticResult(_message.Message):
    __slots__ = ["details", "diagnostic_type", "passed"]
    DETAILS_FIELD_NUMBER: _ClassVar[int]
    DIAGNOSTIC_TYPE_FIELD_NUMBER: _ClassVar[int]
    PASSED_FIELD_NUMBER: _ClassVar[int]
    details: str
    diagnostic_type: DiagnosticType
    passed: bool
    def __init__(
        self,
        diagnostic_type: _Optional[_Union[DiagnosticType, str]] = ...,
        passed: bool = ...,
        details: _Optional[str] = ...,
    ) -> None: ...

class GetCatProfilesRequest(_message.Message):
    __slots__ = []
    def __init__(self) -> None: ...

class GetPlayHistoryRequest(_message.Message):
    __slots__ = ["end_time", "start_time"]
    END_TIME_FIELD_NUMBER: _ClassVar[int]
    START_TIME_FIELD_NUMBER: _ClassVar[int]
    end_time: int
    start_time: int
    def __init__(
        self, start_time: _Optional[int] = ..., end_time: _Optional[int] = ...
    ) -> None: ...

class GetScheduleRequest(_message.Message):
    __slots__ = []
    def __init__(self) -> None: ...

class GetStatusRequest(_message.Message):
    __slots__ = []
    def __init__(self) -> None: ...

class HopperEmpty(_message.Message):
    __slots__ = []
    def __init__(self) -> None: ...

class IdentifyNewCatRequest(_message.Message):
    __slots__ = ["name", "track_id_hint"]
    NAME_FIELD_NUMBER: _ClassVar[int]
    TRACK_ID_HINT_FIELD_NUMBER: _ClassVar[int]
    name: str
    track_id_hint: int
    def __init__(
        self, track_id_hint: _Optional[int] = ..., name: _Optional[str] = ...
    ) -> None: ...

class NewCatDetected(_message.Message):
    __slots__ = ["confidence", "thumbnail", "track_id_hint"]
    CONFIDENCE_FIELD_NUMBER: _ClassVar[int]
    THUMBNAIL_FIELD_NUMBER: _ClassVar[int]
    TRACK_ID_HINT_FIELD_NUMBER: _ClassVar[int]
    confidence: float
    thumbnail: bytes
    track_id_hint: int
    def __init__(
        self,
        track_id_hint: _Optional[int] = ...,
        thumbnail: _Optional[bytes] = ...,
        confidence: _Optional[float] = ...,
    ) -> None: ...

class PlayHistoryResponse(_message.Message):
    __slots__ = ["sessions"]
    SESSIONS_FIELD_NUMBER: _ClassVar[int]
    sessions: _containers.RepeatedCompositeFieldContainer[PlaySession]
    def __init__(
        self, sessions: _Optional[_Iterable[_Union[PlaySession, _Mapping]]] = ...
    ) -> None: ...

class PlaySession(_message.Message):
    __slots__ = [
        "cat_ids",
        "duration_sec",
        "end_time",
        "engagement_score",
        "pounce_count",
        "session_id",
        "start_time",
        "treats_dispensed",
    ]
    CAT_IDS_FIELD_NUMBER: _ClassVar[int]
    DURATION_SEC_FIELD_NUMBER: _ClassVar[int]
    END_TIME_FIELD_NUMBER: _ClassVar[int]
    ENGAGEMENT_SCORE_FIELD_NUMBER: _ClassVar[int]
    POUNCE_COUNT_FIELD_NUMBER: _ClassVar[int]
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    START_TIME_FIELD_NUMBER: _ClassVar[int]
    TREATS_DISPENSED_FIELD_NUMBER: _ClassVar[int]
    cat_ids: _containers.RepeatedScalarFieldContainer[str]
    duration_sec: int
    end_time: int
    engagement_score: float
    pounce_count: int
    session_id: str
    start_time: int
    treats_dispensed: int
    def __init__(
        self,
        session_id: _Optional[str] = ...,
        start_time: _Optional[int] = ...,
        end_time: _Optional[int] = ...,
        cat_ids: _Optional[_Iterable[str]] = ...,
        duration_sec: _Optional[int] = ...,
        engagement_score: _Optional[float] = ...,
        treats_dispensed: _Optional[int] = ...,
        pounce_count: _Optional[int] = ...,
    ) -> None: ...

class PushTokenAck(_message.Message):
    __slots__ = []
    def __init__(self) -> None: ...

class RegisterPushTokenRequest(_message.Message):
    __slots__ = ["platform", "token"]
    PLATFORM_FIELD_NUMBER: _ClassVar[int]
    TOKEN_FIELD_NUMBER: _ClassVar[int]
    platform: PushPlatform
    token: str
    def __init__(
        self, token: _Optional[str] = ..., platform: _Optional[_Union[PushPlatform, str]] = ...
    ) -> None: ...

class RunDiagnosticRequest(_message.Message):
    __slots__ = ["diagnostic_type"]
    DIAGNOSTIC_TYPE_FIELD_NUMBER: _ClassVar[int]
    diagnostic_type: DiagnosticType
    def __init__(self, diagnostic_type: _Optional[_Union[DiagnosticType, str]] = ...) -> None: ...

class ScheduleEntry(_message.Message):
    __slots__ = ["days", "duration_min", "enabled", "entry_id", "start_minute"]
    DAYS_FIELD_NUMBER: _ClassVar[int]
    DURATION_MIN_FIELD_NUMBER: _ClassVar[int]
    ENABLED_FIELD_NUMBER: _ClassVar[int]
    ENTRY_ID_FIELD_NUMBER: _ClassVar[int]
    START_MINUTE_FIELD_NUMBER: _ClassVar[int]
    days: _containers.RepeatedScalarFieldContainer[DayOfWeek]
    duration_min: int
    enabled: bool
    entry_id: str
    start_minute: int
    def __init__(
        self,
        entry_id: _Optional[str] = ...,
        start_minute: _Optional[int] = ...,
        duration_min: _Optional[int] = ...,
        days: _Optional[_Iterable[_Union[DayOfWeek, str]]] = ...,
        enabled: bool = ...,
    ) -> None: ...

class ScheduleList(_message.Message):
    __slots__ = ["entries"]
    ENTRIES_FIELD_NUMBER: _ClassVar[int]
    entries: _containers.RepeatedCompositeFieldContainer[ScheduleEntry]
    def __init__(
        self, entries: _Optional[_Iterable[_Union[ScheduleEntry, _Mapping]]] = ...
    ) -> None: ...

class SessionSummary(_message.Message):
    __slots__ = [
        "cat_ids",
        "duration_sec",
        "ended_at",
        "engagement_score",
        "pounce_count",
        "treats_dispensed",
    ]
    CAT_IDS_FIELD_NUMBER: _ClassVar[int]
    DURATION_SEC_FIELD_NUMBER: _ClassVar[int]
    ENDED_AT_FIELD_NUMBER: _ClassVar[int]
    ENGAGEMENT_SCORE_FIELD_NUMBER: _ClassVar[int]
    POUNCE_COUNT_FIELD_NUMBER: _ClassVar[int]
    TREATS_DISPENSED_FIELD_NUMBER: _ClassVar[int]
    cat_ids: _containers.RepeatedScalarFieldContainer[str]
    duration_sec: int
    ended_at: int
    engagement_score: float
    pounce_count: int
    treats_dispensed: int
    def __init__(
        self,
        cat_ids: _Optional[_Iterable[str]] = ...,
        duration_sec: _Optional[int] = ...,
        engagement_score: _Optional[float] = ...,
        treats_dispensed: _Optional[int] = ...,
        pounce_count: _Optional[int] = ...,
        ended_at: _Optional[int] = ...,
    ) -> None: ...

class SetScheduleRequest(_message.Message):
    __slots__ = ["entries"]
    ENTRIES_FIELD_NUMBER: _ClassVar[int]
    entries: _containers.RepeatedCompositeFieldContainer[ScheduleEntry]
    def __init__(
        self, entries: _Optional[_Iterable[_Union[ScheduleEntry, _Mapping]]] = ...
    ) -> None: ...

class StartSessionRequest(_message.Message):
    __slots__ = []
    def __init__(self) -> None: ...

class StartStreamRequest(_message.Message):
    __slots__ = []
    def __init__(self) -> None: ...

class StatusUpdate(_message.Message):
    __slots__ = [
        "active_cat_ids",
        "firmware_version",
        "hopper_level",
        "session_active",
        "uptime_sec",
    ]
    ACTIVE_CAT_IDS_FIELD_NUMBER: _ClassVar[int]
    FIRMWARE_VERSION_FIELD_NUMBER: _ClassVar[int]
    HOPPER_LEVEL_FIELD_NUMBER: _ClassVar[int]
    SESSION_ACTIVE_FIELD_NUMBER: _ClassVar[int]
    UPTIME_SEC_FIELD_NUMBER: _ClassVar[int]
    active_cat_ids: _containers.RepeatedScalarFieldContainer[str]
    firmware_version: str
    hopper_level: HopperLevel
    session_active: bool
    uptime_sec: int
    def __init__(
        self,
        hopper_level: _Optional[_Union[HopperLevel, str]] = ...,
        session_active: bool = ...,
        active_cat_ids: _Optional[_Iterable[str]] = ...,
        uptime_sec: _Optional[int] = ...,
        firmware_version: _Optional[str] = ...,
    ) -> None: ...

class StopSessionRequest(_message.Message):
    __slots__ = []
    def __init__(self) -> None: ...

class StopStreamRequest(_message.Message):
    __slots__ = []
    def __init__(self) -> None: ...

class StreamOffer(_message.Message):
    __slots__ = ["livekit_url", "subscriber_token"]
    LIVEKIT_URL_FIELD_NUMBER: _ClassVar[int]
    SUBSCRIBER_TOKEN_FIELD_NUMBER: _ClassVar[int]
    livekit_url: str
    subscriber_token: str
    def __init__(
        self, livekit_url: _Optional[str] = ..., subscriber_token: _Optional[str] = ...
    ) -> None: ...

class UnregisterPushTokenRequest(_message.Message):
    __slots__ = ["token"]
    TOKEN_FIELD_NUMBER: _ClassVar[int]
    token: str
    def __init__(self, token: _Optional[str] = ...) -> None: ...

class UpdateCatProfileRequest(_message.Message):
    __slots__ = ["profile"]
    PROFILE_FIELD_NUMBER: _ClassVar[int]
    profile: CatProfile
    def __init__(self, profile: _Optional[_Union[CatProfile, _Mapping]] = ...) -> None: ...

class HopperLevel(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = []

class DiagnosticType(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = []

class PushPlatform(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = []

class DayOfWeek(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = []
