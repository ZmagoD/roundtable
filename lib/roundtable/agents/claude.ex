defmodule Roundtable.Agents.Claude do
  @moduledoc """
  Adapter for `claude -p`, which speaks streaming JSON with a control channel.

  Partial message events carry the text as it is generated; whole assistant
  messages are the fallback when a build does not emit them. Tool approvals
  arrive on the control channel and are answered the same way.
  """
  @behaviour Roundtable.Agents.Adapter
  import Roundtable.Agents.Worker, only: [write: 2, put_output: 2, approval: 3]
  alias Roundtable.Agents.Protocol
  alias Roundtable.Coordinator
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

  def handle_event(%{"type" => "system", "session_id" => session}, state) do
    Coordinator.event(state.run.id, {:session, session})
    %{state | session: session}
  end

  def handle_event(
        %{
          "type" => "stream_event",
          "event" => %{
            "type" => "content_block_delta",
            "delta" => %{"type" => "text_delta", "text" => text}
          }
        },
        state
      ) do
    put_output(state, state.output <> text)
  end

  def handle_event(%{"type" => "assistant", "message" => message}, state) do
    # Full assistant messages are a fallback when partial events aren't available.
    if state.output == "",
      do: put_output(state, Protocol.text_blocks(message["content"])),
      else: state
  end

  def handle_event(%{"type" => "result"} = e, state) do
    state = if is_binary(e["result"]), do: put_output(state, e["result"]), else: state

    error =
      if e["is_error"], do: Enum.join(e["errors"] || [e["result"] || "Claude turn failed"], "\n")

    %{state | finished: {if(error, do: "failed", else: "completed"), error}}
  end

  def handle_event(
        %{
          "type" => "control_request",
          "request_id" => id,
          "request" => %{"subtype" => "can_use_tool"} = request
        },
        state
      ) do
    approval(state, id, request)
  end

  def handle_event(%{"type" => "control_request", "request_id" => id}, state) do
    write(state, %{
      type: "control_response",
      response: %{subtype: "error", request_id: id, error: "Unsupported request"}
    })

    state
  end

  def handle_event(_, state), do: state
end
