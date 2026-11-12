defmodule Roundtable.Agents.Vibe do
  @moduledoc """
  Adapter for `vibe-acp`, Mistral Vibe's Agent Client Protocol server; the
  protocol itself is `Roundtable.Agents.Acp`.

  `vibe-acp` takes no flags. The approval mode is the session's: once the
  session is open it is set to `auto-approve` when the human turned automatic
  approval on, and to `accept-edits` otherwise, so edits go ahead and anything
  else is asked of the room. The model comes from `VIBE_ACTIVE_MODEL` (see
  `Roundtable.Agents.Protocol.env/1`), which Vibe reads like any config field.
  A room folder Vibe does not trust yet is trusted on the first turn there.

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

  def before_prompt(state, opened), do: trust(state, opened) ++ [mode(state)]

  # Vibe ignores an untrusted folder's own `AGENTS.md` and `.vibe` config. The
  # human picked the room's folder to work in, so it is trusted the way
  # accepting Vibe's own prompt would: saved to Vibe's trust list, and applied
  # to this session at once. Vibe offers the decision only when the folder has
  # such files (asking otherwise is an error that would end the turn), and only
  # a new session reports it; a resumed one was trusted when it began.
  defp trust(state, %{"_meta" => %{"workspace_trust" => trust}}) do
    case trust do
      %{"status" => "untrusted", "details" => %{"availableDecisions" => decisions}} ->
        if "trust_cwd" in decisions,
          do: [{"_trust/decision", %{decision: "trust_cwd", cwd: state.agent.directory}}],
          else: []

      _ ->
        []
    end
  end

  defp trust(_state, _opened), do: []

  # Set every turn rather than trusted to the default: the default is the
  # human's own `default_agent`, which could be anything.
  defp mode(state) do
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
