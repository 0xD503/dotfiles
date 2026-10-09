#!/usr/bin/env python3
"""A stand-in debug adapter for the MEGA 2.0 tests.

It speaks the Debug Adapter Protocol on standard input and output and
behaves the way gdb 16 was seen to (`gdb -i=dap'), quirks included:

  * it prints a banner as output events before it answers anything;
  * it answers `launch' only once `configurationDone' has arrived;
  * breakpoints are unverified at first;
  * frame ids are new after every stop, and an old one is an error.

The "program" stops at the first breakpoint it is given, in a function
`square' called from `main', and prints 9 when it is continued to its end.
Every request received is appended, as one line of JSON, to the file named
by MEGA_FAKE_DAP_LOG.
"""

import json
import os
import sys

LOG = os.environ.get("MEGA_FAKE_DAP_LOG")
out = sys.stdout.buffer
seq = 0
launch = None          # the launch request, answered late
source = None          # the path breakpoints were set in
lines = []             # ...and their lines
line = 0               # where the program is
stops = 0              # how many times it has stopped


def send(message):
    global seq
    seq += 1
    message["seq"] = seq
    body = json.dumps(message, ensure_ascii=False).encode("utf-8")
    out.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    out.flush()


def event(name, body=None):
    message = {"type": "event", "event": name}
    if body is not None:
        message["body"] = body
    send(message)


def respond(request, body=None, success=True, message=None):
    answer = {"type": "response", "request_seq": request["seq"],
              "command": request["command"], "success": success}
    if body is not None:
        answer["body"] = body
    if message is not None:
        answer["message"] = message
    send(answer)


def log(message):
    if LOG:
        with open(LOG, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(message, ensure_ascii=False) + "\n")


def stop(reason):
    global stops
    stops += 1
    event("stopped", {"threadId": 1, "allThreadsStopped": True, "reason": reason})


def finish():
    event("output", {"category": "stdout", "output": "9\n"})
    event("thread", {"reason": "exited", "threadId": 1})
    event("exited", {"exitCode": 0})
    event("terminated")


def read():
    header = b""
    while not header.endswith(b"\r\n\r\n"):
        byte = sys.stdin.buffer.read(1)
        if not byte:
            return None
        header += byte
    length = int(header.split(b":")[1].strip().split(b"\r\n")[0])
    return json.loads(sys.stdin.buffer.read(length).decode("utf-8"))


def handle(request):
    global launch, source, lines, line
    command = request.get("command")
    arguments = request.get("arguments") or {}
    if command == "initialize":
        event("output", {"category": "stdout", "output": "GNU gdb (stand-in) 16.3\n"})
        respond(request, {"supportsConfigurationDoneRequest": True})
        event("initialized")
    elif command == "launch":
        launch = request
    elif command == "setBreakpoints":
        source = arguments["source"]["path"]
        lines = [point["line"] for point in arguments["breakpoints"]]
        respond(request, {"breakpoints": [{"id": index + 1, "verified": False,
                                           "reason": "pending"}
                                          for index in range(len(lines))]})
        event("output", {"category": "stdout", "output": "Breakpoint 1 pending.\n"})
    elif command == "configurationDone":
        respond(request)
        if launch is not None:
            respond(launch)
        event("process", {"name": (launch or {}).get("arguments", {}).get("program")})
        event("output", {"category": "telemetry", "output": "not for the user\n"})
        # Something an adapter may ask of its client; MEGA must say no.
        send({"type": "request", "command": "runInTerminal",
              "arguments": {"args": ["true"]}})
        if lines:
            line = lines[0]
            stop("breakpoint")
        else:
            finish()
    elif command == "threads":
        respond(request, {"threads": [{"id": 1, "name": "prog"}]})
    elif command == "stackTrace":
        frames = [{"id": stops * 10, "name": "square", "line": line, "column": 0,
                   "source": {"name": os.path.basename(source), "path": source}},
                  {"id": stops * 10 + 1, "name": "main", "line": 11, "column": 0,
                   "source": {"name": os.path.basename(source), "path": source}},
                  {"id": stops * 10 + 2, "name": "__libc_start_call_main",
                   "line": 0, "column": 0}]
        respond(request, {"stackFrames": frames})
    elif command == "scopes":
        frame = arguments["frameId"]
        if frame // 10 != stops:
            respond(request, success=False, message="list index out of range")
        else:
            respond(request, {"scopes": [
                {"name": "Registers", "variablesReference": 900, "expensive": True},
                {"name": "Locals", "variablesReference": frame + 100, "expensive": False}]})
    elif command == "variables":
        reference = arguments["variablesReference"]
        if reference == 900:
            respond(request, {"variables": [{"name": "rip", "value": "0x1157",
                                             "variablesReference": 0}]})
        elif (reference - 100) % 10 == 0:
            respond(request, {"variables": [
                {"name": "x", "value": "3", "variablesReference": 0}]})
        else:
            respond(request, {"variables": [
                {"name": "a", "value": "3", "variablesReference": 0},
                {"name": "b", "value": "ünïcödé", "variablesReference": 0}]})
    elif command in ("next", "stepIn", "stepOut"):
        respond(request)
        line += 1
        stop("step")
    elif command == "continue":
        respond(request, {"allThreadsContinued": True})
        event("continued", {"threadId": 1, "allThreadsContinued": True})
        finish()
    elif command == "evaluate":
        if arguments.get("frameId", -1) // 10 != stops:
            respond(request, success=False, message="list index out of range")
        else:
            respond(request, {"result": "9", "variablesReference": 0})
    elif command == "disconnect":
        respond(request)
        return False
    else:
        respond(request, success=False, message="unknown request")
    return True


def main():
    while True:
        message = read()
        if message is None:
            return
        log(message)
        if message.get("type") == "request" and not handle(message):
            return


if __name__ == "__main__":
    main()
