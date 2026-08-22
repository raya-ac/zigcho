#!/usr/bin/env python3
import os
import socket
import ssl
import sys
import time


host = os.environ.get("ZIGCHO_IRC_HOST", "irc.kai.ovh")
port = int(os.environ.get("ZIGCHO_IRC_PORT", "6697"))
username = os.environ.get("ZIGCHO_IRC_USER", "").replace(" ", "_")
password = os.environ.get("ZIGCHO_IRC_PASSWORD", "")
if not username or not password:
    print("set ZIGCHO_IRC_USER and ZIGCHO_IRC_PASSWORD", file=sys.stderr)
    raise SystemExit(2)

context = ssl.create_default_context()
with socket.create_connection((host, port), timeout=8) as plain:
    with context.wrap_socket(plain, server_hostname=host) as client:
        client.settimeout(0.25)
        client.sendall(
            (
                "CAP LS 302\r\n"
                f"PASS {password}\r\n"
                f"NICK {username}\r\n"
                f"USER {username} 0 * :zigcho acceptance\r\n"
                "CAP END\r\n"
            ).encode("utf-8")
        )
        response = bytearray()
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline and f" 376 {username} ".encode() not in response:
            try:
                chunk = client.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                break
            response.extend(chunk)
        required = (
            f" 001 {username} ".encode(),
            f":{username}!zigcho@kai.ovh JOIN #osu".encode(),
            f":{username}!zigcho@kai.ovh JOIN #announce".encode(),
        )
        if any(fragment not in response for fragment in required):
            print(response.decode("utf-8", "replace"), file=sys.stderr)
            raise SystemExit("IRC registration contract failed")
        client.sendall(b"PING :zigcho-smoke\r\n")
        pong = bytearray()
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline and b"PONG irc.kai.ovh :zigcho-smoke" not in pong:
            try:
                chunk = client.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                break
            pong.extend(chunk)
        if b"PONG irc.kai.ovh :zigcho-smoke" not in pong:
            raise SystemExit("IRC ping contract failed")
        client.sendall(b"QUIT :smoke complete\r\n")

print(f"irc smoke ok host={host} port={port} nick={username}")
