from __future__ import annotations

import json
import struct
import sys
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from protocol import (  # noqa: E402
    FieldNormalizer,
    NormalizationError,
    apply_field_normalizers,
    canonical_json,
    decode_packet_stream,
    normalize_packet_stream,
)


def wire_string(value: str) -> bytes:
    raw = value.encode("utf-8")
    if not raw:
        return b"\x00"
    encoded_length = bytearray()
    remaining = len(raw)
    while True:
        byte = remaining & 0x7F
        remaining >>= 7
        encoded_length.append(byte | (0x80 if remaining else 0))
        if not remaining:
            break
    return b"\x0b" + bytes(encoded_length) + raw


def wire_packet(packet_id: int, payload: bytes = b"", compression: int = 0) -> bytes:
    return struct.pack("<HBI", packet_id, compression, len(payload)) + payload


def message_payload(sender: str, text: str, target: str, sender_id: int) -> bytes:
    return (
        wire_string(sender)
        + wire_string(text)
        + wire_string(target)
        + struct.pack("<i", sender_id)
    )


def match_payload() -> bytes:
    statuses = bytes([4] + [1] * 15)
    teams = bytes([0] * 16)
    return (
        struct.pack("<hBBi", 7, 0, 0, 64)
        + wire_string("room")
        + wire_string("")
        + wire_string("artist - title [hard]")
        + struct.pack("<i", 123)
        + wire_string("a" * 32)
        + statuses
        + teams
        + struct.pack("<i", 44)
        + struct.pack("<iBBBBi", 44, 0, 0, 0, 0, 99)
    )


def score_frame_payload(
    *,
    score_v2: bool = False,
    perfect: bool = True,
    combo_portion: float = 0.75,
    bonus_portion: float = 0.25,
) -> bytes:
    base = struct.pack(
        "<iBHHHHHHiHH?BB?",
        1234,
        7,
        300,
        100,
        50,
        12,
        8,
        3,
        987654,
        456,
        321,
        perfect,
        200,
        9,
        score_v2,
    )
    if score_v2:
        return base + struct.pack("<dd", combo_portion, bonus_portion)
    return base


def replay_frame_bundle_payload(*, score_v2: bool = False) -> bytes:
    frame = struct.pack("<BBffi", 5, 2, 256.5, 128.25, 7331)
    return (
        struct.pack("<iH", -9, 1)
        + frame
        + bytes([5])
        + score_frame_payload(score_v2=score_v2)
        + struct.pack("<H", 42)
    )


class FramingTests(unittest.TestCase):
    def test_exact_little_endian_header_and_compression_byte(self) -> None:
        data = wire_packet(0x1234, b"abc", compression=0x56)
        result = decode_packet_stream(data)

        self.assertTrue(result.complete)
        self.assertEqual(len(result.packets), 1)
        packet = result.packets[0]
        self.assertEqual(packet.packet_id, 0x1234)
        self.assertEqual(packet.compression, 0x56)
        self.assertEqual(packet.declared_length, 3)
        self.assertEqual(packet.payload, b"abc")
        self.assertEqual(packet.offset, 0)

    def test_truncated_header_and_payload_report_exact_offsets(self) -> None:
        complete = wire_packet(8)
        header_truncated = decode_packet_stream(complete + b"\x01\x02")
        self.assertEqual(len(header_truncated.packets), 1)
        self.assertEqual(header_truncated.diagnostics[0].error, "truncated_header")
        self.assertEqual(header_truncated.diagnostics[0].offset, len(complete))

        payload_truncated = decode_packet_stream(struct.pack("<HBI", 24, 0, 4) + b"ab")
        self.assertEqual(payload_truncated.packets, ())
        self.assertEqual(payload_truncated.diagnostics[0].error, "truncated_payload")
        self.assertEqual(payload_truncated.diagnostics[0].offset, 9)
        self.assertEqual(payload_truncated.diagnostics[0].packet_id, 24)

    def test_truncated_remainder_fingerprint_keeps_distinct_malformed_inputs_distinct(self) -> None:
        first = normalize_packet_stream(struct.pack("<HBI", 24, 0, 4) + b"ab", "server")
        second = normalize_packet_stream(struct.pack("<HBI", 24, 0, 4) + b"cd", "server")
        self.assertEqual(first["remainder"]["length"], second["remainder"]["length"])
        self.assertNotEqual(first["remainder"]["sha256"], second["remainder"]["sha256"])

    def test_payload_limit_is_checked_before_copying(self) -> None:
        result = decode_packet_stream(
            struct.pack("<HBI", 15, 0, 9) + b"123456789", max_payload_size=8
        )
        self.assertEqual(result.packets, ())
        self.assertEqual(result.diagnostics[0].error, "payload_too_large")
        self.assertEqual(result.diagnostics[0].offset, 3)

    def test_packet_count_limit_stops_object_amplification(self) -> None:
        packet = wire_packet(8)
        result = decode_packet_stream(packet * 3, max_packet_count=2)
        self.assertEqual(len(result.packets), 2)
        self.assertEqual(result.diagnostics[0].error, "packet_count_limit")
        self.assertEqual(result.diagnostics[0].offset, len(packet) * 2)
        self.assertEqual(result.remainder_length, len(packet))

        semantic = normalize_packet_stream(packet * 3, "server", max_packet_count=2)
        self.assertFalse(semantic["complete"])
        self.assertEqual(semantic["diagnostics"][0]["error"], "packet_count_limit")

    def test_duplicate_packets_are_preserved_in_wire_order(self) -> None:
        data = wire_packet(24, wire_string("first")) + wire_packet(
            24, wire_string("second")
        )
        result = normalize_packet_stream(data, "server")

        self.assertEqual([packet["id"] for packet in result["packets"]], [24, 24])
        self.assertEqual(
            [packet["payload"]["message"] for packet in result["packets"]],
            ["first", "second"],
        )


class SemanticTests(unittest.TestCase):
    def test_client_logout_keeps_the_reserved_i32_payload(self) -> None:
        result = normalize_packet_stream(wire_packet(2, struct.pack("<i", 0)), "client")
        self.assertTrue(result["complete"], result["diagnostics"])
        self.assertEqual(result["packets"][0]["payload"], {"reserved": 0})

    def test_common_primitive_string_message_channel_and_user_packets(self) -> None:
        presence = (
            struct.pack("<i", 44)
            + wire_string("ari")
            + bytes([33, 13, (2 << 5) | 5])
            + struct.pack("<ffi", 138.6, -34.9, 1)
        )
        stats = (
            struct.pack("<iB", 44, 2)
            + wire_string("playing")
            + wire_string("b" * 32)
            + struct.pack("<iBi", 64, 0, 123)
            + struct.pack("<qfiqiH", 9001, 98.5, 12, 123456, 1, 727)
        )
        channel = wire_string("#osu") + wire_string("general") + struct.pack("<i", 3)
        data = b"".join(
            [
                wire_packet(5, struct.pack("<i", 44)),
                wire_packet(24, wire_string("hello")),
                wire_packet(7, message_payload("kai", "hi", "#osu", 3)),
                wire_packet(65, channel),
                wire_packet(83, presence),
                wire_packet(11, stats),
            ]
        )

        result = normalize_packet_stream(data, "server")
        self.assertTrue(result["complete"], result["diagnostics"])
        self.assertEqual(result["packets"][0]["payload"], {"user_id": 44})
        self.assertEqual(result["packets"][1]["payload"], {"message": "hello"})
        self.assertEqual(result["packets"][2]["payload"]["sender"], "kai")
        self.assertEqual(result["packets"][3]["payload"]["player_count"], 3)
        self.assertEqual(result["packets"][3]["payload"]["player_count_wire_bits"], 32)
        self.assertEqual(result["packets"][4]["payload"]["utc_offset"], 9)
        self.assertEqual(result["packets"][4]["payload"]["mode"], 2)
        self.assertEqual(result["packets"][5]["payload"]["pp"], 727)
        json.loads(canonical_json(result))

    def test_channel_info_preserves_the_pinned_reference_u16_width(self) -> None:
        channel = wire_string("#osu") + wire_string("general") + struct.pack("<H", 3)
        result = normalize_packet_stream(wire_packet(65, channel), "server")
        self.assertTrue(result["complete"], result["diagnostics"])
        self.assertEqual(result["packets"][0]["payload"]["player_count"], 3)
        self.assertEqual(result["packets"][0]["payload"]["player_count_wire_bits"], 16)

    def test_password_change_and_server_switch_use_reference_wire_types(self) -> None:
        result = normalize_packet_stream(
            wire_packet(91, wire_string("new password"))
            + wire_packet(103, struct.pack("<i", 2)),
            "server",
        )
        self.assertTrue(result["complete"], result["diagnostics"])
        self.assertEqual(result["packets"][0]["payload"], {"password": "new password"})
        self.assertEqual(result["packets"][1]["payload"], {"server_id": 2})

    def test_match_packet_is_structured_by_slot(self) -> None:
        result = normalize_packet_stream(wire_packet(26, match_payload()), "server")
        self.assertTrue(result["complete"], result["diagnostics"])
        payload = result["packets"][0]["payload"]
        self.assertEqual(payload["match_id"], 7)
        self.assertEqual(payload["name"], "room")
        self.assertEqual(payload["slots"][0]["user_id"], 44)
        self.assertEqual(payload["slots"][1]["user_id"], None)
        self.assertEqual(payload["host_id"], 44)

    def test_replay_frame_bundle_decodes_for_client_and_server_packets(self) -> None:
        payload = replay_frame_bundle_payload(score_v2=True)
        for direction, packet_id in (("client", 18), ("server", 15)):
            with self.subTest(direction=direction):
                result = normalize_packet_stream(wire_packet(packet_id, payload), direction)
                self.assertTrue(result["complete"], result["diagnostics"])
                decoded = result["packets"][0]["payload"]
                self.assertEqual(decoded["extra"], -9)
                self.assertEqual(decoded["frame_count"], 1)
                self.assertEqual(decoded["frames"][0]["button_state"], 5)
                self.assertEqual(decoded["frames"][0]["taiko_byte"], 2)
                self.assertEqual(decoded["frames"][0]["x"], 256.5)
                self.assertEqual(decoded["frames"][0]["y"], 128.25)
                self.assertEqual(decoded["frames"][0]["time"], 7331)
                self.assertEqual(decoded["action"], 5)
                self.assertEqual(decoded["action_name"], "pause")
                self.assertEqual(decoded["score_frame"]["total_score"], 987654)
                self.assertEqual(decoded["score_frame"]["combo_portion"], 0.75)
                self.assertEqual(decoded["sequence"], 42)

    def test_score_frame_decodes_base_and_score_v2_wire_shapes(self) -> None:
        base = normalize_packet_stream(
            wire_packet(47, score_frame_payload()), "client"
        )
        self.assertTrue(base["complete"], base["diagnostics"])
        base_payload = base["packets"][0]["payload"]
        self.assertEqual(base_payload["id"], 7)
        self.assertEqual(base_payload["count_300"], 300)
        self.assertEqual(base_payload["perfect"], True)
        self.assertEqual(base_payload["score_v2"], False)
        self.assertIsNone(base_payload["combo_portion"])

        score_v2 = normalize_packet_stream(
            wire_packet(48, score_frame_payload(score_v2=True)), "server"
        )
        self.assertTrue(score_v2["complete"], score_v2["diagnostics"])
        v2_payload = score_v2["packets"][0]["payload"]
        self.assertEqual(v2_payload["score_v2"], True)
        self.assertEqual(v2_payload["combo_portion"], 0.75)
        self.assertEqual(v2_payload["bonus_portion"], 0.25)

    def test_replay_count_and_score_v2_tail_are_exactly_bounded(self) -> None:
        one_frame = struct.pack("<BBffi", 1, 0, 1.0, 2.0, 3)
        malformed_count = (
            struct.pack("<iH", 0, 2)
            + one_frame
            + bytes([0])
            + score_frame_payload()
            + struct.pack("<H", 0)
        )
        count_result = normalize_packet_stream(
            wire_packet(18, malformed_count), "client"
        )
        self.assertFalse(count_result["complete"])
        self.assertEqual(count_result["diagnostics"][0]["error"], "truncated_list")
        self.assertEqual(count_result["diagnostics"][0]["offset"], 11)

        truncated_v2 = score_frame_payload(score_v2=True)[:-1]
        tail_result = normalize_packet_stream(wire_packet(47, truncated_v2), "client")
        self.assertFalse(tail_result["complete"])
        self.assertEqual(tail_result["diagnostics"][0]["error"], "truncated_payload")

        trailing_v1 = score_frame_payload() + b"\x00"
        trailing_result = normalize_packet_stream(wire_packet(48, trailing_v1), "server")
        self.assertFalse(trailing_result["complete"])
        self.assertEqual(trailing_result["diagnostics"][0]["error"], "trailing_payload")

    def test_replay_and_score_non_finite_floats_stay_json_safe(self) -> None:
        score = score_frame_payload(
            score_v2=True,
            combo_portion=float("nan"),
            bonus_portion=float("inf"),
        )
        payload = (
            struct.pack("<iH", 0, 1)
            + struct.pack("<BBIIi", 0, 0, 0x7FC00001, 0x7F800000, 0)
            + bytes([0])
            + score
            + struct.pack("<H", 1)
        )
        result = normalize_packet_stream(wire_packet(15, payload), "server")
        self.assertTrue(result["complete"], result["diagnostics"])
        decoded = result["packets"][0]["payload"]
        self.assertEqual(decoded["frames"][0]["x"], "nan:0x7fc00001")
        self.assertEqual(decoded["frames"][0]["y"], "infinity")
        self.assertTrue(decoded["score_frame"]["combo_portion"].startswith("nan:0x"))
        self.assertEqual(decoded["score_frame"]["bonus_portion"], "infinity")
        json.loads(canonical_json(result))

    def test_malformed_semantic_payload_falls_back_to_hex_with_absolute_offset(self) -> None:
        data = wire_packet(24, b"\x01bad")
        result = normalize_packet_stream(data, "server")

        self.assertFalse(result["complete"])
        self.assertEqual(result["packets"][0]["payload_hex"], "01626164")
        self.assertEqual(result["diagnostics"][0]["error"], "invalid_string_marker")
        self.assertEqual(result["diagnostics"][0]["offset"], 7)
        self.assertEqual(result["diagnostics"][0]["packet_index"], 0)

    def test_nonzero_compression_is_opaque_and_json_safe(self) -> None:
        result = normalize_packet_stream(wire_packet(24, b"raw", compression=1), "server")
        self.assertTrue(result["complete"])
        self.assertEqual(result["packets"][0]["payload_hex"], "726177")
        self.assertEqual(result["diagnostics"][0]["error"], "unsupported_compression")
        self.assertEqual(result["diagnostics"][0]["severity"], "warning")
        json.loads(canonical_json(result))


class NormalizationTests(unittest.TestCase):
    def test_rules_touch_only_the_declared_packet_occurrence_and_field(self) -> None:
        data = wire_packet(7, message_payload("same", "dynamic", "same", 3)) * 2
        result = normalize_packet_stream(
            data,
            "server",
            normalizers=(
                FieldNormalizer(
                    direction="server",
                    packet_id=7,
                    occurrence=1,
                    path=("text",),
                    replacement="<ignored text>",
                    required=True,
                ),
            ),
        )

        self.assertEqual(result["packets"][0]["payload"]["text"], "dynamic")
        self.assertEqual(result["packets"][1]["payload"]["text"], "<ignored text>")
        self.assertEqual(result["packets"][1]["payload"]["sender"], "same")
        self.assertEqual(result["packets"][1]["payload"]["target"], "same")

    def test_invalid_declared_path_is_not_silently_ignored(self) -> None:
        packets = normalize_packet_stream(
            wire_packet(24, wire_string("hello")), "server"
        )["packets"]
        with self.assertRaises(NormalizationError):
            apply_field_normalizers(
                packets,
                (
                    FieldNormalizer(
                        direction="server", packet_id=24, path=("timestamp",)
                    ),
                ),
            )


if __name__ == "__main__":
    unittest.main()
