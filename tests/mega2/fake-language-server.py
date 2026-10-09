#!/usr/bin/env python3
"""A scripted language server for the MEGA tests.

It speaks just enough of the Language Server Protocol over stdin/stdout for
eglot to connect, ask for completions and hover text, and shut down.  Every
request it receives is appended, one method name per line, to the file named
by MEGA_TEST_LSP_LOG, so a test can check what the editor really asked.
"""

import json
import os
import sys


def read_message():
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            break
        name, _, value = line.partition(b":")
        if name.lower() == b"content-length":
            length = int(value)
    if length is None:
        return None
    return json.loads(sys.stdin.buffer.read(length))


def send(message):
    body = json.dumps(message).encode("utf-8")
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body))
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


def reply(request, result):
    send({"jsonrpc": "2.0", "id": request["id"], "result": result})


def main():
    log = os.environ.get("MEGA_TEST_LSP_LOG")
    while True:
        message = read_message()
        if message is None:
            return
        method = message.get("method")
        if log and method:
            with open(log, "a") as handle:
                handle.write(method + "\n")
        if method == "initialize":
            reply(message, {
                "capabilities": {
                    "textDocumentSync": 1,
                    "completionProvider": {},
                    "hoverProvider": True,
                },
                "serverInfo": {"name": "mega-fake-server"},
            })
        elif method == "textDocument/completion":
            reply(message, [
                {"label": "server_alpha", "kind": 3, "detail": "fn()"},
                {"label": "server_beta", "kind": 6, "detail": "i32"},
            ])
        elif method == "textDocument/hover":
            reply(message, {"contents": "Documentation from the fake server"})
        elif method == "shutdown":
            reply(message, None)
        elif method == "exit":
            return
        elif "id" in message and method:
            reply(message, None)


if __name__ == "__main__":
    main()
