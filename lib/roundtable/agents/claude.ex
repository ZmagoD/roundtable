defmodule Roundtable.Agents.Claude do
  @moduledoc """
  Adapter for `claude -p`, which speaks streaming JSON with a control channel.

  Partial message events carry the text as it is generated; whole assistant
  messages are the fallback when a build does not emit them. Tool approvals
  arrive on the control channel and are answered the same way.
  """
  @behaviour Roundtable.Agents.Adapter
  import Roundtable.Agents.Worker, only: [write: 2, approval: 3]

  alias Roundtable.Agents.{Messages, Protocol}
  def id, do: "claude"
  def label, do: "Claude Code"
  def command(agent, _prompt), do: Protocol.command(Map.put(agent, :provider, "claude"))

  def start(state),
    do: write(state, %{type: "user", message: %{role: "user", content: state.prompt}})

  def approve(state, id, decision, request) do
    response =
      if decision == "accept",
        do: %{behavior: "allow", updatedInput: request["input"] || %{}},
        else: %{behavior: "deny", message: "The user declined this tool call."}

    write(state, %{
      type: "control_response",
      response: %{subtype: "success", request_id: id, response: response}
    })
  end

  def exit_status(code, state), do: {"failed", "Claude exited (#{code}). #{state.diagnostics}"}

  # Session, streaming text and completion are the shared wire format; what is
  # Claude Code's own is the control channel that carries tool approvals.
  def handle_event(event, state) do
    case Messages.handle(event, state) do
      {:ok, state} -> state
      :unhandled -> control(event, state)
    end
  end

  defp control(
         %{
           "type" => "control_request",
           "request_id" => id,
           "request" => %{"subtype" => "can_use_tool"} = request
         },
         state
       ) do
    approval(state, id, request)
  end

  defp control(%{"type" => "control_request", "request_id" => id}, state) do
    write(state, %{
      type: "control_response",
      response: %{subtype: "error", request_id: id, error: "Unsupported request"}
    })

    state
  end

  defp control(_event, state), do: state
end
