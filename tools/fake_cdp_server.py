#!/usr/bin/env python3
"""Fake CDP endpoint for tools/test_cdpreq.lua.

Speaks just enough of the DevTools websocket to exercise the blocking one-shot
client: the HTTP 101 upgrade, one masked client frame in, and a scripted reply.
Usage: fake_cdp_server.py <mode> <port-file>

modes
  ok                 answer the command with a string result
  noise-then-result  an unrelated event and a mismatched id first
  error              a protocol-level error for that id
  exception          a Runtime.evaluate exceptionDetails result
  no-upgrade         refuse the websocket upgrade
  silent             upgrade, then never answer
"""
import json
import os
import socket
import struct
import sys
import time

mode, port_file = sys.argv[1], sys.argv[2]

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(1)
tmp = port_file + ".tmp"
with open(tmp, "w") as fh:
    fh.write(str(srv.getsockname()[1]))
os.replace(tmp, port_file)  # atomic: the test only ever sees a complete port
srv.settimeout(20)


def text_frame(payload: bytes) -> bytes:
    """Server->client frames are unmasked."""
    n = len(payload)
    if n < 126:
        header = bytes([0x81, n])
    elif n < 65536:
        header = bytes([0x81, 126]) + struct.pack(">H", n)
    else:
        header = bytes([0x81, 127]) + struct.pack(">Q", n)
    return header + payload


def read_client_frame(conn) -> dict:
    buf = b""
    while True:
        if len(buf) >= 2:
            length = buf[1] & 0x7F
            offset = 2
            if length == 126 and len(buf) >= 4:
                length, offset = struct.unpack(">H", buf[2:4])[0], 4
            elif length == 127 and len(buf) >= 10:
                length, offset = struct.unpack(">Q", buf[2:10])[0], 10
            masked = bool(buf[1] & 0x80)
            need = offset + (4 if masked else 0) + length
            if len(buf) >= need:
                mask = buf[offset:offset + 4] if masked else b""
                body = buf[offset + len(mask):need]
                if masked:
                    body = bytes(b ^ mask[i % 4] for i, b in enumerate(body))
                return json.loads(body)
        chunk = conn.recv(4096)
        if not chunk:
            raise SystemExit(0)
        buf += chunk


conn, _ = srv.accept()
conn.settimeout(20)
request = b""
while b"\r\n\r\n" not in request:
    chunk = conn.recv(1)
    if not chunk:
        raise SystemExit(0)
    request += chunk

if mode == "no-upgrade":
    conn.sendall(b"HTTP/1.1 500 Nope\r\nContent-Length: 0\r\n\r\n")
    conn.close()
    raise SystemExit(0)

conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
             b"Connection: Upgrade\r\nSec-WebSocket-Accept: x\r\n\r\n")

command = read_client_frame(conn)
cid = command.get("id")

if mode == "silent":
    time.sleep(4)
    conn.close()
    raise SystemExit(0)

replies = []
if mode == "noise-then-result":
    replies.append({"method": "Runtime.consoleAPICalled", "params": {}})
    replies.append({"id": cid + 41, "result": {"wrong": True}})
if mode == "error":
    replies.append({"id": cid, "error": {"code": -32000, "message": "nope"}})
elif mode == "exception":
    replies.append({"id": cid, "result": {"exceptionDetails": {"text": "boom"}}})
else:
    replies.append({"id": cid, "result": {"result": {"type": "string", "value": "hello"}}})

for reply in replies:
    conn.sendall(text_frame(json.dumps(reply).encode()))
time.sleep(0.5)
conn.close()
