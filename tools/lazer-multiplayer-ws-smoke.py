#!/usr/bin/env python3

import base64
import hashlib
import os
import socket
import struct
import sys
import json
import urllib.parse
import urllib.request


def pack(value):
    if value is None:
        return b"\xc0"
    if value is False:
        return b"\xc2"
    if value is True:
        return b"\xc3"
    if isinstance(value, int):
        if 0 <= value <= 0x7f:
            return bytes([value])
        if -32 <= value < 0:
            return bytes([value & 0xff])
        if 0 <= value <= 0xff:
            return b"\xcc" + struct.pack(">B", value)
        if 0 <= value <= 0xffff:
            return b"\xcd" + struct.pack(">H", value)
        if 0 <= value <= 0xffffffff:
            return b"\xce" + struct.pack(">I", value)
        if value >= 0:
            return b"\xcf" + struct.pack(">Q", value)
        if value >= -0x80:
            return b"\xd0" + struct.pack(">b", value)
        if value >= -0x8000:
            return b"\xd1" + struct.pack(">h", value)
        if value >= -0x80000000:
            return b"\xd2" + struct.pack(">i", value)
        return b"\xd3" + struct.pack(">q", value)
    if isinstance(value, float):
        return b"\xcb" + struct.pack(">d", value)
    if isinstance(value, str):
        raw = value.encode()
        if len(raw) <= 31:
            return bytes([0xa0 | len(raw)]) + raw
        if len(raw) <= 0xff:
            return b"\xd9" + bytes([len(raw)]) + raw
        return b"\xda" + struct.pack(">H", len(raw)) + raw
    if isinstance(value, list):
        prefix = bytes([0x90 | len(value)]) if len(value) <= 15 else b"\xdc" + struct.pack(">H", len(value))
        return prefix + b"".join(pack(item) for item in value)
    if isinstance(value, dict):
        prefix = bytes([0x80 | len(value)]) if len(value) <= 15 else b"\xde" + struct.pack(">H", len(value))
        return prefix + b"".join(pack(key) + pack(item) for key, item in value.items())
    raise TypeError(type(value))


def unpack(data, position=0):
    tag = data[position]
    position += 1
    if tag <= 0x7f:
        return tag, position
    if tag >= 0xe0:
        return tag - 256, position
    if 0xa0 <= tag <= 0xbf:
        size = tag & 0x1f
        return data[position:position + size].decode(), position + size
    if 0x90 <= tag <= 0x9f:
        result = []
        for _ in range(tag & 0x0f):
            value, position = unpack(data, position)
            result.append(value)
        return result, position
    if 0x80 <= tag <= 0x8f:
        result = {}
        for _ in range(tag & 0x0f):
            key, position = unpack(data, position)
            value, position = unpack(data, position)
            result[key] = value
        return result, position
    if tag == 0xc0:
        return None, position
    if tag == 0xc2:
        return False, position
    if tag == 0xc3:
        return True, position
    formats = {
        0xcc: (">B", 1), 0xcd: (">H", 2), 0xce: (">I", 4), 0xcf: (">Q", 8),
        0xd0: (">b", 1), 0xd1: (">h", 2), 0xd2: (">i", 4), 0xd3: (">q", 8),
        0xca: (">f", 4), 0xcb: (">d", 8),
    }
    if tag in formats:
        fmt, size = formats[tag]
        return struct.unpack(fmt, data[position:position + size])[0], position + size
    if tag in (0xd9, 0xda, 0xdb):
        size_bytes = {0xd9: 1, 0xda: 2, 0xdb: 4}[tag]
        size = int.from_bytes(data[position:position + size_bytes], "big")
        position += size_bytes
        return data[position:position + size].decode(), position + size
    if tag in (0xdc, 0xdd):
        size_bytes = 2 if tag == 0xdc else 4
        count = int.from_bytes(data[position:position + size_bytes], "big")
        position += size_bytes
        result = []
        for _ in range(count):
            value, position = unpack(data, position)
            result.append(value)
        return result, position
    if tag in (0xde, 0xdf):
        size_bytes = 2 if tag == 0xde else 4
        count = int.from_bytes(data[position:position + size_bytes], "big")
        position += size_bytes
        result = {}
        for _ in range(count):
            key, position = unpack(data, position)
            value, position = unpack(data, position)
            result[key] = value
        return result, position
    raise ValueError(f"unsupported MessagePack tag {tag:#x}")


def signalr_frame(message):
    body = pack(message)
    length = len(body)
    prefix = bytearray()
    while True:
        byte = length & 0x7f
        length >>= 7
        prefix.append(byte | (0x80 if length else 0))
        if not length:
            break
    return bytes(prefix) + body


class WebSocket:
    def __init__(self, host, port, token, path="/multiplayer?id=smoke"):
        self.socket = socket.create_connection((host, port), timeout=5)
        self.socket.settimeout(5)
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
            f"Sec-WebSocket-Key: {key}\r\nAuthorization: Bearer {token}\r\n\r\n"
        )
        self.socket.sendall(request.encode())
        response = b""
        while b"\r\n\r\n" not in response:
            response += self.socket.recv(4096)
        if not response.startswith(b"HTTP/1.1 101"):
            raise RuntimeError(response.decode(errors="replace"))
        expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
        if expected.lower() not in response.lower():
            raise RuntimeError("invalid websocket accept")
        self.events = []
        self.event_messages = []
        # Zigcho negotiates binary transfer for the MessagePack hub. The JSON
        # SignalR handshake therefore arrives in a binary WebSocket frame in
        # the real client, even though its body is JSON.
        self.send(2, b'{"protocol":"messagepack","version":1}\x1e')
        opcode, payload = self.receive()
        if opcode != 2 or payload != b"{}\x1e":
            raise RuntimeError(f"invalid SignalR handshake {opcode} {payload!r}")

    def close(self):
        try:
            self.send(8, b"")
        finally:
            self.socket.close()

    def send(self, opcode, payload):
        mask = os.urandom(4)
        length = len(payload)
        header = bytearray([0x80 | opcode])
        if length < 126:
            header.append(0x80 | length)
        elif length <= 0xffff:
            header.append(0x80 | 126)
            header.extend(struct.pack(">H", length))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack(">Q", length))
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.socket.sendall(bytes(header) + mask + masked)

    def receive(self):
        first = self._read(2)
        opcode = first[0] & 0x0f
        length = first[1] & 0x7f
        if length == 126:
            length = struct.unpack(">H", self._read(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._read(8))[0]
        if first[1] & 0x80:
            mask = self._read(4)
            payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(self._read(length)))
        else:
            payload = self._read(length)
        return opcode, payload

    def _read(self, size):
        output = b""
        while len(output) < size:
            chunk = self.socket.recv(size - len(output))
            if not chunk:
                raise RuntimeError("websocket closed")
            output += chunk
        return output

    def invoke(self, invocation_id, target, arguments):
        self.send(2, signalr_frame([1, {}, str(invocation_id), target, arguments, []]))
        while True:
            opcode, payload = self.receive()
            if opcode == 9:
                self.send(10, payload)
                continue
            if opcode != 2:
                continue
            position = 0
            while position < len(payload):
                length = 0
                shift = 0
                while True:
                    byte = payload[position]
                    position += 1
                    length |= (byte & 0x7f) << shift
                    if not byte & 0x80:
                        break
                    shift += 7
                message, consumed = unpack(payload[position:position + length])
                if consumed != length:
                    raise RuntimeError("trailing MessagePack bytes")
                position += length
                if message[0] == 1:
                    self.events.append(message[3])
                    self.event_messages.append(message)
                elif message[0] == 3 and message[2] == str(invocation_id):
                    if message[3] == 1:
                        raise RuntimeError(f"{target} failed: {message[4]}")
                    return message[4] if message[3] == 3 else None

    def event_arguments(self, target):
        return [message[4] for message in self.event_messages if message[3] == target]

    def matchmaking_stages(self):
        stages = []
        for arguments in self.event_arguments("MatchRoomStateChanged"):
            if arguments and arguments[0] and arguments[0][0] == 1:
                stages.append(arguments[0][1][0])
        return stages

    def ranked_stages(self):
        stages = []
        for arguments in self.event_arguments("MatchRoomStateChanged"):
            if arguments and arguments[0] and arguments[0][0] == 2:
                stages.append(arguments[0][1][0])
        return stages


def api_request(origin, token, method, path, body=None, content_type=None):
    request = urllib.request.Request(origin + path, data=body, method=method)
    request.add_header("Authorization", f"Bearer {token}")
    if content_type:
        request.add_header("Content-Type", content_type)
    with urllib.request.urlopen(request, timeout=10) as response:
        return response.status, json.loads(response.read())


def main():
    host, port, token_one, token_two = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    one = WebSocket(host, port, token_one)
    two = WebSocket(host, port, token_two)
    try:
        playlist = [1, 4, 75, "0123456789abcdef0123456789abcdef", 0, [], [], False, 0, None, 1.0, False]
        settings = ["zigcho multiplayer smoke", 1, "", 1, 0, 0, False, 2]
        room = [0, 0, settings, [], None, None, [playlist], [], 0]
        created = one.invoke(1, "CreateRoom", [room])
        room_id = created[0]
        joined = two.invoke(1, "JoinRoomWithPassword", [room_id, ""])
        if joined[0] != room_id or len(joined[3]) != 2:
            raise RuntimeError("second user did not join room")
        one.invoke(2, "ChangeState", [1])
        two.invoke(2, "ChangeState", [1])
        one.invoke(3, "StartMatch", [])
        one.invoke(4, "ChangeState", [3])
        two.invoke(3, "ChangeState", [3])
        one.invoke(5, "ChangeState", [6])
        two.invoke(4, "ChangeState", [6])
        if "LoadRequested" not in one.events or "GameplayStarted" not in two.events or "ResultsReady" not in two.events:
            raise RuntimeError(f"missing lifecycle events one={one.events} two={two.events}")
        origin = f"http://{host}:{port}"
        token_form = urllib.parse.urlencode({
            "version_hash": "11111111111111111111111111111111",
            "beatmap_id": "75",
            "beatmap_hash": "0123456789abcdef0123456789abcdef",
            "ruleset_id": "0",
        }).encode()
        status, token_response = api_request(origin, token_one, "POST", f"/api/v2/rooms/{room_id}/playlist/1/scores", token_form, "application/x-www-form-urlencoded")
        if status != 201 or token_response["id"] <= 0:
            raise RuntimeError("room score token was not created")
        score_body = json.dumps({
            "rank": "A", "total_score": 765432, "total_score_without_mods": 765432,
            "accuracy": 0.95, "max_combo": 9, "ruleset_id": 0, "passed": True,
            "mods": [], "statistics": {"great": 19, "miss": 1},
            "maximum_statistics": {"great": 20}, "pauses": [],
        }).encode()
        status, score_response = api_request(origin, token_one, "PUT", f"/api/v2/rooms/{room_id}/playlist/1/scores/{token_response['id']}", score_body, "application/json")
        if status != 200 or score_response["id"] <= 0:
            raise RuntimeError("room score was not submitted")
        status, results = api_request(origin, token_one, "GET", f"/api/v2/rooms/{room_id}/playlist/1/scores")
        if status != 200 or results["total"] != 1 or results["scores"][0]["id"] != score_response["id"] or results["user_score"]["id"] != score_response["id"]:
            raise RuntimeError(f"room results did not contain submitted score: {results}")
        two.invoke(5, "LeaveRoom", [])
        one.invoke(6, "LeaveRoom", [])

        pools = one.invoke(10, "GetMatchmakingPoolsOfType", [0])
        if not pools or pools[0][0] != 1 or pools[0][1] != 0 or pools[0][4] != 0:
            raise RuntimeError(f"quick play pool unavailable: {pools}")
        one.invoke(11, "MatchmakingJoinLobbyWithParams", [[1]])
        two.invoke(10, "MatchmakingJoinLobbyWithParams", [[1]])
        one.invoke(12, "MatchmakingJoinQueue", [1])
        two.invoke(11, "MatchmakingJoinQueue", [1])
        one.invoke(13, "MatchmakingAcceptInvitation", [])
        two.invoke(12, "MatchmakingAcceptInvitation", [])
        one.invoke(14, "MatchmakingLeaveLobby", [])
        two.invoke(13, "MatchmakingLeaveLobby", [])
        ready_events = two.event_arguments("MatchmakingRoomReady") or one.event_arguments("MatchmakingRoomReady")
        if not ready_events or len(ready_events[-1]) != 2:
            raise RuntimeError(f"matchmaking room was not created: one={one.events} two={two.events}")
        match_room_id, match_password = ready_events[-1]
        match_one = one.invoke(15, "JoinRoomWithPassword", [match_room_id, match_password])
        match_two = two.invoke(14, "JoinRoomWithPassword", [match_room_id, match_password])
        if match_one[0] != match_room_id or match_two[0] != match_room_id or match_two[5][1][0] != 2:
            raise RuntimeError("matched users did not enter beatmap selection")

        score_id = None
        for round_number, playlist_item_id in enumerate((1, 2, 3), start=1):
            stage_offset = len(two.matchmaking_stages())
            event_offset = len(two.events)
            one.invoke(20 + round_number * 10, "MatchmakingToggleSelection", [playlist_item_id])
            if round_number == 1:
                one.invoke(95, "MatchmakingToggleSelection", [playlist_item_id])
            two.invoke(21 + round_number * 10, "MatchmakingToggleSelection", [playlist_item_id])
            stages = two.matchmaking_stages()[stage_offset:]
            if 3 not in stages or 4 not in stages:
                raise RuntimeError(f"round {round_number} did not finalise its beatmap: {stages}")
            one.invoke(22 + round_number * 10, "ChangeState", [1])
            two.invoke(23 + round_number * 10, "ChangeState", [1])
            stages = two.matchmaking_stages()[stage_offset:]
            events = two.events[event_offset:]
            if "LoadRequested" not in events or 5 not in stages or 6 not in stages:
                raise RuntimeError(f"round {round_number} did not request gameplay: {events} {stages}")
            one.invoke(24 + round_number * 10, "ChangeState", [3])
            one.invoke(25 + round_number * 10, "ChangeState", [4])
            two.invoke(24 + round_number * 10, "ChangeState", [3])

            if round_number == 1:
                token_form = urllib.parse.urlencode({
                    "version_hash": "11111111111111111111111111111111",
                    "beatmap_id": "75",
                    "beatmap_hash": "0123456789abcdef0123456789abcdef",
                    "ruleset_id": "0",
                }).encode()
                status, token_response = api_request(origin, token_one, "POST", f"/api/v2/rooms/{match_room_id}/playlist/1/scores", token_form, "application/x-www-form-urlencoded")
                if status != 201 or token_response["id"] <= 0:
                    raise RuntimeError("matchmaking score token was not created")
                score_body = json.dumps({
                    "rank": "A", "total_score": 900000, "total_score_without_mods": 765432,
                    "accuracy": 0.95, "max_combo": 9, "ruleset_id": 0, "passed": True,
                    "mods": [], "statistics": {"great": 19, "miss": 1},
                    "maximum_statistics": {"great": 20}, "pauses": [],
                }).encode()
                status, score_response = api_request(origin, token_one, "PUT", f"/api/v2/rooms/{match_room_id}/playlist/1/scores/{token_response['id']}", score_body, "application/json")
                if status != 200 or score_response["id"] <= 0:
                    raise RuntimeError("matchmaking score was not submitted")
                score_id = score_response["id"]

            one.invoke(26 + round_number * 10, "ChangeState", [6])
            two.invoke(25 + round_number * 10, "ChangeState", [6])
            stages = two.matchmaking_stages()[stage_offset:]
            events = two.events[event_offset:]
            if "ResultsReady" not in events or 7 not in stages:
                raise RuntimeError(f"round {round_number} did not reach results")
            one.invoke(27 + round_number * 10, "ChangeState", [0])
            two.invoke(26 + round_number * 10, "ChangeState", [0])
            expected_stage = 8 if round_number == 3 else 2
            if expected_stage not in two.matchmaking_stages()[stage_offset:]:
                raise RuntimeError(f"round {round_number} did not advance to stage {expected_stage}")

        status, results = api_request(origin, token_one, "GET", f"/api/v2/rooms/{match_room_id}/playlist/1/scores")
        if status != 200 or results["total"] < 1 or results["user_score"]["id"] != score_id:
            raise RuntimeError(f"matchmaking results did not retain the submitted score: {results}")
        two.invoke(90, "LeaveRoom", [])
        one.invoke(91, "LeaveRoom", [])

        ranked_pools = one.invoke(100, "GetMatchmakingPoolsOfType", [1])
        if not ranked_pools or ranked_pools[0][0] != 101 or ranked_pools[0][1] != 0 or ranked_pools[0][4] != 1:
            raise RuntimeError(f"ranked play pool unavailable: {ranked_pools}")
        one.invoke(101, "MatchmakingJoinLobbyWithParams", [[101]])
        two.invoke(100, "MatchmakingJoinLobbyWithParams", [[101]])
        one.invoke(102, "MatchmakingJoinQueue", [101])
        two.invoke(101, "MatchmakingJoinQueue", [101])
        one.invoke(103, "MatchmakingAcceptInvitation", [])
        two.invoke(102, "MatchmakingAcceptInvitation", [])
        one.invoke(104, "MatchmakingLeaveLobby", [])
        two.invoke(103, "MatchmakingLeaveLobby", [])
        ranked_ready = two.event_arguments("MatchmakingRoomReady")[-1]
        ranked_room_id, ranked_password = ranked_ready
        ranked_one = one.invoke(105, "JoinRoomWithPassword", [ranked_room_id, ranked_password])
        one_user_id = ranked_one[3][0][0]
        ranked_two = two.invoke(104, "JoinRoomWithPassword", [ranked_room_id, ranked_password])
        two_user_id = next(user[0] for user in ranked_two[3] if user[0] != one_user_id)
        if ranked_two[5][0] != 2 or ranked_two[5][1][0] != 2:
            raise RuntimeError(f"ranked users did not enter card discard: {ranked_two[5]}")
        one.invoke(106, "DiscardCards", [[]])
        two.invoke(105, "DiscardCards", [[]])
        if 4 not in two.ranked_stages():
            raise RuntimeError(f"ranked match did not enter card play: {two.ranked_stages()}")

        for round_number in (1, 2):
            state_events = two.event_arguments("MatchRoomStateChanged")
            ranked_state = next(args[0][1] for args in reversed(state_events) if args[0][0] == 2)
            active_user_id = ranked_state[4]
            active_card = ranked_state[3][active_user_id][2][0]
            active = one if active_user_id == one_user_id else two
            passive = two if active is one else one
            active.invoke(110 + round_number * 20, "PlayCard", [active_card])
            passive.invoke(111 + round_number * 20, "ChangeState", [1])
            active.invoke(112 + round_number * 20, "ChangeState", [1])
            ranked_stages = one.ranked_stages() + two.ranked_stages()
            if 7 not in ranked_stages:
                raise RuntimeError(f"ranked round {round_number} did not start gameplay: {ranked_stages}")

            reveal = one.event_arguments("RankedPlayCardRevealed")[-1]
            selected_item = reveal[1]
            selected_item_id = selected_item[0]
            selected_beatmap_id = selected_item[2]
            selected_checksum = selected_item[3]
            for token, client, total in ((token_one, one, 900000), (token_two, two, 100000)):
                token_form = urllib.parse.urlencode({
                    "version_hash": "11111111111111111111111111111111",
                    "beatmap_id": str(selected_beatmap_id),
                    "beatmap_hash": selected_checksum,
                    "ruleset_id": "0",
                }).encode()
                status, token_response = api_request(origin, token, "POST", f"/api/v2/rooms/{ranked_room_id}/playlist/{selected_item_id}/scores", token_form, "application/x-www-form-urlencoded")
                if status != 201:
                    raise RuntimeError(f"ranked round {round_number} score token failed")
                score_body = json.dumps({
                    "rank": "A", "total_score": total, "legacy_total_score": total,
                    "total_score_without_mods": total, "accuracy": 0.95, "max_combo": 9,
                    "ruleset_id": 0, "passed": True, "mods": [],
                    "statistics": {"great": 19, "miss": 1}, "maximum_statistics": {"great": 20}, "pauses": [],
                }).encode()
                status, _ = api_request(origin, token, "PUT", f"/api/v2/rooms/{ranked_room_id}/playlist/{selected_item_id}/scores/{token_response['id']}", score_body, "application/json")
                if status != 200:
                    raise RuntimeError(f"ranked round {round_number} score submit failed")

            one.invoke(113 + round_number * 20, "ChangeState", [3])
            two.invoke(113 + round_number * 20, "ChangeState", [3])
            one.invoke(114 + round_number * 20, "ChangeState", [6])
            two.invoke(114 + round_number * 20, "ChangeState", [6])
            if 8 not in two.ranked_stages():
                raise RuntimeError(f"ranked round {round_number} did not reach results: {two.ranked_stages()}")
            one.invoke(115 + round_number * 20, "ChangeState", [0])
            two.invoke(115 + round_number * 20, "ChangeState", [0])

        if 9 not in two.ranked_stages():
            raise RuntimeError(f"ranked match did not end: {two.ranked_stages()}")
        two.invoke(190, "LeaveRoom", [])
        one.invoke(191, "LeaveRoom", [])
        print(f"lazer_multiplayer_ws_smoke_ok room_id={room_id} matchmaking_room_id={match_room_id} ranked_room_id={ranked_room_id}")
    finally:
        one.close()
        two.close()


if __name__ == "__main__":
    main()
