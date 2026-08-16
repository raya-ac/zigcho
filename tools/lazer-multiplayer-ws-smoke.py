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
                elif message[0] == 3 and message[2] == str(invocation_id):
                    if message[3] == 1:
                        raise RuntimeError(f"{target} failed: {message[4]}")
                    return message[4] if message[3] == 3 else None


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
        print(f"lazer_multiplayer_ws_smoke_ok room_id={room_id}")
    finally:
        one.close()
        two.close()


if __name__ == "__main__":
    main()
