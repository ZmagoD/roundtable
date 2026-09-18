defmodule Roundtable.Agents.OpenCode do
  @behaviour Roundtable.Agents.Adapter
  import Roundtable.Agents.Worker, only: [put_output: 2, write_raw: 2, close_stdin: 1]
  alias Roundtable.Coordinator
  alias Roundtable.Agents.Protocol
  def id, do: "opencode"
  def label, do: "OpenCode"

  def command(agent, _prompt), do: Protocol.command(Map.put(agent, :provider, "opencode"))

  def start(state) do
    write_raw(state, state.prompt)
    close_stdin(state)
  end

  def approve(_state, _id, _decision, _request), do: :unsupported
  def exit_status(0, %{output: output}) when output != "", do: {"completed", nil}
  def exit_status(code, state), do: {"failed", "OpenCode exited (#{code}). #{state.diagnostics}"}

  def handle_event(%{"sessionID" => session} = e, state) do
    if state.session != session, do: Coordinator.event(state.run.id, {:session, session})
    state = %{state | session: session}

    case e do
      %{"type" => "text", "part" => %{"text" => text}} ->
        put_output(state, state.output <> text <> "\n")

      %{"type" => "error", "error" => error} ->
        %{state | finished: {"failed", inspect(error)}}

      _ ->
        state
    end
  end

  def handle_event(%{"type" => "error", "error" => error}, state),
    do: %{state | finished: {"failed", inspect(error)}}

  def handle_event(_, state), do: state
end
