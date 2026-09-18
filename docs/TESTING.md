# Validation

`mix test` exercises transactional message delivery, mention routing, delegation
limits, queue serialization, concurrent participants, persisted session IDs,
approval scoping, stopping/resetting, recovery, LiveView interaction, and port
fallback without contacting a model. It also covers profiles, room-management
tools, recurring schedules, and the team-builder flow from form submission
through worker dispatch, approval and completion.

## Automated checks

```sh
mix precommit
mix test --only pty
mix test --cover
```

`mix precommit` runs the default suite with compilation, formatting and Credo
checks. The `:pty` tests run separately because they start a second VM and drive
a real terminal. `mix test --include pty` runs both groups together.

The latest local validation on 2026-09-18 passed 405 default tests and all four
terminal integration tests. The team-builder's 30 new executable Elixir lines
were covered. Overall coverage was 81.30%, below the default 90% threshold;
`mix test --cover` therefore exits with a coverage failure even when its tests
pass. HTML reports are in `cover/`. Second-VM terminal execution is not captured
by the parent report, and there are also uncovered paths elsewhere.

## Optional provider checks

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

## Mention autocomplete in a browser

`test/browser/mentions.cjs` checks the actual dropdown in Chromium: hit testing
catches clipping that a DOM visibility assertion misses. It also checks prefix
filtering, keyboard and mouse completion, caret replacement, LiveView updates,
Escape, multiline input and mobile layout. It never submits a message.

Run it against an isolated test instance with a temporary database, real agent
execution disabled (`MIX_ENV=test`), and an empty room containing `manager`,
`maintainer` and `reviewer`. Build assets with `mix assets.deploy` so compressed
bundles match the source. With Playwright available:

```sh
ROUNDTABLE_TEST_URL=http://127.0.0.1:4437 node test/browser/mentions.cjs
```

Set `PLAYWRIGHT_MODULE` to an existing Playwright module path if it is not on
Node's lookup path, and `CHROMIUM` to override `/usr/bin/chromium`.
