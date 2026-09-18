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

Tests should cover session creation/resume, fragmented streaming, final output,
permissions, errors, unknown events, and shutdown. Never include real credentials
or proprietary room history in fixtures.

## The rooms as tools

A participant whose CLI takes an MCP server on the command line *and* can ask
the room for approval is given one: the service's own `/mcp`, with a token
minted for that turn. `Roundtable.Agents.Protocol.tools/1` builds the flags,
`env/1` the environment, and `Roundtable.MCP` decides who is offered them at
all. If your CLI has both, add a clause to `flags/3`. If it has no approval
channel, do not — a tool that rearranges the rooms with nowhere to say no is not
worth having.
