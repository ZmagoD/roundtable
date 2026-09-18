defmodule Roundtable.Agents.Messages do
  @moduledoc """
  Events in the Anthropic Messages wire format.

  Claude Code speaks it, and Grok CLI documents its
  `--output-format streaming-messages-json` as "NDJSON in the Anthropic
  Messages API wire format". The clauses that are genuinely shared live here
  rather than being written twice and drifting apart the first time one of them
  is fixed.

  Returns `:unhandled` for anything it does not recognise, so an adapter can
  add the parts that are its own — Claude Code's approval channel, for one,
  which Grok has no equivalent of.
  """
  import Roundtable.Agents.Worker, only: [put_output: 2]

  alias Roundtable.Agents.Protocol
  alias Roundtable.Coordinator

  @doc "Returns `{:ok, state}` or `:unhandled`."
  def handle(event, state)

  def handle(%{"type" => "system", "session_id" => session}, state) when session != "" do
    Coordinator.event(state.run.id, {:session, session})
    {:ok, %{state | session: session}}
  end

  def handle(
        %{
          "type" => "stream_event",
          "event" => %{
            "type" => "content_block_delta",
            "delta" => %{"type" => "text_delta", "text" => text}
          }
        },
        state
      ) do
    {:ok, put_output(state, state.output <> text)}
  end

  # Whole assistant messages are the fallback when partial events aren't
  # available; they must not clobber text the deltas already produced.
  def handle(%{"type" => "assistant", "message" => message}, state) do
    if state.output == "",
      do: {:ok, put_output(state, Protocol.text_blocks(message["content"]))},
      else: {:ok, state}
  end

  def handle(%{"type" => "result"} = event, state) do
    state = if is_binary(event["result"]), do: put_output(state, event["result"]), else: state

    error =
      if event["is_error"],
        do: Enum.join(event["errors"] || [event["result"] || "The turn failed"], "\n")

    {:ok, %{state | finished: {if(error, do: "failed", else: "completed"), error}}}
  end

  def handle(_event, _state), do: :unhandled
end
