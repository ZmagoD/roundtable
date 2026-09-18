import json
import sys

request = json.loads(sys.stdin.readline())
# Deliberately split a JSON line across writes.
sys.stdout.write('{"type":"session",')
sys.stdout.flush()
sys.stdout.write('"id":"fixture-session"}\n')
sys.stdout.flush()
print(json.dumps({"type": "approval", "id": "fixture-request"}), flush=True)
approval = json.loads(sys.stdin.readline())
print(json.dumps({"type": "text", "text": "Approved" if approval["decision"] == "accept" else "Declined"}), flush=True)
print(json.dumps({"type": "done"}), flush=True)
