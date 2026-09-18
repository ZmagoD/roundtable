# Validation

`mix test` exercises transactional message delivery, mention routing, delegation
limits, queue serialization, concurrent participants, persisted session IDs,
approval scoping, stopping/resetting, recovery, LiveView interaction, and port
fallback without contacting a model.

For a real-provider smoke check, log in to the CLI in a terminal, create a room
pointing at a disposable directory, add one participant, and ask it to reply with
a fixed short phrase without tools. Send a follow-up asking it to recall that
phrase to confirm native session resume. Repeat for each provider you use.
A real smoke check consumes the provider's normal usage allowance.

For permission handling, request a harmless action that your provider's existing
policy requires approval for. Confirm the chat shows the request, decline it,
and verify the action was not performed. Do not weaken your policy for a test.

For interruption recovery, stop the service during a turn and restart it. The
run should be shown as interrupted, and must not be replayed automatically.
Queued assignments should retain their order. For a port collision, bind 4317
with a disposable local server and verify Roundtable selects 4318 or another
available port above it; both 3000 and 4000 are explicitly reserved.

## Initial validation (2026-09-18)

- 22 automated tests passed, including a custom adapter using the real subprocess
  bridge, fragmented JSON, a permission response, persisted output, model/cost
  snapshots, provider validation, and switching back from a premium model.
- Headless Chromium: create a room, add three providers, post a message, reload
  and recover state; no JavaScript errors or mobile horizontal overflow.
- The production release bound to 4318 while 4317 was occupied, confirming
  automatic port fallback with a real web server.
- Real installed Codex, Claude Code, and OpenCode: a fresh session and a resumed
  session each returned the expected phrase. All six turns completed and the
  native session IDs were persisted. These were tool-free transport tests;
  they do not validate every provider tool or approval variation.

These results describe this machine's installed providers; they do not guarantee
compatibility with every CLI release or authentication setup.
