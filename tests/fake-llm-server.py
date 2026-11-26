#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""A stand-in for an OpenAI-compatible chat completions server.

The auto-naming end-to-end tests point the app at this instead of a real
model. It listens on a free port on 127.0.0.1, prints the port on its first
line of output, and appends one tab-separated line per request it receives
to the log file named on its command line:

    path  authorization  model  thinking-flags(0|1)  image-size(WxH)

The request path picks the behaviour:

    /ok            answers with a dated name for a person's insurance claim
    /nodate        answers with a name that has no date or person
    /empty         answers with empty content, as a reasoning model does when
                   it runs out of tokens
    /reject-flags  refuses requests carrying thinking flags, like a server
                   that rejects parameters it does not know, then answers
    anything else  same as /ok

It exits when its standard input closes, so it never outlives the test
that started it.

A request whose body is not valid JSON gets an error, so every test also
checks that the app sends well-formed JSON.
"""

import base64
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPLIES = {
    "/ok": "2026-10-30|Jordan Sample|Explanation of Benefits from BlueCross",
    "/nodate": "NONE|NONE|Owner's Manual Cordless Drill",
    "/empty": "",
}

log = open(sys.argv[1], "a", buffering=1)


def jpeg_size(data):
    """Width x height from a JPEG's start-of-frame marker, or '?'."""
    i = 2
    while i + 9 < len(data) and data[i] == 0xFF:
        marker = data[i + 1]
        length = int.from_bytes(data[i + 2:i + 4], "big")
        if marker in (0xC0, 0xC1, 0xC2):
            h = int.from_bytes(data[i + 5:i + 7], "big")
            w = int.from_bytes(data[i + 7:i + 9], "big")
            return f"{w}x{h}"
        i += 2 + length
    return "?"


def image_size(request):
    for message in request.get("messages", []):
        content = message.get("content")
        if not isinstance(content, list):
            continue
        for part in content:
            url = part.get("image_url", {}).get("url", "")
            prefix = "data:image/jpeg;base64,"
            if url.startswith(prefix):
                return jpeg_size(base64.b64decode(url[len(prefix):]))
    return "-"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            request = json.loads(raw)
        except ValueError:
            log.write(f"{self.path}\tINVALID-JSON\t\t\t\n")
            return self.reply(400, {"error": {"message": "request is not valid JSON"}})

        flags = "reasoning_effort" in request or "chat_template_kwargs" in request
        log.write("\t".join([self.path,
                             self.headers.get("Authorization", ""),
                             str(request.get("model", "")),
                             "1" if flags else "0",
                             image_size(request)]) + "\n")

        if self.path == "/reject-flags" and flags:
            return self.reply(400, {"error": {"message": "unrecognized request argument"}})

        content = REPLIES.get(self.path, REPLIES["/ok"])
        self.reply(200, {"object": "chat.completion",
                         "choices": [{"index": 0,
                                      "message": {"role": "assistant", "content": content},
                                      "finish_reason": "stop" if content else "length"}]})


def exit_with_parent():
    sys.stdin.read()
    os._exit(0)


threading.Thread(target=exit_with_parent, daemon=True).start()
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
