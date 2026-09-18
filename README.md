# Roundtable

A local workspace where you and your coding agents share a conversation.
Built with Phoenix LiveView, OTP, and SQLite. Bring multiple named Codex,
Claude Code, and OpenCode sessions into one room, assign work with mentions,
and keep the history when you close the browser.

**Status:** early working prototype. Two clients ship: a browser UI and a
terminal client, both driving the same coordination core. A public network API
is not implemented yet.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/ZmagoD/roundtable/main/install.sh | bash
```

Then:

```sh
roundtable start     # start the background service
roundtable tui       # open the terminal client
roundtable status    # check on it, and print the browser URL
```

The installer clones into `~/.local/share/roundtable`, builds an OTP release,
and links `roundtable` into `~/.local/bin`. It never asks for sudo and touches
nothing outside your home directory. Re-run it, or run `roundtable update`, to
update in place; `install.sh --uninstall` removes the command and the code but
keeps your rooms, and `--purge` deletes those too. `install.sh --help` lists
the flags, and `ROUNDTABLE_PREFIX`, `ROUNDTABLE_BIN_DIR`, `ROUNDTABLE_REF` and
`ROUNDTABLE_REPO` override where it installs from and to.

You need Linux, Elixir 1.17+ with a compatible Erlang/OTP, Python 3, Git, and
at least one supported agent CLI. Log in to each agent in its own terminal
first: Roundtable uses those installations and their existing credentials, and
stores no API keys of its own.

## From source

```sh
git clone https://github.com/ZmagoD/roundtable.git
cd roundtable
mix setup
mix phx.server
```

Open the URL printed in the terminal (normally **http://127.0.0.1:4317**).
The service scans the next 99 ports if the preferred port is occupied. It never
uses ports 3000 or 4000. Override the preferred port with `PORT=4320`.
The probe is best effort: a different process can claim a port between the
availability check and the web server binding it.

## Background service

```sh
roundtable start
roundtable open    # the browser UI in its own window
roundtable status  # includes the URL and recent logs
roundtable logs
roundtable stop
```

From a source checkout the same commands live at `bin/roundtable`, and
`bin/roundtable setup` builds the assets and the OTP release.

The production release migrates its SQLite database on startup. The launcher
keeps its database, generated cookie-signing secret, PID and logs in `.local/`.
Development uses `roundtable_dev.db`. These are separate workspaces by default;
set `DATABASE_PATH` to use a specific database. Never run two service instances
against the same database: one coordinator owns its delivery queue.
The service survives closing the terminal; automatic start at login is not installed.

### As a desktop app

`roundtable open` starts the service if it is not running and opens the UI in a
Chromium-family browser with `--app`: a window with no browser chrome, its own
icon and its own entry in the task switcher. `roundtable install-desktop` adds
a launcher entry for it.

There is nothing to package. The UI is a local web server and the browser is
the runtime, so the same two commands work on every distribution — the only
thing installed is a `.desktop` text file. Set `ROUNDTABLE_BROWSER` to choose a
browser; without a Chromium-family one it falls back to an ordinary tab.

## Terminal client

```sh
roundtable start   # the service owns the database and the agents
roundtable tui     # attach a terminal to it
```

The client attaches to the running service over distributed Erlang rather than
opening the database itself, so the terminal, the browser, and any other
terminal all see one conversation and one delivery queue. Quitting the client
leaves running turns alone: a 30-minute turn keeps going, and reattaching shows
where it got to. The service node is `roundtable@<hostname>`; override it with
`ROUNDTABLE_NODE`, and the cookie with `ROUNDTABLE_COOKIE`.

Agents do not run in the browser or in the client: the service starts each
provider CLI as a process on your machine, in that participant's working
directory. So point a room at the project you want worked on — from the
directory itself, `/new-room My App .` is enough — and the agent has the access
your user has there, subject to the provider's own permissions.

Type a message to post it to the room, or `@name` to assign a turn — `Tab`
cycles the recipient. Lines beginning with `/` are commands:

| Command | Effect |
| --- | --- |
| `/help`, or `?` on an empty line | the full help screen |
| `/rooms`, `/room <name>` | list rooms, switch to one |
| `/new-room <name> <dir>` | create a room; `.` is the directory you started the client in |
| `/agent <name> <provider> [dir]` | add a participant; `--model`, `--role`, `--tier`, `--dir` |
| `/role <agent> <text>` | set what a participant is for |
| `/model <agent> <id\|default>` | pin a model, or hand the choice back |
| `/who` | show every participant, their model, tier and role |
| `/stop <agent>`, `/reset <agent>` | stop a participant's queue, clear its session |
| `/retry [run]` | retry the newest failed run, or one by id |
| `/approve accept\|decline [n]` | answer a pending tool approval |
| `/changes [agent\|room\|off]` | watch a different directory, or hide the pane |
| `/ask <room>/<agent> <question>` | ask another room; the answer comes back here |
| `/delegate <room>/<agent> <task>` | hand work to another room; it reports back |
| `/lazygit` | hand the terminal to lazygit |
| `/refresh` | re-read the room now, without waiting for an update |
| `/quit` | leave (Ctrl-C and Ctrl-D also work) |

Press `?` on an empty line for a help screen listing every command and key —
the client is meant to be learnable from inside it, without this page.

`↑`/`↓` and `PgUp`/`PgDn` scroll the transcript, `^L` redraws. Approvals and
failed runs appear inline with the command that answers them.

`^P` opens the roster: every participant with their provider, model, cost tier
and role, which is also what each agent is told about the others.

The message line takes the usual editing keys: `Esc` closes the roster if it is open and otherwise clears it, `^U` deletes to
the start, `^W` deletes the word behind the cursor, and `Home`/`End` jump to
either end.

### Watching the work land

A pane under the transcript polls `git status` in the room's directory, so you
see files appear and line counts move while a turn is still running:

```
─ changes · main ───────────────────────────────
  M lib/parser.ex                          +42 -7
  A test/parser_test.exs                      +88
 ?? scratch.md
 3 files, +130 -7
```

`^T` hides and shows it. When an agent has its own working directory — a
separate worktree, say — `/changes <agent>` follows that one instead of the
room's.

`^G` hands the terminal to **lazygit** in whichever directory the pane is
watching, and brings the client back when you quit it. Set `ROUNDTABLE_GIT_UI`
to use something else (`ROUNDTABLE_GIT_UI=nvim`, for instance). This needs
`bin/roundtable tui`: the client cannot spawn an interactive tool itself,
because the BEAM starts every child process in its own session with no
controlling terminal, so the launcher does it and restarts the client
afterwards.

Without the service running, `mix tui --local` starts a standalone client that
owns the database itself. Use it only when the background service is stopped —
two coordinators on one database fight over the same delivery queue.

### Rooms as teams

Rooms are sealed from each other. An agent sees only its own room's roster and
history, and `@name` resolves only inside the room — two rooms can both have a
`grace`. That makes a room a team rather than a channel.

A room is addressed from another room by its name in lowercase with dashes, so
`Design Team` is `design-team`:

```
/ask design-team/grace what spacing should the room list use?
```

The question is delivered into Design Team as an ordinary turn for `@grace`,
carrying only what was asked — not the asking room's history. When that turn
finishes, the answer is posted back into the asking room. An agent can do the
same by writing `@design-team/grace …` in its reply; the answer then mentions
that agent, so it wakes up and can use it. Each agent's prompt lists the other
rooms it can reach.

`/delegate` is the same path for work rather than a question, and reports back
when it is done. Agents can ask other rooms on their own, but only a human can
delegate to one.

The four-hop cap spans rooms: a cross-room request inherits the asking
message's depth, so Platform → Design → Platform terminates like any other
chain rather than resetting each time it crosses a boundary.

## Working together

1. Create a room and choose an existing project directory.
2. Add agents with unique names such as `ada`, `reviewer`, or `tester`.
   Multiple participants can use the same provider. Optionally choose a model
   and give each participant a role or a separate working directory.
3. Write a message or select a recipient. `@ada` starts Ada's turn;
   `@all` schedules everyone. Unaddressed messages are saved as shared context.
4. Agents receive unread room messages before their next assignment. Their final
   replies go into the room. A mention in a reply can delegate to another agent.
5. Open **Session details** to stop a participant and its queue, or start a new
   native session. New sessions receive room history. Stopped and failed work
   can be retried explicitly.

There is one active turn per participant, up to four active turns overall,
and at most four automatic delegation hops from a human message. Agent tool
permissions remain subject to the provider's rules. Codex and Claude approval
requests are presented in the chat; OpenCode's CLI adapter uses its configured
permissions and cannot interactively grant a new approval. Errors are visible
with partial output and a retry control. Each turn has a 30-minute timeout.

For concurrent code changes, create separate Git worktrees and set each agent's
working directory accordingly. Automatic worktree creation/merging is not built in.
All messages are public within their room. Agents process new messages at the
next turn boundary; mid-turn steering is not implemented.

The UI currently renders plain text (including code and Markdown source).
Room history is loaded in full; very large rooms will need pagination and
context compaction. Session reset clears the participant's current native
session pointer, but leaves the room conversation intact. Old native transcripts
remain managed by the provider CLI. Roundtable does not currently offer a picker
for those older sessions.

## Models and cost-aware assignments

Open **Model presets** in the sidebar to save model IDs/aliases accepted by your
CLIs. Label each preset **economy**, **standard**, **premium**, or **unrated**.
These are your relative estimates, not live vendor prices; no dollar billing
or token accounting is implied. You can edit presets later.

When adding an agent, select a preset or enter a custom model and its cost tier.
For each assignment, select a named recipient, choose a model preset (or keep
that agent's default), and choose **Plan**, **Implement**, **Verify**, or General.
The choice is saved on the assignment and shown in chat. Editing a preset later
does not change queued or historical assignments.

Every agent receives the room roster including model IDs, relative cost tiers,
and roles. The prompt encourages delegating routine work to economy participants
and using premium participants where planning or review warrants it. This is
model guidance, not an enforced budget optimizer: create appropriately named
participants and review their handoffs. Automatic agent-to-agent mentions use
the recipient's configured default model.

A change of model starts a fresh native session and supplies room history. This
also applies when returning from an expensive override to the provider default,
so a resumed session cannot silently keep the expensive model selected. Repeated
turns with the same model resume the native session as usual. For efficient
parallel work, keep separate named agents for your regular model/role combinations.

## Providers and extensions

| Adapter | Transport | Resume | Approvals |
| --- | --- | --- | --- |
| Codex | `codex app-server`, JSON-RPC over stdio | Thread ID | Command and file approval |
| Claude Code | `claude -p`, streaming JSON/control protocol | Session ID | Tool approval |
| OpenCode | `opencode run --format json` | Session ID | CLI configuration only |

Adapters implement `Roundtable.Agents.Adapter` and are registered in application
configuration. No UI changes are needed to list another provider.
See [the adapter guide](docs/ADAPTERS.md) and [contributing](CONTRIBUTING.md).
Provider protocols can change; adapter contract tests and real CLI smoke tests
should accompany updates. Codex's installed schema can be inspected with
`codex app-server generate-json-schema --out /tmp/codex-schema`.

## Architecture

Clients (LiveView, terminal) → Chat/Coordinator → supervised agent workers →
provider CLIs. `Roundtable.Client` is the seam: it calls the coordination core
directly in-node, or over distributed Erlang from a terminal, so a client never
opens the database itself.
SQLite stores rooms, participants, messages, native session IDs, and durable run
records. Message insertion and delivery creation are transactional; PubSub
updates connected browsers. A coordinator serializes queue transitions.
Its runtime supervisor restarts workers and coordinator together if either
supervisor component fails. On startup, active runs become interrupted, so they
are not silently repeated. Queued runs are eligible to resume.

The app binds **only to loopback** and is designed for a single local user.
It has no multi-user authentication. Do not put it on a public proxy without
adding authentication and authorization. Browser origin checks and CSRF
protection remain enabled, and requests are answered only when addressed to a
loopback host, so a remote page cannot read a room by pointing its own domain
at 127.0.0.1. If a proxy needs to serve another name, allow it with
`config :roundtable, :allowed_hosts`. The service state directory (`.local/`),
which holds the database and logs, is created private to the user running it.
Adapters are trusted code with the same OS access as the service. Prompt text
and working directories are passed as arguments/data, not interpolated into
shell commands.

## Tests

```sh
mix test
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
```

`mix precommit` runs all four. CI runs them on every push, plus `shellcheck`
on `install.sh` and `bin/roundtable`, which reach users before any Elixir does.

The adapters have contract tests because provider protocols change under us,
and a wrong clause there does not crash — it silently drops a turn's output or
leaves a turn that never finishes.

The terminal client is tested in two halves. Its pure layers — key decoding,
state transitions, rendering — and every effect a keystroke asks for run in the
normal suite. What only exists because there is a terminal (raw mode, the
reader process, the redraw loop, restoring the screen) is covered by
`mix test --only pty`, which allocates a real pty, types a scripted session
into the client and reads back what it drew. Those are excluded from the
default run because they boot a second VM; CI runs them as their own step.

Line coverage is around 80%. The gap is mostly code that runs in that second
VM, which the coverage tool cannot see from the first — tested, but not
counted. Coverage says which lines ran, not whether they were right.

Tests use fake workers and synthetic protocol events, so they don't consume
model tokens or depend on installed provider credentials. See `docs/TESTING.md`
for optional real-provider checks.

## Sharing

Local data and secrets are ignored by Git: databases, `.local/`, and `.env`
files never leave your machine. Roundtable stores no API keys; each agent uses
its own CLI's existing login.

Released under the [MIT License](LICENSE). Bundled third-party code keeps its
own notice: `assets/vendor/topbar.js` is MIT (© 2024 Buu Nguyen), and
[heroicons](https://github.com/tailwindlabs/heroicons) is MIT, fetched as a
build dependency.
