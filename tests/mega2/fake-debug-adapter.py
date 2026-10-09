#!/usr/bin/env python3
"""A stand-in debug adapter for the MEGA 2.0 tests.

It speaks the Debug Adapter Protocol on standard input and output and
behaves the way real adapters were seen to, quirks included.  By default
that is gdb 16 (`gdb -i=dap'):

  * it prints a banner as output events before it answers anything;
  * it says "initialized" at once, and answers `launch' only once
    `configurationDone' has arrived;
  * breakpoints are unverified at first;
  * frame ids are new after every stop, and an old one is an error.

With MEGA_FAKE_DAP_STYLE=lldb it is lldb-dap 19 instead:

  * no banner; "initialized" comes only after `launch' has been answered;
  * a step is announced by a "continued" event before it is answered;
  * the thread is the process id, and frame ids repeat from stop to stop;
  * the program's output ends its lines with a carriage return as well;
  * told to disconnect, it answers, crashes, and prints the backtrace as
    output on its way down.

The "program" stops at the first breakpoint it is given, in a function
`square' called from `main', and prints 9 when it is continued to its end.
Every request received is appended, as one line of JSON, to the file named
by MEGA_FAKE_DAP_LOG.
"""

import json
import os
import sys

LOG = os.environ.get("MEGA_FAKE_DAP_LOG")
LLDB = os.environ.get("MEGA_FAKE_DAP_STYLE") == "lldb"
THREAD = 20 if LLDB else 1
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
    event("stopped", {"threadId": THREAD, "allThreadsStopped": True, "reason": reason})


def frame_id(index):
    """The id of the frame INDEX levels out from where the program is."""
    return 524288 + index if LLDB else stops * 10 + index


def stale(frame):
    """True if FRAME is an id from an earlier stop that is no longer valid."""
    return not LLDB and frame // 10 != stops


def finish():
    if LLDB:
        event("output", {"category": "stdout", "output": "9\r\n"})
        event("output", {"category": "console",
                         "output": "Process 20 exited with status = 0 (0x00000000) \n"})
    else:
        event("output", {"category": "stdout", "output": "9\n"})
        event("thread", {"reason": "exited", "threadId": THREAD})
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
        if not LLDB:
            event("output", {"category": "stdout", "output": "GNU gdb (stand-in) 16.3\n"})
        respond(request, {"supportsConfigurationDoneRequest": True})
        if not LLDB:
            event("initialized")
    elif command == "launch":
        if LLDB:
            respond(request)
            event("process", {"name": arguments.get("program")})
            event("initialized")
        else:
            launch = request
    elif command == "setBreakpoints":
        source = arguments["source"]["path"]
        lines = [point["line"] for point in arguments["breakpoints"]]
        respond(request, {"breakpoints": [{"id": index + 1, "verified": LLDB}
                                          for index in range(len(lines))]})
        event("output", {"category": "stdout", "output": "Breakpoint 1 pending.\n"})
    elif command == "configurationDone":
        respond(request)
        if launch is not None:
            respond(launch)
            event("process", {"name": launch.get("arguments", {}).get("program")})
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
        frames = [{"id": frame_id(0), "name": "square", "line": line, "column": 0,
                   "source": {"name": os.path.basename(source), "path": source}},
                  {"id": frame_id(1), "name": "main", "line": 11, "column": 0,
                   "source": {"name": os.path.basename(source), "path": source}},
                  {"id": frame_id(2), "name": "__libc_start_call_main",
                   "line": 0, "column": 0}]
        respond(request, {"stackFrames": frames})
    elif command == "scopes":
        frame = arguments["frameId"]
        if stale(frame):
            respond(request, success=False, message="list index out of range")
        elif LLDB:
            respond(request, {"scopes": [
                {"name": "Locals", "variablesReference": frame + 100, "expensive": False},
                {"name": "Globals", "variablesReference": 901, "expensive": False},
                {"name": "Registers", "variablesReference": 900, "expensive": False}]})
        else:
            respond(request, {"scopes": [
                {"name": "Registers", "variablesReference": 900, "expensive": True},
                {"name": "Locals", "variablesReference": frame + 100, "expensive": False}]})
    elif command == "variables":
        reference = arguments["variablesReference"]
        if reference >= 900 and reference < 1000:
            respond(request, {"variables": [{"name": "rip", "value": "0x1157",
                                             "variablesReference": 0}]})
        elif (reference - 100) % 10 == 0 or (LLDB and reference - 100 == 524288):
            respond(request, {"variables": [
                {"name": "x", "value": "3", "variablesReference": 0}]})
        else:
            respond(request, {"variables": [
                {"name": "a", "value": "3", "variablesReference": 0},
                {"name": "b", "value": "ünïcödé", "variablesReference": 0}]})
    elif command in ("next", "stepIn", "stepOut"):
        if LLDB:
            event("continued", {"threadId": THREAD, "allThreadsContinued": True})
        respond(request)
        line += 1
        stop("step")
    elif command == "continue":
        respond(request, {"allThreadsContinued": True})
        event("continued", {"threadId": THREAD, "allThreadsContinued": True})
        finish()
    elif command == "evaluate":
        if stale(arguments.get("frameId", -1)):
            respond(request, success=False, message="list index out of range")
        else:
            respond(request, {"result": "9", "variablesReference": 0})
    elif command == "disconnect":
        respond(request)
        if LLDB:
            event("output", {"category": "stderr", "output": "free(): invalid pointer\n"})
            event("output", {"category": "stderr",
                             "output": "PLEASE submit a bug report and include the crash backtrace.\n"})
            sys.stdout.flush()
            os._exit(134)
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
