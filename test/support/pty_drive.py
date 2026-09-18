"""Drive a terminal program on a real pty, for the end-to-end client test.

The client puts the terminal into raw mode through the runtime's own tty
driver, so there has to be a terminal for it to own: a pipe is not enough. This
allocates one, types a scripted sequence into it, and returns everything the
program drew.

  DRIVE_SCRIPT   "<seconds>:<keys>|<seconds>:<keys>|..." with \\xNN escapes
  DRIVE_TIMEOUT  seconds before giving up (default 120)
  DRIVE_ROWS     terminal size (default 40x120)
  DRIVE_COLS

Reads until the pty reports EOF rather than stopping when the child exits, so
bytes a program writes on its way out — restoring the terminal, for instance —
are never lost.
"""
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time

rows = int(os.environ.get("DRIVE_ROWS", "40"))
cols = int(os.environ.get("DRIVE_COLS", "120"))
budget = float(os.environ.get("DRIVE_TIMEOUT", "120"))

timeline = []
for item in os.environ["DRIVE_SCRIPT"].split("|"):
    at, _, keys = item.partition(":")
    timeline.append((float(at), keys.encode().decode("unicode_escape")))

pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
start = time.time()
chunks, sent = [], 0

while time.time() - start < budget:
    now = time.time() - start
    while sent < len(timeline) and timeline[sent][0] <= now:
        os.write(fd, timeline[sent][1].encode())
        sent += 1
    readable, _, _ = select.select([fd], [], [], 0.2)
    if fd not in readable:
        continue
    try:
        data = os.read(fd, 65536)
    except OSError:  # EIO: the slave side is closed for good
        break
    if not data:
        break
    chunks.append(data)

try:
    os.waitpid(pid, os.WNOHANG)
except ChildProcessError:
    pass

sys.stdout.buffer.write(b"".join(chunks))
