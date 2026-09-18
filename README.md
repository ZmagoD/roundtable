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

The room header shows the current branch and the working directory, and a panel
lists what has changed in it — file by file, with line counts — updating while a
turn runs. Click it for the patch itself. A participant can be removed from its card and a room from its header, both
behind a confirmation. Removing a participant keeps what it said: its runs go,
but its messages stay attributed by name, because a room's history is a record
of what happened rather than a list of who is still here. Removing a room takes
its participants, its whole history and any cross-room requests with it — there
is no undo and nothing is exported first.

Each participant can be re-roled or given a different model from its card, and
renamed until it takes its first turn — after that the room has been addressing
it by name, and a rename would leave a conversation full of mentions of someone
who is not there. Its provider and directory stay fixed, because a live session
is built on them.

The theme follows your system, with Auto/Light/Dark in the sidebar if you would
rather choose. The palette is one set of colours: the dark values keep each hue
and invert its lightness, so there is only ever one design to keep in step.

### A terminal in the room

The **Terminal** button opens a shell in the room's working directory, in the
page. It is a real terminal on a real pty, so curses programs, job control and
line editing all work — `lazygit`, `vim` and `htop` included.

The BEAM cannot allocate a pty, and starts every process it spawns in a new
session with no controlling terminal, so `priv/terminal_bridge.py` allocates
one and relays bytes. The shell is tied to the page that opened it: close the
tab, switch rooms, or lose the connection, and it goes with you rather than
lingering as a process nobody can see.

This is a shell with your user's access, reachable by anyone who can reach the
page. That is the same access the agents in the room already have, and the same
reason the service binds to loopback, checks origins, and says not to put it
behind a proxy without authentication.

### Choosing the project directory

The room form completes paths as you type, so you are not recalling one from
memory: what is under `ROUNDTABLE_WORKSPACE` (or your home directory) before
you type anything, then whatever your prefix could still become. Click one to
fill the field and go a level in. Only directories are offered, never files,
hidden ones only once you type a dot, and a git repository is marked as one —
usually that is the directory you meant.

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
provider CLI as a process on your machine, in the room's working directory.
Every participant in a room works on the same tree — a room is a project, and
separate trees are separate rooms. So point a room at the project you want worked on — from the
directory itself, `/new-room My App .` is enough — and the agent has the access
your user has there, subject to the provider's own permissions.

Type a message to post it to the room, or `@name` to assign a turn — `Tab`
cycles the recipient. Lines beginning with `/` are commands:

| Command | Effect |
| --- | --- |
| `/help`, or `?` on an empty line | the full help screen |
| `/rooms`, `/room <name>` | list rooms, switch to one |
| `/new-room <name> <dir>` | create a room; `.` is the directory you started the client in |
| `/agent <name> <provider>` | add a participant; `--model`, `--role`, `--tier` |
| `/role <agent> <text>` | set what a participant is for |
| `/model <agent> <id\|default>` | pin a model, or hand the choice back |
| `/rename <agent> <new name>` | rename a participant, before its first turn |
| `/providers` | which agent CLIs are installed |
| `/models <provider> [filter]` | model names that provider offers |
| `/who` | show every participant, their model, tier and role |
| `/stop <agent>`, `/reset <agent>` | stop a participant's queue, clear its session |
| `/remove <agent>` | remove a participant; what it said stays |
| `/remove-room <name>` | delete a room and everything in it |
| `/retry [run]` | retry the newest failed run, or one by id |
| `/approve accept\|decline [n]` | answer a pending tool approval |
| `/changes [on\|off]` | show or hide the changes pane |
| `/ask <room>/<agent> <question>` | ask another room; the answer comes back here |
| `/delegate <room>/<agent> <task>` | hand work to another room; it reports back |
| `/lazygit` | hand the terminal to lazygit |
| `/refresh` | re-read the room now, without waiting for an update |
| `/quit` | leave (Ctrl-C and Ctrl-D also work) |

Type `/` and the commands appear as a palette, narrowing as you type: `↑`/`↓`
choose, `Tab` completes as far as the matches agree, and `Enter` takes the
highlighted one — filling in the line when it needs an argument rather than
running it bare. Press `?` on an empty line for the full help screen. The
client is meant to be learnable from inside it, without this page.

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

`^T` hides and shows it. It watches the room's directory, which is where every
participant in the room works.

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

### Which agents and which models

The app looks for each adapter's CLI on your PATH and says which it found — in
the browser beside the provider, and with `/providers` in the terminal. An
agent on a CLI you have not installed can still be created; it just says so,
rather than letting you find out at the first turn.

Models are asked of the CLI wherever it can answer. `opencode models` lists
what that installation can reach, `grok models` prints its own; both are parsed
for names and nothing else, because an unauthenticated CLI explains itself
instead of listing and that explanation must not end up offered as a model.
Claude Code has no listing command, so the aliases its own `--help` documents
are offered (`fable`, `opus`, `sonnet`); it takes full names too. Codex has
neither, so nothing is suggested rather than a list invented here.

In the browser the model is a list you pick from, not a box you type into —
except for a provider that cannot name its models, which gets a free text
field and says why. The form opens on a provider that *can* list, so there is
something to choose on the first screen. A model an agent already has is kept
as an option even if the CLI has stopped listing it, rather than being dropped
without telling you.

`/models <provider> [filter]` does the same from the terminal — with 400-odd
OpenCode models, the filter is the point:

```
/models claude              claude: fable, opus, sonnet
/models opencode mistral    filters 405 down to the ones you meant
/providers                  which CLIs are installed
```

They are suggestions, not a menu: the field stays free text, so a model that
appears tomorrow needs no release. Model presets in the sidebar save the ones
you use with a cost tier attached.

### Reaching other providers today

Before writing an adapter, check whether OpenCode already fronts the model you
want: it is a multi-provider agent, and `opencode models` lists what your
installation can actually reach. On this machine that is over 400, including
Mistral and Grok:

```
/agent mistral opencode --model openrouter/mistralai/mistral-large --tier standard
/agent grok opencode --model openrouter/~x-ai/grok-latest --tier standard
```

So a new provider usually needs no code. An adapter is for a CLI with its own
agent loop — its own tools, approvals and sessions — not for reaching a model.

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

## A walkthrough

Say you want a discount added to a checkout. Start the service and open a
terminal on the project:

```sh
cd ~/code/checkout
roundtable start
roundtable tui
```

**Make a room on the project.** `.` is the directory you are standing in:

```
/new-room Checkout .
```

**Build a team.** Give each participant a model, a cost tier and — most
importantly — a role, because every agent is told about the others and uses
that to decide who to hand work to:

```
/agent architect claude --model opus --tier premium --role "Plan and assign. Never write code yourself."
/agent builder codex --tier economy --role "Implement exactly what architect specifies."
/agent reviewer claude --model sonnet --tier standard --role "Review diffs for correctness and tests."
```

`^P` shows who is in the room, what they run on, and what each is for:

```
 roundtable                                                Checkout · main · /tmp/rt-demo-project 
──────────────────────────────────────────────────────────────────────────────────────────────────
 ROOMS              participants · 3 ──────────────────────────────────────────────────────────── 
 ▌ Checkout          ○ @architect  claude · opus · premium                                        
                       Plan and assign. Never write code yourself.                                
 AGENTS                                                                                           
 ○ architect         ○ @builder  codex · provider default · economy                               
 ○ builder             Implement exactly what architect specifies.                                
 ○ reviewer                                                                                       
                     ○ @reviewer  claude · sonnet · standard                                      
                       Review diffs for correctness and tests.                                    
                                                                                                  
──────────────────────────────────────────────────────────────────────────────────────────────────
 ▌ /quit                                                                                          
 ?  help    ^P  who    ^T  changes    ^G  lazygit    ^C  quit                          in-process 
```

**Give the work to someone.** A message with an `@name` starts that
participant's turn; a message without one is shared context everyone reads
next turn:

```
@architect we need a percentage discount on the cart total.
```

Architect plans, then hands the implementation over by mentioning `@builder`
in its reply, which starts builder's turn. Delegation stops after four hops, so
a chain ends on its own.

**Watch the work land.** The pane under the transcript is `git status` in the
room's directory, updating while a turn runs. `^T` hides it; `^G` hands the
terminal to lazygit and takes it back when you quit:

```
 roundtable                                                Checkout · main · /tmp/rt-demo-project 
──────────────────────────────────────────────────────────────────────────────────────────────────
 ROOMS                                                                                            
 ▌ Checkout                                                                                       
                                                                                                  
 AGENTS                                                                                           
 ○ architect                                                                                      
 ○ builder                                                                                        
 ○ reviewer                                                                                       
                                                                                                  
                                                                                                  
                    13:52 you        @architect we need a percentage discount on the cart total.  
                                                                                                  
                    13:52 architect  Two pieces: Cart.discount/2 rounding to whole units, and a te
                                     st for the boundary cases. @builder take the implementation. 
                                                                                                  
                    13:52 builder    Added Cart.discount/2 with a test for 10% off 100. @reviewer 
                                     over to you.                                                 
                    changes · main ────────────────────────────────────────────────────────────── 
                      M lib/cart.ex                                                          +2 -0
                      M test/cart_test.exs                                                   +4 -0
                     ?? NOTES.md                                                                  
                     3 files, +6 -0                                                               
──────────────────────────────────────────────────────────────────────────────────────────────────
 ▌ Say something, or / for commands                                                               
 Connected to in-process. /help for commands.                                          in-process 
```

**Answer for the tools.** When an agent asks to run something, the request
appears inline with the command that answers it — `/approve accept 1` or
`/approve decline 1`. Codex and Claude Code ask; OpenCode uses its own
configured permissions.

**Press `?` for everything else.** The client is meant to be learnable from
inside it.

### The same room in a browser

`roundtable open` gives the same room a window. The header carries the branch
and the directory, the right-hand column is the roster and what has changed,
and the theme follows your system.

![The Checkout room in the browser](docs/images/room-light.png)

Dark is the same palette with its lightness inverted, not a second design:

![The same room in dark mode](docs/images/room-dark.png)

The **Terminal** button opens a shell in the room's directory, in the page.

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
| Grok | `grok -p`, Anthropic Messages wire format | Session ID | CLI configuration only |
| OpenCode | `opencode run --format json` | Session ID | CLI configuration only |

Adding one is a module, not a fork: adapters implement
`Roundtable.Agents.Adapter` and are registered in application configuration, so
a provider can live outside this repository entirely. The three here are 40-110
lines each. What an adapter needs from a CLI is a non-interactive mode and
machine-readable output — `claude -p --output-format stream-json`, `codex
app-server`, `opencode run --format json`. A CLI without those cannot be
driven by anything, including this.

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
