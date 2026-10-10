#!/usr/bin/env python3
"""A scripted language server for the MEGA tests.

It speaks enough of the Language Server Protocol over stdin/stdout for eglot
to do with it what it does with a real server: complete, with the kinds of
answer real servers give; show documentation; report problems; format; and
be asked for its settings.

What it is told is written down, so that a test can check what the editor
really said and not what a variable holds:

  MEGA_TEST_LSP_LOG    every method received, one per line
  MEGA_TEST_LSP_SEEN   one JSON object per line: the options it was started
                       with, the settings it was sent, and the answers to
                       its own question about settings

  MEGA_TEST_LSP_HANG   a method that is never answered, to test patience

Completions, for whatever is being typed:

  server_alpha, server_beta   bare labels
  server_edit                 a text edit that replaces the word, and a
                              second edit that adds a line at the top
  server_snippet              a snippet, offered only to an editor that
                              said it can expand one

A line containing BUG gets a diagnostic.  Formatting strips the spaces at
the ends of lines and squeezes runs of spaces inside them.
"""

import json
import os
import re
import sys

DOCUMENTS = {}
QUESTION = "mega-fake-server-settings"


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


def note(what, **more):
    seen = os.environ.get("MEGA_TEST_LSP_SEEN")
    if seen:
        with open(seen, "a") as handle:
            handle.write(json.dumps(dict(more, what=what)) + "\n")


def diagnose(uri):
    found = []
    for number, line in enumerate(DOCUMENTS.get(uri, "").split("\n")):
        column = line.find("BUG")
        if column >= 0:
            found.append({
                "range": {"start": {"line": number, "character": column},
                          "end": {"line": number, "character": column + 3}},
                "severity": 1,
                "source": "mega-fake-server",
                "message": "A bug, by its own admission",
            })
    send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
          "params": {"uri": uri, "diagnostics": found}})


def complete(params, snippets):
    uri = params["textDocument"]["uri"]
    line = params["position"]["line"]
    end = params["position"]["character"]
    lines = DOCUMENTS.get(uri, "").split("\n")
    text = lines[line] if line < len(lines) else ""
    start = end
    while start > 0 and re.match(r"\w", text[start - 1]):
        start -= 1
    word = {"start": {"line": line, "character": start},
            "end": {"line": line, "character": end}}
    top = {"start": {"line": 0, "character": 0},
           "end": {"line": 0, "character": 0}}
    items = [
        {"label": "server_alpha", "kind": 3, "detail": "fn()"},
        {"label": "server_beta", "kind": 6, "detail": "i32"},
        {"label": "server_edit", "kind": 3,
         "textEdit": {"range": word, "newText": "server_edit_done"},
         "additionalTextEdits": [{"range": top,
                                  "newText": "use server::edit;\n"}]},
    ]
    if snippets:
        items.append({"label": "server_snippet", "kind": 3,
                      "insertTextFormat": 2,
                      "insertText": "server_snippet(${1:first}, ${2:second})$0"})
    return {"isIncomplete": False, "items": items}


def formatted(uri):
    text = DOCUMENTS.get(uri, "")
    lines = text.split("\n")
    new = "\n".join(re.sub(r"(?<=\S) {2,}(?=\S)", " ", line).rstrip()
                    for line in lines)
    if new == text:
        return []
    return [{"range": {"start": {"line": 0, "character": 0},
                       "end": {"line": len(lines) - 1,
                               "character": len(lines[-1])}},
             "newText": new}]


def main():
    log = os.environ.get("MEGA_TEST_LSP_LOG")
    hang = os.environ.get("MEGA_TEST_LSP_HANG")
    snippets = False
    while True:
        message = read_message()
        if message is None:
            return
        method = message.get("method")
        if log and method:
            with open(log, "a") as handle:
                handle.write(method + "\n")
        if method is None:
            # An answer to a question of ours.
            if message.get("id") == QUESTION:
                note("configuration", result=message.get("result"))
            continue
        if method == hang:
            continue
        params = message.get("params") or {}
        if method == "initialize":
            try:
                snippets = bool(params["capabilities"]["textDocument"]
                                ["completion"]["completionItem"]
                                ["snippetSupport"])
            except (KeyError, TypeError):
                snippets = False
            note("initialize",
                 options=params.get("initializationOptions"),
                 snippets=snippets)
            reply(message, {
                "capabilities": {
                    "textDocumentSync": 1,
                    "completionProvider": {},
                    "hoverProvider": True,
                    "documentFormattingProvider": True,
                },
                "serverInfo": {"name": "mega-fake-server"},
            })
        elif method == "initialized":
            send({"jsonrpc": "2.0", "id": QUESTION,
                  "method": "workspace/configuration",
                  "params": {"items": [{"section": "telemetry"},
                                       {"section": "redhat"},
                                       {"section": "gopls"}]}})
        elif method == "workspace/didChangeConfiguration":
            note("settings", settings=params.get("settings"))
        elif method == "textDocument/didOpen":
            document = params["textDocument"]
            DOCUMENTS[document["uri"]] = document["text"]
            diagnose(document["uri"])
        elif method == "textDocument/didChange":
            uri = params["textDocument"]["uri"]
            for change in params.get("contentChanges", []):
                DOCUMENTS[uri] = change["text"]
            diagnose(uri)
        elif method == "textDocument/didClose":
            DOCUMENTS.pop(params["textDocument"]["uri"], None)
        elif method == "textDocument/completion":
            reply(message, complete(params, snippets))
        elif method == "textDocument/hover":
            reply(message, {"contents": "Documentation from the fake server"})
        elif method == "textDocument/formatting":
            reply(message, formatted(params["textDocument"]["uri"]))
        elif method == "shutdown":
            reply(message, None)
        elif method == "exit":
            return
        elif "id" in message:
            reply(message, None)


if __name__ == "__main__":
    main()
