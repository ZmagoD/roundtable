defmodule Roundtable.Agents.Grok do
  @moduledoc """
  Adapter for `grok -p`, the xAI CLI.

  Its `--output-format streaming-messages-json` is, by its own help, "NDJSON in
  the Anthropic Messages API wire format", so the events are the ones
  `Roundtable.Agents.Messages` already understands — confirmed against a real
  run of the CLI, not assumed from the documentation.

  It has no interactive approval channel: permissions come from its own
  `--allow`/`--deny` rules and `--permission-mode`, the way OpenCode's come
  from its configuration. So `approve/4` reports that it cannot grant one, and
  the turn runs under `acceptEdits` rather than a mode that would sit waiting
  for a prompt nobody can answer — or with every tool approved, when the human
  turned automatic approval on for this participant.

  A step `acceptEdits` does not cover, such as a shell command, is not refused
  but cancelled, and the turn ends with nothing more than "cancelled". Its own
  log calls the turn successful, so the room is told what that usually means.
  """
  @behaviour Roundtable.Agents.Adapter

  import Roundtable.Agents.Worker, only: [close_stdin: 1]

  alias Roundtable.Agents.{Messages, Protocol}

  @cancelled "Grok cancelled this turn, most likely at a step that needed permission, " <>
               "such as a shell command. It cannot ask the room for permission, so it " <>
               "stops instead. Turn on automatic approval for this participant, or give " <>
               "the step to a Claude Code or Codex participant."

  def id, do: "grok"
  def label, do: "Grok"
  # `-p` takes the prompt as an argument, and the CLI documents no way to read
  # it from stdin, so that is where it goes. Linux caps a single argument at
  # 128 KB; a room long enough to exceed that fails visibly at spawn rather
  # than silently truncating.
  def command(agent, prompt) do
    args =
      [
        "-p",
        prompt,
        "--output-format",
        "streaming-messages-json",
        "--include-partial-messages"
      ] ++
        permissions(agent) ++
        Protocol.optional("--resume", agent.session_id) ++
        Protocol.optional("--model", agent.model)

    {"grok", args}
  end

  defp permissions(agent) do
    if Map.get(agent, :auto_approve),
      do: ["--always-approve"],
      else: ["--permission-mode", "acceptEdits"]
  end

  # Nothing to send: the prompt was an argument. Closing stdin stops the CLI
  # waiting on input that is never coming.
  def start(state), do: close_stdin(state)

  def approve(_state, _id, _decision, _request), do: :unsupported

  def exit_status(0, %{output: output}) when output != "", do: {"completed", nil}
  def exit_status(code, state), do: {"failed", "Grok exited (#{code}). #{state.diagnostics}"}

  def handle_event(event, state) do
    case Messages.handle(event, state) do
      {:ok, state} -> explain_cancel(state)
      :unhandled -> state
    end
  end

  # With every tool approved there is no permission to have stopped at, so a
  # cancel then is left as the CLI said it and retried like any other failure.
  defp explain_cancel(%{finished: {"failed", message}} = state) do
    if String.trim(message) =~ ~r/\Acancell?ed\z/i and !Map.get(state.agent, :auto_approve),
      do: %{state | finished: {"failed", @cancelled}},
      else: state
  end

  defp explain_cancel(state), do: state
end
