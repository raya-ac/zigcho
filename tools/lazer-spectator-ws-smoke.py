#!/usr/bin/env python3

import importlib.util
import json
import pathlib
import sys
import urllib.parse


helper_path = pathlib.Path(__file__).with_name("lazer-multiplayer-ws-smoke.py")
spec = importlib.util.spec_from_file_location("zigcho_signalr_smoke", helper_path)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class Hub:
    def __init__(self, host, port, token):
        self.websocket = helper.WebSocket(host, port, token, "/spectator?id=smoke")
        self.pending = []

    def close(self):
        self.websocket.close()

    def send_invocation(self, invocation_id, target, arguments):
        value = None if invocation_id is None else str(invocation_id)
        self.websocket.send(2, helper.signalr_frame([1, {}, value, target, arguments, []]))

    def invoke(self, invocation_id, target, arguments):
        self.send_invocation(invocation_id, target, arguments)
        return self.wait_completion(invocation_id)

    def wait_completion(self, invocation_id):
        expected = str(invocation_id)
        while True:
            message = self.next_message()
            if message[0] == 3 and message[2] == expected:
                if message[3] == 1:
                    raise RuntimeError(f"invocation {invocation_id} failed: {message[4]}")
                return message[4] if message[3] == 3 else None
            self.pending.append(message)

    def wait_event(self, target):
        for index, message in enumerate(self.pending):
            if message[0] == 1 and message[3] == target:
                return self.pending.pop(index)
        while True:
            message = self.next_message()
            if message[0] == 1 and message[3] == target:
                return message
            self.pending.append(message)

    def next_message(self):
        while True:
            opcode, payload = self.websocket.receive()
            if opcode == 9:
                self.websocket.send(10, payload)
                continue
            if opcode != 2:
                continue
            position = 0
            messages = []
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
                message, consumed = helper.unpack(payload[position:position + length])
                if consumed != length:
                    raise RuntimeError("trailing MessagePack bytes")
                messages.append(message)
                position += length
            if not messages:
                continue
            self.pending.extend(messages[1:])
            return messages[0]


def require_event(message, target, expected_arguments):
    if message[0] != 1 or message[3] != target or message[4] != expected_arguments:
        raise RuntimeError(f"unexpected {target} event: {message!r}")


def main():
    host, port, token_one, token_two = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    origin = f"http://{host}:{port}"
    _, one_user = helper.api_request(origin, token_one, "GET", "/api/v2/me")
    _, two_user = helper.api_request(origin, token_two, "GET", "/api/v2/me")
    one_id = one_user["id"]
    two_id = two_user["id"]
    state = [75, 0, [], 1, {}]
    finished_state = [75, 0, [], 3, {}]
    frame_bundle = [[1000, 0.99, 10, 10, {}, {}, None, [], 1000, []], [[123.5, None, None, 1]]]

    token_body = urllib.parse.urlencode({
        "version_hash": "11111111111111111111111111111111",
        "beatmap_hash": "0123456789abcdef0123456789abcdef",
        "ruleset_id": "0",
    }).encode()
    token_status, token_payload = helper.api_request(
        origin,
        token_one,
        "POST",
        "/api/v2/beatmaps/75/solo/scores",
        token_body,
        "application/x-www-form-urlencoded",
    )
    if token_status != 201:
        raise RuntimeError(f"score token failed: {token_status} {token_payload!r}")
    score_token = token_payload["id"]

    host_hub = Hub(host, port, token_one)
    watcher_hub = Hub(host, port, token_two)
    replacement = None
    try:
        watcher_hub.invoke(1, "StartWatchingUser", [one_id])
        started = host_hub.wait_event("UserStartedWatching")
        require_event(started, "UserStartedWatching", [[[two_id, two_user["username"]]]])

        host_hub.invoke(1, "BeginPlaySessionV2", [score_token, state])
        require_event(watcher_hub.wait_event("UserBeganPlaying"), "UserBeganPlaying", [one_id, state])

        host_hub.send_invocation(None, "SendFrameDataV2", [score_token, frame_bundle])
        require_event(watcher_hub.wait_event("UserSentFrames"), "UserSentFrames", [one_id, frame_bundle])

        score_body = json.dumps({
            "rank": "S",
            "total_score": 123456,
            "total_score_without_mods": 123456,
            "accuracy": 0.9,
            "max_combo": 8,
            "ruleset_id": 0,
            "passed": True,
            "mods": [],
            "statistics": {"great": 9, "miss": 1},
            "maximum_statistics": {"great": 10},
            "pauses": [],
            "replay": "ANAnNQEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        }).encode()
        score_status, score_payload = helper.api_request(
            origin,
            token_one,
            "PUT",
            f"/api/v2/beatmaps/75/solo/scores/{score_token}",
            score_body,
            "application/json",
        )
        if score_status != 200:
            raise RuntimeError(f"score submit failed: {score_status} {score_payload!r}")
        score_id = score_payload["id"]

        try:
            host_hub.invoke(99, "EndPlaySessionV2", [score_token + 1, 3])
            raise RuntimeError("mismatched spectator score token was accepted")
        except RuntimeError as error:
            if "mismatched spectator score token" in str(error):
                raise

        host_hub.invoke(2, "EndPlaySessionV2", [score_token, 3])
        require_event(watcher_hub.wait_event("UserFinishedPlaying"), "UserFinishedPlaying", [one_id, finished_state])
        require_event(host_hub.wait_event("UserScoreProcessed"), "UserScoreProcessed", [one_id, score_id])
        require_event(watcher_hub.wait_event("UserScoreProcessed"), "UserScoreProcessed", [one_id, score_id])

        host_hub.invoke(3, "BeginPlaySessionV2", [4243, state])
        require_event(watcher_hub.wait_event("UserBeganPlaying"), "UserBeganPlaying", [one_id, state])
        host_hub.close()
        require_event(watcher_hub.wait_event("UserFinishedPlaying"), "UserFinishedPlaying", [one_id, [75, 0, [], 5, {}]])
        replacement = Hub(host, port, token_one)
        try:
            replacement.invoke(99, "BeginPlaySessionV2", [4343, [9999, 0, [], 1, {}]])
            raise RuntimeError("unknown spectator beatmap was accepted")
        except RuntimeError as error:
            if "unknown spectator beatmap" in str(error):
                raise
        replacement.invoke(1, "BeginPlaySessionV2", [4343, state])
        require_event(watcher_hub.wait_event("UserBeganPlaying"), "UserBeganPlaying", [one_id, state])
        require_event(replacement.wait_event("UserStartedWatching"), "UserStartedWatching", [[[two_id, two_user["username"]]]])
        replacement.invoke(2, "EndPlaySessionV2", [4343, 5])
        require_event(watcher_hub.wait_event("UserFinishedPlaying"), "UserFinishedPlaying", [one_id, [75, 0, [], 5, {}]])

        replacement.invoke(3, "BeginPlaySessionV2", [state, 4443])
        require_event(watcher_hub.wait_event("UserBeganPlaying"), "UserBeganPlaying", [one_id, state])
        replacement.invoke(4, "EndPlaySessionV2", [5, 4443])
        require_event(watcher_hub.wait_event("UserFinishedPlaying"), "UserFinishedPlaying", [one_id, [75, 0, [], 5, {}]])

        watcher_hub.invoke(2, "EndWatchingUser", [one_id])
        require_event(replacement.wait_event("UserEndedWatching"), "UserEndedWatching", [two_id])
        print(f"lazer_spectator_ws_smoke_ok host_id={one_id} watcher_id={two_id}")
    finally:
        if replacement is not None:
            replacement.close()
        else:
            try:
                host_hub.close()
            except OSError:
                pass
        watcher_hub.close()


if __name__ == "__main__":
    main()
