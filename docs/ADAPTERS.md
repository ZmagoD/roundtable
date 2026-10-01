# Adding an agent

Providers are trusted Elixir modules implementing `Roundtable.Agents.Adapter`.
The room UI discovers names from the registry and does not hardcode provider IDs.

Register built-in and custom modules in `config/config.exs`:

```elixir
config :roundtable, :adapters, [
  Roundtable.Agents.Codex,
  Roundtable.Agents.Claude,
  Roundtable.Agents.OpenCode,
  MyAgentAdapter
]
```

An external Mix dependency can supply an adapter module. Configuration is applied
on application startup; this is not an untrusted runtime plugin marketplace.
IDs must remain stable because persisted participants reference them. Keep an
adapter registered while it has participants. Use unique lowercase IDs.

## Contract

- `id/0`: persisted provider ID, e.g. `"myagent"`.
- `label/0`: display name.
- `command(agent, prompt)`: executable and argv list. Never build a shell string.
  The agent includes `session_id`, `model`, `directory`, `name`, and `role`.
  The UI calls this function with an empty prompt and nil session/model to
  detect the executable, so it must be pure and not need other agent fields.
- `start(state)`: send a handshake or initial prompt over the worker port.
- `handle_event(event, state)`: normalize a decoded JSON line and return state.
- `approve(state, request_id, decision, request)`: send a provider-native response.
  Decisions are `"accept"` or `"decline"`, scoped to one request.
- `exit_status(code, state)`: return `{status, error_or_nil}` if the process exits
  before emitting an explicit completion. Do not interpret a zero exit code as
  success unless the protocol guarantees a completed response.

The worker currently supports a local process emitting newline-delimited JSON.
For an HTTP-only or non-JSON provider, a small protocol bridge can implement
this contract. A separate transport behaviour can be introduced later without
changing the room/client model.

## Event helpers

```elixir
alias Roundtable.Coordinator
alias Roundtable.Agents.Worker

# Persist the provider's real session ID, so later turns can resume it.
Coordinator.event(state.run.id, {:session, event["session_id"]})

# Replace the current rendered output; worker batches UI updates.
state = Worker.put_output(state, state.output <> event["text_delta"])

# Pause for the human. Store enough native request data to answer accurately.
state = Worker.approval(state, event["request_id"], event["request"])

# Finish after returning the final state; the worker persists output and stops.
%{state | finished: {"completed", nil}}
# On error: %{state | finished: {"failed", "Actionable explanation"}}

# Send a JSON line to the provider.
Worker.write(state, %{type: "user", text: state.prompt})

# For a CLI reading plain text until EOF:
Worker.write_raw(state, state.prompt)
Worker.close_stdin(state)
```

Use the built-in adapters as working examples. Unknown informational events
should leave state unchanged. Unsupported requests requiring a response must
receive an explicit error, rather than hanging the session. Do not route stderr
or tool logs into public chat messages. This initial transport combines stderr
with stdout; non-JSON diagnostics are retained only for an actionable failure.

Session creation is lazy: adding a participant does not call a model. The first
assignment starts the native conversation. Every subsequent turn gets the saved
ID. Reset creates a fresh conversation on the next turn and supplies room history.

Compaction emits the normalized `:compacted` coordinator event. Claude's
[`system/compact_boundary`](https://code.claude.com/docs/en/agent-sdk/agent-loop#automatic-compaction)
and Codex's `item/completed` with a `contextCompaction` item (or legacy
`thread/compacted`) request full standing instructions on the next turn. The
Codex shapes are defined by `codex app-server generate-json-schema`. Unknown
events and compaction-start notifications do not trigger a refresh. Chat persists
the counter, which also refreshes instructions every twentieth resumed dispatch.
The counter advances only after a worker starts; repeated compaction events are
idempotent, and later session events do not clear a pending refresh.

Tests should cover session creation/resume, fragmented streaming, final output,
permissions, errors, unknown events, and shutdown. Never include real credentials
or proprietary room history in fixtures.

## Quota exhaustion

Adapters can finish a turn with a normalized temporary quota failure:

```elixir
%{state | finished: {"rate_limited", %{
  message: "Provider usage limit reached.",
  resets_at: unix_seconds_or_nil
}}}
```

`resets_at` is an absolute Unix timestamp in seconds. Do not emit this for a
quota warning that still allows work, context-window exhaustion, session budgets,
missing credentials, or insufficient credits. `Roundtable.Quota.failure/1`
normalizes known error codes and a conservative set of quota-error phrases.
Unsupported failures remain ordinary failures. Only participants whose human
has enabled `auto_retry` will wait and resume.

Claude's rejected `rate_limit_event` carries `rate_limit_info.resetsAt`; an
assistant `error: "rate_limit"` is also supported. Codex's terminal turn error
uses `codexErrorInfo` (`usageLimitExceeded` or `rateLimitExceeded`), with reset
times from exhausted windows in `account/rateLimits/updated`. These contracts
were checked against the installed CLIs, including Codex's generated JSON
schema. Update the synthetic contract tests when provider events change.

The worker exits normally after reporting this event. A separate supervised
clock wakes the same durable run when due; workers themselves remain temporary.
The coordinator does not publish partial output or fail cross-room requests
while waiting. Ordinary worker crashes are still interrupted and need an explicit
retry, so a process restart does not silently repeat arbitrary side effects.

## Usage reporting

`Roundtable.Agents.Usage.report/2` sends cumulative token snapshots for one worker
attempt to the coordinator. `Chat` persists them in `runs.token_usage`, keyed by
attempt UUID, so duplicate snapshots replace counts and retries retain earlier
consumption. Use the keys `input`, `output`, `cached` (cache reads), and
`cache_write`. Omit absent values; zero is a real reported value. Participant
totals sum only retained runs and do not survive clearing chat history.

Claude's `result.usage` is authoritative for a turn. Assistant message usage is
retained by message ID as a fallback for interrupted streams, then replaced by
the final result. Codex `thread/tokenUsage/updated` carries cumulative thread
totals and the last model response, not a single turn total. The adapter counts
the first current-turn `last`, then differences between successive `total`
snapshots; replayed and other-turn notifications do not add usage. The installed
app-server JSON schema defines these events; `turn/completed` itself has no
token fields. OpenCode `step_finish.part.tokens` is summed by unique part ID
when present (see its [JSON command implementation](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/cli/cmd/run.ts)).

Quota events use `{:provider_usage, data}`. The coordinator attributes them to
the worker's launch provider, even if the participant is edited mid-turn.
`Chat` replaces the provider's previous snapshot and timestamp and notifies
every browser room. Claude's installed rate-limit schema defines `utilization`
as a fraction; converting it to a percentage is not an estimate. Codex uses the
higher reported `usedPercent` of the two windows and preserves its reset time.
Claude reports its windows in separate events, so `Usage.keep/2` keeps the one
closer to its limit (stricter status, then higher percentage) and lets a newer
reading of the same window replace it. A snapshot expires when its `resets_at`
(Unix seconds) is reached: `Usage.label/1` renders “not reported” and
`Usage.level/1` clears its warning. `Usage.keep/2` never prefers an expired
snapshot over a fresh one, even across windows. Missing reset times do not
expire; expiry never invents a new percentage.
Missing fields remain unknown. Contract tests use synthetic, non-sensitive
events matching these protocol shapes; no real provider turn is needed.

## The rooms as tools

A participant whose CLI takes an MCP server on the command line *and* can ask
the room for approval is given one: the service's own `/mcp`, with a token
minted for that turn. `Roundtable.Agents.Protocol.tools/1` builds the flags,
`env/1` the environment, and `Roundtable.MCP` decides who is offered them at
all. If your CLI has both, add a clause to `flags/3`. If it has no approval
channel, do not — a tool that rearranges the rooms with nowhere to say no is not
worth having.
