defmodule Roundtable.Agents.Vibe do
  @moduledoc """
  Adapter for `vibe -p --output streaming`, Mistral's CLI.

  The stream is one JSON object per *completed* history entry — Vibe's own
  `PublicHistoryEntry`, camel-cased — so there are no deltas: an assistant
  message arrives whole, and a turn may hold several between tool calls. The
  shapes come from the installed CLI's `vibe/cli/programmatic.py` and
  `vibe/app_server/models.py`, not from a run.

  A resumed session replays its whole history before the new turn, every entry
  carrying the turn it belongs to. Only the newest turn seen is this one, so
  output starts over whenever the turn changes.

  Programmatic mode denies every approval it would have asked for, so there is
  no channel to the room: `approve/4` cannot grant one, and the turn runs under
  `accept-edits` unless the human turned automatic approval on.
  """
  @behaviour Roundtable.Agents.Adapter

  import Roundtable.Agents.Worker, only: [put_output: 2, write_raw: 2, close_stdin: 1]

  alias Roundtable.Agents.Protocol
  alias Roundtable.Coordinator

  def id, do: "vibe"
  def label, do: "Mistral Vibe"

  # `-p` with no text reads the prompt from stdin, which has no argument-size
  # limit. `--trust` is the CLI's own advice for automation: without it the
  # room's folder is untrusted and its project configuration silently ignored.
  def command(agent, _prompt) do
    approval =
      if Map.get(agent, :auto_approve), do: ["--auto-approve"], else: ["--agent", "accept-edits"]

    {"vibe",
     ["-p", "--output", "streaming", "--trust"] ++
       approval ++ Protocol.optional("--resume", agent.session_id)}
  end

  def start(state) do
    write_raw(state, state.prompt)
    close_stdin(state)
  end

  def approve(_state, _id, _decision, _request), do: :unsupported

  def exit_status(0, %{output: output}) when output != "", do: {"completed", nil}

  def exit_status(code, state) do
    case Roundtable.Quota.failure(String.trim(state.diagnostics)) do
      {"rate_limited", _} = limited -> limited
      _ -> {"failed", "Vibe exited (#{code}). #{state.diagnostics}"}
    end
  end

  def handle_event(%{"sessionId" => session} = entry, state) when is_binary(session) do
    if state.session != session, do: Coordinator.event(state.run.id, {:session, session})

    state = follow_turn(%{state | session: session}, entry["turnId"])
    entry(entry, state)
  end

  def handle_event(_event, state), do: state

  defp follow_turn(state, nil), do: state
  defp follow_turn(%{turn: turn} = state, turn), do: state
  defp follow_turn(state, turn), do: state |> Map.put(:turn, turn) |> Map.put(:output, "")

  defp entry(%{"type" => "message", "role" => "assistant", "content" => content}, state) do
    case Protocol.text_blocks(content) do
      "" -> state
      text when state.output == "" -> put_output(state, text)
      text -> put_output(state, state.output <> "\n\n" <> text)
    end
  end

  # A turn that fails says so in an error notice before the CLI exits, and the
  # exit status is where a failure is decided.
  defp entry(%{"type" => "notice", "level" => "error", "message" => message}, state)
       when is_binary(message),
       do: %{state | diagnostics: String.slice(state.diagnostics <> message <> "\n", -8000, 8000)}

  defp entry(_entry, state), do: state
end
