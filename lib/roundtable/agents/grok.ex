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
  for a prompt nobody can answer.
  """
  @behaviour Roundtable.Agents.Adapter

  import Roundtable.Agents.Worker, only: [close_stdin: 1]

  alias Roundtable.Agents.{Messages, Protocol}

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
        "--include-partial-messages",
        "--permission-mode",
        "acceptEdits"
      ] ++
        Protocol.optional("--resume", agent.session_id) ++
        Protocol.optional("--model", agent.model)

    {"grok", args}
  end

  # Nothing to send: the prompt was an argument. Closing stdin stops the CLI
  # waiting on input that is never coming.
  def start(state), do: close_stdin(state)

  def approve(_state, _id, _decision, _request), do: :unsupported

  def exit_status(0, %{output: output}) when output != "", do: {"completed", nil}
  def exit_status(code, state), do: {"failed", "Grok exited (#{code}). #{state.diagnostics}"}

  def handle_event(event, state) do
    case Messages.handle(event, state) do
      {:ok, state} -> state
      :unhandled -> state
    end
  end
end
