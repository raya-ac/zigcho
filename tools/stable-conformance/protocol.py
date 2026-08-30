"""Bounded Bancho packet decoding for Stable differential conformance tests.

The wire decoder deliberately does not know how to connect to either server. It
turns an already captured byte stream into deterministic, JSON-safe values and
keeps byte offsets on every diagnostic so a runner can report the first real
divergence.

Normalization is opt-in and field-scoped. A rule names one direction, one
packet id, and one exact path inside that packet's semantic payload. There is no
whole-response substitution or regular-expression cleanup here.
"""

from __future__ import annotations

import copy
import hashlib
import json
import math
import struct
from dataclasses import dataclass
from typing import Any, Iterable, Literal, Mapping, Sequence


Direction = Literal["client", "server"]
PathPart = str | int
JSONValue = type(None) | bool | int | float | str | list["JSONValue"] | dict[str, "JSONValue"]

HEADER = struct.Struct("<HBI")
HEADER_SIZE = HEADER.size
DEFAULT_MAX_PAYLOAD_SIZE = 1024 * 1024
DEFAULT_MAX_PACKET_COUNT = 8192


CLIENT_PACKET_NAMES: dict[int, str] = {
    0: "change_action",
    1: "send_public_message",
    2: "logout",
    3: "request_status",
    4: "ping",
    16: "start_spectating",
    17: "stop_spectating",
    18: "spectate_frames",
    21: "cant_spectate",
    25: "send_private_message",
    29: "part_lobby",
    30: "join_lobby",
    31: "create_match",
    32: "join_match",
    33: "part_match",
    38: "change_slot",
    39: "match_ready",
    40: "match_lock",
    41: "match_change_settings",
    44: "match_start",
    47: "match_score_update",
    49: "match_complete",
    51: "match_change_mods",
    52: "match_load_complete",
    54: "match_no_beatmap",
    55: "match_not_ready",
    56: "match_failed",
    59: "match_has_beatmap",
    60: "match_skip_request",
    63: "channel_join",
    68: "beatmap_info_request",
    70: "match_transfer_host",
    73: "friend_add",
    74: "friend_remove",
    77: "match_change_team",
    78: "channel_part",
    79: "receive_updates",
    82: "set_away_message",
    84: "irc_only",
    85: "user_stats_request",
    87: "match_invite",
    90: "match_change_password",
    93: "tournament_match_info",
    97: "user_presence_request",
    98: "user_presence_request_all",
    99: "toggle_block_non_friend_dms",
    108: "tournament_join_match_channel",
    109: "tournament_leave_match_channel",
}

SERVER_PACKET_NAMES: dict[int, str] = {
    5: "user_id",
    7: "send_message",
    8: "pong",
    11: "user_stats",
    12: "user_logout",
    13: "spectator_joined",
    14: "spectator_left",
    15: "spectate_frames",
    22: "spectator_cant_spectate",
    24: "notification",
    26: "update_match",
    27: "new_match",
    28: "dispose_match",
    34: "toggle_block_non_friend_dms",
    36: "match_join_success",
    37: "match_join_fail",
    42: "fellow_spectator_joined",
    43: "fellow_spectator_left",
    45: "all_players_loaded",
    46: "match_start",
    48: "match_score_update",
    50: "match_transfer_host",
    53: "match_all_players_loaded",
    57: "match_player_failed",
    58: "match_complete",
    61: "match_skip",
    64: "channel_join_success",
    65: "channel_info",
    66: "channel_kick",
    67: "channel_auto_join",
    69: "beatmap_info_reply",
    71: "privileges",
    72: "friends_list",
    75: "protocol_version",
    76: "main_menu_icon",
    81: "match_player_skipped",
    83: "user_presence",
    86: "restart",
    88: "match_invite",
    89: "channel_info_end",
    91: "match_change_password",
    92: "silence_end",
    94: "user_silenced",
    95: "user_presence_single",
    96: "user_presence_bundle",
    100: "user_dm_blocked",
    101: "target_is_silenced",
    102: "version_update_forced",
    103: "switch_server",
    104: "account_restricted",
    106: "match_abort",
    107: "switch_tournament_server",
}


@dataclass(frozen=True)
class Diagnostic:
    """A framing or semantic error at an absolute byte offset."""

    error: str
    offset: int
    message: str
    packet_index: int | None = None
    packet_id: int | None = None
    severity: Literal["error", "warning"] = "error"

    def to_dict(self) -> dict[str, JSONValue]:
        return {
            "error": self.error,
            "offset": self.offset,
            "message": self.message,
            "packet_index": self.packet_index,
            "packet_id": self.packet_id,
            "severity": self.severity,
        }


@dataclass(frozen=True)
class Packet:
    """One fully framed packet. Payload ownership is independent of the input."""

    offset: int
    packet_id: int
    compression: int
    declared_length: int
    payload: bytes

    @property
    def payload_offset(self) -> int:
        return self.offset + HEADER_SIZE

    def name(self, direction: Direction) -> str:
        names = _packet_names(direction)
        return names.get(self.packet_id, f"unknown_{self.packet_id}")


@dataclass(frozen=True)
class DecodeResult:
    packets: tuple[Packet, ...]
    diagnostics: tuple[Diagnostic, ...]
    remainder_offset: int
    remainder_length: int
    remainder_sha256: str

    @property
    def complete(self) -> bool:
        return not any(item.severity == "error" for item in self.diagnostics)


@dataclass(frozen=True)
class SemanticDecodeResult:
    """JSON-safe packets and byte-addressable diagnostics."""

    packets: tuple[dict[str, JSONValue], ...]
    diagnostics: tuple[Diagnostic, ...]
    remainder_offset: int
    remainder_length: int
    remainder_sha256: str

    @property
    def complete(self) -> bool:
        return not any(item.severity == "error" for item in self.diagnostics)

    def to_dict(self) -> dict[str, JSONValue]:
        return {
            "packets": [copy.deepcopy(item) for item in self.packets],
            "diagnostics": [item.to_dict() for item in self.diagnostics],
            "remainder": {
                "offset": self.remainder_offset,
                "length": self.remainder_length,
                "sha256": self.remainder_sha256,
            },
            "complete": self.complete,
        }

    def canonical_json(self) -> str:
        return canonical_json(self.to_dict())


@dataclass(frozen=True)
class FieldNormalizer:
    """Replace one exact semantic payload field for one exact packet kind.

    ``path`` is relative to the packet's ``payload`` object. An integer path
    component addresses a list index. ``occurrence`` can select one duplicate
    packet; ``None`` applies the same explicit field rule to every occurrence.
    """

    direction: Direction
    packet_id: int
    path: tuple[PathPart, ...]
    replacement: JSONValue = "<normalized>"
    occurrence: int | None = None
    required: bool = False

    def __post_init__(self) -> None:
        _packet_names(self.direction)
        if not 0 <= self.packet_id <= 0xFFFF:
            raise ValueError("packet_id must fit u16")
        if not self.path:
            raise ValueError("normalizer path cannot be empty")
        if self.occurrence is not None and self.occurrence < 0:
            raise ValueError("occurrence cannot be negative")
        for component in self.path:
            if not isinstance(component, (str, int)) or isinstance(component, bool):
                raise TypeError("normalizer path components must be str or int")
        try:
            json.dumps(self.replacement, ensure_ascii=False, allow_nan=False, sort_keys=True)
        except (TypeError, ValueError) as error:
            raise TypeError("normalizer replacement must be JSON-safe") from error


class PayloadDecodeError(ValueError):
    def __init__(self, error: str, offset: int, message: str):
        super().__init__(message)
        self.error = error
        self.offset = offset
        self.message = message


class NormalizationError(ValueError):
    pass


def _packet_names(direction: Direction) -> Mapping[int, str]:
    if direction == "client":
        return CLIENT_PACKET_NAMES
    if direction == "server":
        return SERVER_PACKET_NAMES
    raise ValueError("direction must be 'client' or 'server'")


def decode_packet_stream(
    data: bytes | bytearray | memoryview,
    *,
    max_payload_size: int = DEFAULT_MAX_PAYLOAD_SIZE,
    max_packet_count: int = DEFAULT_MAX_PACKET_COUNT,
) -> DecodeResult:
    """Frame a packet stream without reading or allocating oversized payloads.

    Framing errors return every complete packet before the failure plus one
    diagnostic. The decoder stops at the first point where the next boundary is
    no longer trustworthy.
    """

    if max_payload_size < 0:
        raise ValueError("max_payload_size cannot be negative")
    if max_packet_count < 0:
        raise ValueError("max_packet_count cannot be negative")
    try:
        view = memoryview(data).cast("B")
    except (TypeError, ValueError) as error:
        raise TypeError("data must be a contiguous bytes-like object") from error

    packets: list[Packet] = []
    diagnostics: list[Diagnostic] = []
    offset = 0
    packet_index = 0
    while offset < len(view):
        if packet_index >= max_packet_count:
            diagnostics.append(
                Diagnostic(
                    error="packet_count_limit",
                    offset=offset,
                    message=f"packet count exceeds limit {max_packet_count}",
                    packet_index=packet_index,
                )
            )
            break
        remaining = len(view) - offset
        if remaining < HEADER_SIZE:
            diagnostics.append(
                Diagnostic(
                    error="truncated_header",
                    offset=offset,
                    message=f"packet header needs {HEADER_SIZE} bytes; only {remaining} remain",
                    packet_index=packet_index,
                )
            )
            break

        packet_id, compression, declared_length = HEADER.unpack_from(view, offset)
        if declared_length > max_payload_size:
            diagnostics.append(
                Diagnostic(
                    error="payload_too_large",
                    offset=offset + 3,
                    message=(
                        f"declared payload length {declared_length} exceeds "
                        f"limit {max_payload_size}"
                    ),
                    packet_index=packet_index,
                    packet_id=packet_id,
                )
            )
            break

        payload_offset = offset + HEADER_SIZE
        available = len(view) - payload_offset
        if available < declared_length:
            diagnostics.append(
                Diagnostic(
                    error="truncated_payload",
                    offset=payload_offset + available,
                    message=(
                        f"packet declares {declared_length} payload bytes; "
                        f"only {available} are available"
                    ),
                    packet_index=packet_index,
                    packet_id=packet_id,
                )
            )
            break

        payload_end = payload_offset + declared_length
        packets.append(
            Packet(
                offset=offset,
                packet_id=packet_id,
                compression=compression,
                declared_length=declared_length,
                payload=view[payload_offset:payload_end].tobytes(),
            )
        )
        offset = payload_end
        packet_index += 1

    remainder = view[offset:].tobytes()
    return DecodeResult(
        tuple(packets),
        tuple(diagnostics),
        offset,
        len(remainder),
        hashlib.sha256(remainder).hexdigest(),
    )


class PayloadReader:
    """Little-endian Bancho primitive reader with local error offsets."""

    def __init__(self, data: bytes):
        self._data = memoryview(data).cast("B")
        self.offset = 0

    @property
    def remaining(self) -> int:
        return len(self._data) - self.offset

    def _read(self, size: int) -> memoryview:
        if size < 0:
            raise ValueError("read size cannot be negative")
        end = self.offset + size
        if end > len(self._data):
            raise PayloadDecodeError(
                "truncated_payload",
                len(self._data),
                f"field needs {size} bytes at payload offset {self.offset}; {self.remaining} remain",
            )
        start = self.offset
        self.offset = end
        return self._data[start:end]

    def _unpack(self, fmt: str, size: int) -> int | float:
        return struct.unpack(fmt, self._read(size))[0]

    def u8(self) -> int:
        return int(self._unpack("<B", 1))

    def i16(self) -> int:
        return int(self._unpack("<h", 2))

    def u16(self) -> int:
        return int(self._unpack("<H", 2))

    def i32(self) -> int:
        return int(self._unpack("<i", 4))

    def i64(self) -> int:
        return int(self._unpack("<q", 8))

    def f32(self) -> float | str:
        raw = self._read(4).tobytes()
        value = struct.unpack("<f", raw)[0]
        if math.isfinite(value):
            return value
        bits = struct.unpack("<I", raw)[0]
        if math.isnan(value):
            return f"nan:0x{bits:08x}"
        return "infinity" if value > 0 else "-infinity"

    def f64(self) -> float | str:
        raw = self._read(8).tobytes()
        value = struct.unpack("<d", raw)[0]
        if math.isfinite(value):
            return value
        bits = struct.unpack("<Q", raw)[0]
        if math.isnan(value):
            return f"nan:0x{bits:016x}"
        return "infinity" if value > 0 else "-infinity"

    def uleb128(self) -> int:
        start = self.offset
        value = 0
        # Mirrors Zigcho's usize reader: shifts 0 through 56 are accepted and
        # a continuation beyond bit 62 is an overflow.
        for index in range(9):
            byte = self.u8()
            value |= (byte & 0x7F) << (index * 7)
            if byte & 0x80 == 0:
                return value
        raise PayloadDecodeError("integer_overflow", start, "ULEB128 value exceeds 63 bits")

    def string(self) -> str:
        marker_offset = self.offset
        marker = self.u8()
        if marker == 0:
            return ""
        if marker != 0x0B:
            raise PayloadDecodeError(
                "invalid_string_marker",
                marker_offset,
                f"expected string marker 0x00 or 0x0b; got 0x{marker:02x}",
            )
        length = self.uleb128()
        start = self.offset
        raw = self._read(length).tobytes()
        try:
            return raw.decode("utf-8", errors="strict")
        except UnicodeDecodeError as error:
            raise PayloadDecodeError(
                "invalid_utf8",
                start + error.start,
                "Bancho string is not valid UTF-8",
            ) from error

    def i32_list(self) -> list[int]:
        count_offset = self.offset
        count = self.u16()
        if count > self.remaining // 4:
            raise PayloadDecodeError(
                "truncated_list",
                count_offset,
                f"i32 list declares {count} values; only {self.remaining // 4} fit",
            )
        return [self.i32() for _ in range(count)]

    def finish(self) -> None:
        if self.remaining:
            raise PayloadDecodeError(
                "trailing_payload",
                self.offset,
                f"{self.remaining} unconsumed payload bytes remain",
            )


def _decode_empty(reader: PayloadReader) -> dict[str, JSONValue]:
    reader.finish()
    return {}


def _decode_i32(reader: PayloadReader, field: str = "value") -> dict[str, JSONValue]:
    value = reader.i32()
    reader.finish()
    return {field: value}


def _decode_string(reader: PayloadReader, field: str = "value") -> dict[str, JSONValue]:
    value = reader.string()
    reader.finish()
    return {field: value}


def _decode_i32_list(reader: PayloadReader, field: str = "values") -> dict[str, JSONValue]:
    values = reader.i32_list()
    reader.finish()
    return {field: values}


def _decode_message(reader: PayloadReader) -> dict[str, JSONValue]:
    result: dict[str, JSONValue] = {
        "sender": reader.string(),
        "text": reader.string(),
        "target": reader.string(),
        "sender_id": reader.i32(),
    }
    reader.finish()
    return result


def _decode_channel(reader: PayloadReader) -> dict[str, JSONValue]:
    name = reader.string()
    topic = reader.string()
    if reader.remaining == 4:
        player_count = reader.i32()
        count_wire_bits = 32
    elif reader.remaining == 2:
        # The pinned bancho.py reference writes this field as u16 while
        # Zigcho uses Stable's i32 shape. Decode both and preserve the width so
        # the differential can report the wire mismatch instead of truncation.
        player_count = reader.u16()
        count_wire_bits = 16
    else:
        raise PayloadDecodeError(
            "invalid_channel_count_width",
            reader.offset,
            f"channel player count has {reader.remaining} bytes; expected 2 or 4",
        )
    result: dict[str, JSONValue] = {
        "name": name,
        "topic": topic,
        "player_count": player_count,
        "player_count_wire_bits": count_wire_bits,
    }
    reader.finish()
    return result


def _decode_user_logout(reader: PayloadReader) -> dict[str, JSONValue]:
    result: dict[str, JSONValue] = {"user_id": reader.i32(), "state": reader.u8()}
    reader.finish()
    return result


def _decode_user_presence(reader: PayloadReader) -> dict[str, JSONValue]:
    user_id = reader.i32()
    username = reader.string()
    utc_encoded = reader.u8()
    country_id = reader.u8()
    privileges_and_mode = reader.u8()
    result: dict[str, JSONValue] = {
        "user_id": user_id,
        "username": username,
        "utc_offset": utc_encoded - 24,
        "country_id": country_id,
        "privileges": privileges_and_mode & 0x1F,
        "mode": privileges_and_mode >> 5,
        "longitude": reader.f32(),
        "latitude": reader.f32(),
        "global_rank": reader.i32(),
    }
    reader.finish()
    return result


def _decode_user_stats(reader: PayloadReader) -> dict[str, JSONValue]:
    result: dict[str, JSONValue] = {
        "user_id": reader.i32(),
        "action": reader.u8(),
        "info_text": reader.string(),
        "beatmap_md5": reader.string(),
        "mods": reader.i32(),
        "mode": reader.u8(),
        "beatmap_id": reader.i32(),
        "ranked_score": reader.i64(),
        "accuracy": reader.f32(),
        "play_count": reader.i32(),
        "total_score": reader.i64(),
        "global_rank": reader.i32(),
        "pp": reader.u16(),
    }
    reader.finish()
    return result


def _slot_has_player(status: int) -> bool:
    return status & 0x7C != 0


def _decode_match(reader: PayloadReader) -> dict[str, JSONValue]:
    match_id = reader.i16()
    in_progress_raw = reader.u8()
    if in_progress_raw not in (0, 1):
        raise PayloadDecodeError(
            "invalid_boolean", reader.offset - 1, f"in-progress byte is {in_progress_raw}"
        )
    match_type = reader.u8()
    mods = reader.i32()
    name = reader.string()
    password = reader.string()
    beatmap_name = reader.string()
    beatmap_id = reader.i32()
    beatmap_md5 = reader.string()
    statuses = [reader.u8() for _ in range(16)]
    teams = [reader.u8() for _ in range(16)]
    slots: list[JSONValue] = [
        {"status": status, "team": team, "user_id": None}
        for status, team in zip(statuses, teams, strict=True)
    ]
    for index, status in enumerate(statuses):
        if _slot_has_player(status):
            assert isinstance(slots[index], dict)
            slots[index]["user_id"] = reader.i32()
    host_id = reader.i32()
    mode = reader.u8()
    win_condition = reader.u8()
    team_type = reader.u8()
    freemods_raw = reader.u8()
    if freemods_raw not in (0, 1):
        raise PayloadDecodeError(
            "invalid_boolean", reader.offset - 1, f"freemods byte is {freemods_raw}"
        )
    if freemods_raw:
        for index in range(16):
            assert isinstance(slots[index], dict)
            slots[index]["mods"] = reader.i32()
    seed = reader.i32()
    reader.finish()
    return {
        "match_id": match_id,
        "in_progress": bool(in_progress_raw),
        "in_progress_raw": in_progress_raw,
        "match_type": match_type,
        "mods": mods,
        "name": name,
        "password": password,
        "beatmap_name": beatmap_name,
        "beatmap_id": beatmap_id,
        "beatmap_md5": beatmap_md5,
        "slots": slots,
        "host_id": host_id,
        "mode": mode,
        "win_condition": win_condition,
        "team_type": team_type,
        "freemods": bool(freemods_raw),
        "seed": seed,
    }


def _decode_join_match(reader: PayloadReader) -> dict[str, JSONValue]:
    result: dict[str, JSONValue] = {
        "match_id": reader.i32(),
        "password": reader.string(),
    }
    reader.finish()
    return result


def _decode_action(reader: PayloadReader) -> dict[str, JSONValue]:
    result: dict[str, JSONValue] = {
        "action": reader.u8(),
        "info_text": reader.string(),
        "beatmap_md5": reader.string(),
        "mods": reader.i32(),
        "mode": reader.u8(),
        "beatmap_id": reader.i32(),
    }
    reader.finish()
    return result


REPLAY_ACTION_NAMES: dict[int, str] = {
    0: "standard",
    1: "new_song",
    2: "skip",
    3: "completion",
    4: "fail",
    5: "pause",
    6: "unpause",
    7: "song_select",
    8: "watching_other",
}
REPLAY_FRAME_SIZE = 14
SCORE_FRAME_BASE_SIZE = 29
SCORE_FRAME_V2_TAIL_SIZE = 16


def _wire_boolean(reader: PayloadReader, field: str) -> tuple[bool, int]:
    raw = reader.u8()
    if raw not in (0, 1):
        raise PayloadDecodeError(
            "invalid_boolean", reader.offset - 1, f"{field} byte is {raw}"
        )
    return bool(raw), raw


def _decode_score_frame(
    reader: PayloadReader,
    *,
    consume_all: bool = True,
    reserved_tail_size: int = 0,
) -> dict[str, JSONValue]:
    """Decode Stable's exact 29-byte score frame and optional 16-byte v2 tail."""

    if reserved_tail_size < 0:
        raise ValueError("reserved_tail_size cannot be negative")

    result: dict[str, JSONValue] = {
        "time": reader.i32(),
        "id": reader.u8(),
        "count_300": reader.u16(),
        "count_100": reader.u16(),
        "count_50": reader.u16(),
        "count_geki": reader.u16(),
        "count_katu": reader.u16(),
        "count_miss": reader.u16(),
        "total_score": reader.i32(),
        "max_combo": reader.u16(),
        "current_combo": reader.u16(),
    }
    perfect, perfect_raw = _wire_boolean(reader, "perfect")
    result["perfect"] = perfect
    result["perfect_raw"] = perfect_raw
    result["current_hp"] = reader.u8()
    result["tag_byte"] = reader.u8()
    score_v2, score_v2_raw = _wire_boolean(reader, "score_v2")
    result["score_v2"] = score_v2
    result["score_v2_raw"] = score_v2_raw
    if score_v2:
        required = SCORE_FRAME_V2_TAIL_SIZE + reserved_tail_size
        if reader.remaining < required:
            raise PayloadDecodeError(
                "truncated_payload",
                reader.offset + reader.remaining,
                (
                    "score_v2 frame needs a 16-byte scoring tail plus "
                    f"{reserved_tail_size} reserved bytes; {reader.remaining} remain"
                ),
            )
        result["combo_portion"] = reader.f64()
        result["bonus_portion"] = reader.f64()
    else:
        result["combo_portion"] = None
        result["bonus_portion"] = None
    if consume_all:
        reader.finish()
    return result


def _decode_replay_frame(reader: PayloadReader) -> dict[str, JSONValue]:
    return {
        "button_state": reader.u8(),
        "taiko_byte": reader.u8(),
        "x": reader.f32(),
        "y": reader.f32(),
        "time": reader.i32(),
    }


def _decode_replay_frame_bundle(reader: PayloadReader) -> dict[str, JSONValue]:
    extra = reader.i32()
    count_offset = reader.offset
    frame_count = reader.u16()
    minimum_tail_size = 1 + SCORE_FRAME_BASE_SIZE + 2
    required = frame_count * REPLAY_FRAME_SIZE + minimum_tail_size
    if required > reader.remaining:
        available_frames = max(0, reader.remaining - minimum_tail_size) // REPLAY_FRAME_SIZE
        raise PayloadDecodeError(
            "truncated_list",
            count_offset,
            (
                f"replay bundle declares {frame_count} frames; only "
                f"{available_frames} fit before the required base tail"
            ),
        )

    frames: list[JSONValue] = [
        _decode_replay_frame(reader) for _ in range(frame_count)
    ]
    action_offset = reader.offset
    action = reader.u8()
    action_name = REPLAY_ACTION_NAMES.get(action)
    if action_name is None:
        raise PayloadDecodeError(
            "invalid_enum", action_offset, f"replay action byte is {action}"
        )
    score_frame = _decode_score_frame(
        reader, consume_all=False, reserved_tail_size=2
    )
    sequence = reader.u16()
    reader.finish()
    return {
        "extra": extra,
        "frame_count": frame_count,
        "frames": frames,
        "action": action,
        "action_name": action_name,
        "score_frame": score_frame,
        "sequence": sequence,
    }


SERVER_EMPTY_PACKETS = frozenset({8, 34, 37, 45, 50, 53, 58, 61, 89, 102, 104, 106})
SERVER_I32_FIELDS: dict[int, str] = {
    5: "user_id",
    13: "user_id",
    14: "user_id",
    22: "user_id",
    28: "match_id",
    42: "user_id",
    43: "user_id",
    57: "slot_id",
    71: "privileges",
    75: "protocol_version",
    81: "user_id",
    86: "delay_ms",
    92: "seconds",
    94: "user_id",
    95: "user_id",
    103: "server_id",
}
SERVER_STRING_FIELDS: dict[int, str] = {
    24: "message",
    64: "channel",
    66: "channel",
    67: "channel",
    76: "icon",
    91: "password",
    107: "host",
}
SERVER_MESSAGE_PACKETS = frozenset({7, 88, 100, 101})
SERVER_MATCH_PACKETS = frozenset({26, 27, 36, 46})

CLIENT_EMPTY_PACKETS = frozenset(
    {
        3,
        4,
        17,
        21,
        29,
        30,
        33,
        39,
        44,
        49,
        52,
        54,
        55,
        56,
        59,
        60,
        77,
        84,
    }
)
CLIENT_I32_FIELDS: dict[int, str] = {
    2: "reserved",
    16: "user_id",
    38: "slot_id",
    40: "slot_id",
    51: "mods",
    70: "slot_id",
    73: "user_id",
    74: "user_id",
    79: "filter",
    87: "user_id",
    93: "match_id",
    98: "request",
    99: "enabled",
    108: "match_id",
    109: "match_id",
}
CLIENT_STRING_FIELDS: dict[int, str] = {63: "channel", 78: "channel"}
CLIENT_MESSAGE_PACKETS = frozenset({1, 25, 82})
CLIENT_MATCH_PACKETS = frozenset({31, 41, 90})
CLIENT_I32_LIST_PACKETS = frozenset({85, 97})


def decode_packet_semantics(packet: Packet, direction: Direction) -> dict[str, JSONValue] | None:
    """Decode a known payload shape, or return ``None`` for opaque packets.

    A non-zero compression byte is intentionally opaque. The stream framing is
    still valid, but this module does not guess a compression algorithm.
    """

    _packet_names(direction)
    if packet.compression != 0:
        return None
    reader = PayloadReader(packet.payload)

    if direction == "server":
        if packet.packet_id in SERVER_EMPTY_PACKETS:
            return _decode_empty(reader)
        if packet.packet_id in SERVER_I32_FIELDS:
            return _decode_i32(reader, SERVER_I32_FIELDS[packet.packet_id])
        if packet.packet_id in SERVER_STRING_FIELDS:
            return _decode_string(reader, SERVER_STRING_FIELDS[packet.packet_id])
        if packet.packet_id in SERVER_MESSAGE_PACKETS:
            return _decode_message(reader)
        if packet.packet_id == 11:
            return _decode_user_stats(reader)
        if packet.packet_id == 12:
            return _decode_user_logout(reader)
        if packet.packet_id == 15:
            return _decode_replay_frame_bundle(reader)
        if packet.packet_id in SERVER_MATCH_PACKETS:
            return _decode_match(reader)
        if packet.packet_id == 48:
            return _decode_score_frame(reader)
        if packet.packet_id == 65:
            return _decode_channel(reader)
        if packet.packet_id == 72:
            return _decode_i32_list(reader, "user_ids")
        if packet.packet_id == 83:
            return _decode_user_presence(reader)
        if packet.packet_id == 96:
            return _decode_i32_list(reader, "user_ids")
        return None

    if packet.packet_id in CLIENT_EMPTY_PACKETS:
        return _decode_empty(reader)
    if packet.packet_id in CLIENT_I32_FIELDS:
        return _decode_i32(reader, CLIENT_I32_FIELDS[packet.packet_id])
    if packet.packet_id in CLIENT_STRING_FIELDS:
        return _decode_string(reader, CLIENT_STRING_FIELDS[packet.packet_id])
    if packet.packet_id in CLIENT_MESSAGE_PACKETS:
        return _decode_message(reader)
    if packet.packet_id == 0:
        return _decode_action(reader)
    if packet.packet_id == 18:
        return _decode_replay_frame_bundle(reader)
    if packet.packet_id in CLIENT_MATCH_PACKETS:
        return _decode_match(reader)
    if packet.packet_id == 47:
        return _decode_score_frame(reader)
    if packet.packet_id == 32:
        return _decode_join_match(reader)
    if packet.packet_id in CLIENT_I32_LIST_PACKETS:
        return _decode_i32_list(reader, "user_ids")
    return None


def decode_semantic_packet_stream(
    data: bytes | bytearray | memoryview,
    direction: Direction,
    *,
    max_payload_size: int = DEFAULT_MAX_PAYLOAD_SIZE,
    max_packet_count: int = DEFAULT_MAX_PACKET_COUNT,
    normalizers: Sequence[FieldNormalizer] = (),
) -> SemanticDecodeResult:
    """Return typed semantic decoding evidence for a packet stream."""

    _packet_names(direction)
    framed = decode_packet_stream(
        data,
        max_payload_size=max_payload_size,
        max_packet_count=max_packet_count,
    )
    diagnostics = list(framed.diagnostics)
    packets: list[dict[str, JSONValue]] = []

    for packet_index, packet in enumerate(framed.packets):
        normalized: dict[str, JSONValue] = {
            "direction": direction,
            "id": packet.packet_id,
            "name": packet.name(direction),
            "compression": packet.compression,
        }
        if packet.compression != 0:
            normalized["payload_hex"] = packet.payload.hex()
            diagnostics.append(
                Diagnostic(
                    error="unsupported_compression",
                    offset=packet.offset + 2,
                    message=f"compression byte is {packet.compression}; payload left opaque",
                    packet_index=packet_index,
                    packet_id=packet.packet_id,
                    severity="warning",
                )
            )
        else:
            try:
                semantic = decode_packet_semantics(packet, direction)
            except PayloadDecodeError as error:
                normalized["payload_hex"] = packet.payload.hex()
                diagnostics.append(
                    Diagnostic(
                        error=error.error,
                        offset=packet.payload_offset + error.offset,
                        message=error.message,
                        packet_index=packet_index,
                        packet_id=packet.packet_id,
                    )
                )
            else:
                if semantic is None:
                    normalized["payload_hex"] = packet.payload.hex()
                else:
                    normalized["payload"] = semantic
        packets.append(normalized)

    normalized_packets = apply_field_normalizers(packets, normalizers)
    return SemanticDecodeResult(
        tuple(normalized_packets),
        tuple(diagnostics),
        framed.remainder_offset,
        framed.remainder_length,
        framed.remainder_sha256,
    )


def normalize_packet_stream(
    data: bytes | bytearray | memoryview,
    direction: Direction,
    *,
    max_payload_size: int = DEFAULT_MAX_PAYLOAD_SIZE,
    max_packet_count: int = DEFAULT_MAX_PACKET_COUNT,
    normalizers: Sequence[FieldNormalizer] = (),
) -> dict[str, JSONValue]:
    """Return plain, deterministic, JSON-safe semantic packet evidence.

    The differential runner uses this function directly inside its canonical
    response document, so the public boundary intentionally returns ordinary
    dictionaries and lists rather than requiring a custom JSON encoder.
    """

    return decode_semantic_packet_stream(
        data,
        direction,
        max_payload_size=max_payload_size,
        max_packet_count=max_packet_count,
        normalizers=normalizers,
    ).to_dict()


def apply_field_normalizers(
    packets: Iterable[Mapping[str, JSONValue]],
    normalizers: Sequence[FieldNormalizer],
) -> list[dict[str, JSONValue]]:
    """Apply exact packet-and-path replacement rules to semantic packets."""

    result: list[dict[str, JSONValue]] = [copy.deepcopy(dict(packet)) for packet in packets]
    for rule in normalizers:
        matching = [
            index
            for index, packet in enumerate(result)
            if packet.get("direction") == rule.direction and packet.get("id") == rule.packet_id
        ]
        if rule.occurrence is not None:
            matching = matching[rule.occurrence : rule.occurrence + 1]
        if not matching and rule.required:
            raise NormalizationError(
                f"required {rule.direction} packet {rule.packet_id} occurrence was not present"
            )
        for packet_index in matching:
            packet = result[packet_index]
            payload = packet.get("payload")
            if not isinstance(payload, dict):
                raise NormalizationError(
                    f"packet {packet_index} has no structured payload for path {rule.path!r}"
                )
            _replace_exact_path(payload, rule.path, rule.replacement, packet_index)
    return result


def _replace_exact_path(
    root: dict[str, JSONValue],
    path: tuple[PathPart, ...],
    replacement: JSONValue,
    packet_index: int,
) -> None:
    current: Any = root
    for component in path[:-1]:
        if isinstance(component, str) and isinstance(current, dict) and component in current:
            current = current[component]
        elif (
            isinstance(component, int)
            and not isinstance(component, bool)
            and isinstance(current, list)
            and 0 <= component < len(current)
        ):
            current = current[component]
        else:
            raise NormalizationError(
                f"packet {packet_index} has no exact payload path {path!r}"
            )

    leaf = path[-1]
    if isinstance(leaf, str) and isinstance(current, dict) and leaf in current:
        current[leaf] = copy.deepcopy(replacement)
        return
    if (
        isinstance(leaf, int)
        and not isinstance(leaf, bool)
        and isinstance(current, list)
        and 0 <= leaf < len(current)
    ):
        current[leaf] = copy.deepcopy(replacement)
        return
    raise NormalizationError(f"packet {packet_index} has no exact payload path {path!r}")


def canonical_json(value: JSONValue | Mapping[str, JSONValue]) -> str:
    """Serialize normalized evidence with stable keys and no non-JSON floats."""

    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    )


__all__ = [
    "CLIENT_PACKET_NAMES",
    "DEFAULT_MAX_PAYLOAD_SIZE",
    "DecodeResult",
    "Diagnostic",
    "FieldNormalizer",
    "HEADER_SIZE",
    "NormalizationError",
    "Packet",
    "PayloadDecodeError",
    "PayloadReader",
    "SERVER_PACKET_NAMES",
    "SemanticDecodeResult",
    "apply_field_normalizers",
    "canonical_json",
    "decode_packet_semantics",
    "decode_packet_stream",
    "decode_semantic_packet_stream",
    "normalize_packet_stream",
]
