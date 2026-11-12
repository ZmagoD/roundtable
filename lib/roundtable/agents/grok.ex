defmodule Roundtable.Agents.Grok do
  @moduledoc """
  Adapter for `grok agent stdio`, Grok's Agent Client Protocol server; the
  protocol itself is `Roundtable.Agents.Acp`.

  A participant set to approve its own tools runs with `--always-approve` and
  is never asked; any other asks the room through ACP.

  The shapes for `initialize` and `session/new` were confirmed against the
  installed CLI. Those for a running turn follow the ACP specification and the
  names in Grok's own binary; no real turn was run to capture them.
  """
  @behaviour Roundtable.Agents.Adapter
  @behaviour Roundtable.Agents.Acp

  alias Roundtable.Agents.{Acp, Protocol}

  def id, do: "grok"
  def label, do: "Grok"

  # Everything else, the prompt included, goes over stdin once the protocol is
  # up, so nothing about the turn reaches the argument list.
  def command(agent, _prompt) do
    {"grok",
     ["agent"] ++
       approvals(agent) ++ Protocol.optional("--model", Map.get(agent, :model)) ++ ["stdio"]}
  end

  defp approvals(agent),
    do: if(Map.get(agent, :auto_approve), do: ["--always-approve"], else: [])

  def start(state), do: Acp.start(state)
  def approve(state, id, decision, request), do: Acp.approve(state, id, decision, request)
  def handle_event(event, state), do: Acp.handle_event(event, state, __MODULE__)
  def before_prompt(_state, _opened), do: []

  def exit_status(code, state), do: {"failed", "Grok exited (#{code}). #{state.diagnostics}"}
end
