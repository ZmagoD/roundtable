"""A pty for the browser terminal.

The BEAM cannot allocate a pty, and a process it spawns has no controlling
terminal at all — it starts each one in a new session. A shell without a
terminal is not a shell: no job control, no curses, no line editing. So this
allocates one, runs the shell inside it, and relays bytes over the port.

Protocol, one JSON object per line in each direction. Payloads are base64
because terminal output is arbitrary bytes and the transport is text.

  in   {"data": "<base64>"}          keystrokes
       {"resize": [rows, columns]}   the browser window changed
  out  {"data": "<base64>"}          whatever the shell drew
       {"exit": <status>}            the shell is gone
"""
import base64
import fcntl
import json
import os
import pty
import select
import struct
import sys
import termios

shell = os.environ.get("SHELL") or "/bin/sh"

pid, fd = pty.fork()
if pid == 0:
    # A login shell would re-read the profile and print its banner; this is a
    # terminal inside a room, not a login session.
    os.execvp(shell, [shell, "-i"])


def emit(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def resize(rows, columns):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))


resize(24, 80)
buffer = b""

while True:
    try:
        readable, _, _ = select.select([fd, sys.stdin.buffer], [], [])
    except (OSError, ValueError):
        break

    if fd in readable:
        try:
            output = os.read(fd, 65536)
        except OSError:  # EIO: the shell exited and the pty closed
            break
        if not output:
            break
        emit({"data": base64.b64encode(output).decode()})

    if sys.stdin.buffer in readable:
        chunk = sys.stdin.buffer.read1(65536)
        if not chunk:  # the BEAM went away; the shell has no one to talk to
            break
        buffer += chunk
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            if not line.strip():
                continue
            command = json.loads(line)
            if "data" in command:
                os.write(fd, base64.b64decode(command["data"]))
            elif "resize" in command:
                resize(*command["resize"])

os.close(fd)
_, status = os.waitpid(pid, 0)
emit({"exit": os.waitstatus_to_exitcode(status)})
