"""JSON control bridge for isolated CLI process groups and half-closing stdin.

Input: {argv: [...]} followed by {write: "..."} or {close_stdin: true}.
Output: the CLI's unmodified stdout/stderr. No shell is involved.
"""
import json
import os
import signal
import subprocess
import sys
import threading

if os.getpgrp() != os.getpid():
    os.setsid()


def terminate_group():
    os.killpg(os.getpgrp(), signal.SIGTERM)


config = json.loads(sys.stdin.buffer.readline())
child = subprocess.Popen(config["argv"], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def forward_input():
    try:
        for line in sys.stdin.buffer:
            command = json.loads(line)
            if command.get("close_stdin"):
                child.stdin.close()
            elif "write" in command and not child.stdin.closed:
                child.stdin.write(command["write"].encode())
                child.stdin.flush()
        # The BEAM disappeared. Do not leave agents running unsupervised.
        terminate_group()
    except (BrokenPipeError, ValueError):
        pass


threading.Thread(target=forward_input, daemon=True).start()
try:
    while True:
        data = os.read(child.stdout.fileno(), 8192)
        if not data:
            break
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
    code = child.wait()
except BrokenPipeError:
    terminate_group()
    code = 1
# The input reader is intentionally blocked until the BEAM closes its pipe.
# Avoid Python finalization racing that daemon thread's buffered stdin lock.
sys.stdout.buffer.flush()
os._exit(code if code >= 0 else 128 - code)
