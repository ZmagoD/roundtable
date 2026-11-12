defmodule Roundtable.Agents.Vibe do
  @moduledoc """
  Adapter for `vibe-acp`, Mistral Vibe's Agent Client Protocol server; the
  protocol itself is `Roundtable.Agents.Acp`.

  `vibe-acp` takes no flags. The approval mode is the session's: once the
  session is open it is set to `auto-approve` when the human turned automatic
  approval on, and to `accept-edits` otherwise, so edits go ahead and anything
  else is asked of the room. The model comes from `VIBE_ACTIVE_MODEL` (see
  `Roundtable.Agents.Protocol.env/1`), which Vibe reads like any config field.

  The shapes were read from the installed CLI's own `vibe/acp` package; the
  session start was also run against it, without a model turn.
  """
  @behaviour Roundtable.Agents.Adapter
  @behaviour Roundtable.Agents.Acp

  alias Roundtable.Agents.Acp

  def id, do: "vibe"
  def label, do: "Mistral Vibe"

  def command(_agent, _prompt), do: {"vibe-acp", []}

  def start(state), do: Acp.start(state)
  def approve(state, id, decision, request), do: Acp.approve(state, id, decision, request)
  def handle_event(event, state), do: Acp.handle_event(event, state, __MODULE__)

  # Set every turn rather than trusted to the default: the default is the
  # human's own `default_agent`, which could be anything.
  def before_prompt(state) do
    mode = if Map.get(state.agent, :auto_approve), do: "auto-approve", else: "accept-edits"
    {"session/set_mode", %{modeId: mode}}
  end

  def exit_status(code, state) do
    case Roundtable.Quota.failure(String.trim(state.diagnostics)) do
      {"rate_limited", _} = limited -> limited
      _ -> {"failed", "Mistral Vibe exited (#{code}). #{state.diagnostics}"}
    end
  end
end
