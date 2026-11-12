defmodule Roundtable.Agents.Acp do
  @moduledoc """
  The Agent Client Protocol (ACP) as a Roundtable client: JSON-RPC over stdio,
  shared by every CLI that speaks it (`grok agent stdio`, `vibe-acp`).

  ACP gives a CLI what its one-shot print mode could not: the room tools are
  handed to each session in `session/new` (or `session/resume`) as an MCP
  server, so they live only as long as the turn, and a tool that needs
  permission is asked of the client with `session/request_permission`, which
  becomes an approval card in the room.

  The adapter using this supplies its label and, optionally, one request to
  make once the session is open and before the prompt (Vibe sets its approval
  mode there). Everything else is the protocol's.
  """
  import Roundtable.Agents.Worker, only: [write: 2, put_output: 2, approval: 3, activity: 2]

  alias Roundtable.Agents.Activity
  alias Roundtable.{Coordinator, MCP}

  @initialize 1
  @open_session 2
  @prompt 3
  # A session that cannot be resumed, from a CLI reinstalled or a history
  # removed, is replaced rather than failing every later turn the same way.
  @fresh_session 4
  @before_prompt 5

  # `label/0` comes from `Roundtable.Agents.Adapter`, which every user of this
  # implements too.
  @doc "A request to make once the session is open and before the prompt, or nil."
  @callback before_prompt(map()) :: {String.t(), map()} | nil

  def start(state) do
    write(state, %{
      jsonrpc: "2.0",
      id: @initialize,
      method: "initialize",
      params: %{
        protocolVersion: 1,
        # The room hands out no files or terminals of its own; the CLI uses
        # its built-in tools in the participant's folder.
        clientCapabilities: %{fs: %{readTextFile: false, writeTextFile: false}, terminal: false},
        clientInfo: %{name: "roundtable", version: "0.1.0"}
      }
    })
  end

  @doc "Answers a permission request with the option that matches the human's decision."
  def approve(state, id, decision, request) do
    outcome =
      case pick(request["options"], decision) do
        nil -> %{outcome: "cancelled"}
        option_id -> %{outcome: "selected", optionId: option_id}
      end

    write(state, %{jsonrpc: "2.0", id: id, result: %{outcome: outcome}})
  end

  # A one-off answer first: the human approved this call, not every later one.
  defp pick(options, decision) when is_list(options) do
    kinds =
      if decision == "accept",
        do: ["allow_once", "allow_always"],
        else: ["reject_once", "reject_always"]

    Enum.find_value(kinds, fn kind ->
      Enum.find_value(options, &(&1["kind"] == kind && &1["optionId"]))
    end)
  end

  defp pick(_options, _decision), do: nil

  def handle_event(%{"id" => @initialize, "result" => _}, state, _adapter) do
    open_session(state, if(state.session, do: "session/resume", else: "session/new"))
  end

  def handle_event(%{"id" => @open_session, "error" => _}, %{session: session} = state, _adapter)
      when is_binary(session),
      do: open_session(%{state | session: nil}, "session/new", @fresh_session)

  def handle_event(%{"id" => id, "result" => result}, state, adapter)
      when id in [@open_session, @fresh_session] do
    session = result["sessionId"] || state.session
    if session != state.session, do: Coordinator.event(state.run.id, {:session, session})
    state = Map.put(state, :session, session)

    case adapter.before_prompt(state) do
      {method, params} ->
        write(state, %{
          jsonrpc: "2.0",
          id: @before_prompt,
          method: method,
          params: Map.put(params, :sessionId, session)
        })

        state

      nil ->
        prompt(state)
    end
  end

  def handle_event(%{"id" => @before_prompt, "result" => _}, state, _adapter), do: prompt(state)

  def handle_event(%{"id" => @prompt, "result" => result}, state, adapter) do
    state = Roundtable.Agents.Usage.report(state, tokens(result["usage"]))
    %{state | finished: stopped(result["stopReason"], state, adapter.label())}
  end

  def handle_event(%{"id" => id, "error" => error}, state, _adapter) when is_integer(id),
    do: %{state | finished: Roundtable.Quota.failure(error)}

  def handle_event(
        %{"id" => id, "method" => "session/request_permission", "params" => params},
        state,
        _adapter
      ) do
    call = params["toolCall"] || %{}

    approval(
      state,
      id,
      Map.merge(params, %{"display_name" => call["title"], "input" => call["rawInput"]})
    )
  end

  # A CLI may ask the client for other things, such as its own extensions; the
  # room offers none of them, and an unanswered request would stall the turn.
  def handle_event(%{"id" => id, "method" => method}, state, _adapter) do
    write(state, %{
      jsonrpc: "2.0",
      id: id,
      error: %{code: -32_601, message: "Roundtable does not support #{method}."}
    })

    state
  end

  def handle_event(
        %{"method" => "session/update", "params" => %{"update" => update}},
        state,
        _adapter
      ),
      do: update(update, state)

  def handle_event(_event, state, _adapter), do: state

  defp prompt(state) do
    write(state, %{
      jsonrpc: "2.0",
      id: @prompt,
      method: "session/prompt",
      params: %{sessionId: state.session, prompt: [%{type: "text", text: state.prompt}]}
    })

    Map.put(state, :prompting, true)
  end

  # A resumed session can replay its history before the turn; only what comes
  # after the prompt was sent belongs to this turn.
  defp update(_update, state) when not is_map_key(state, :prompting), do: state

  defp update(%{"sessionUpdate" => "agent_message_chunk", "content" => content}, state) do
    case content do
      %{"type" => "text", "text" => text} when is_binary(text) ->
        # Text on both sides of a tool call is two paragraphs, not one run-on.
        gap = if Map.get(state, :after_tool, false) and state.output != "", do: "\n\n", else: ""

        state
        |> Map.put(:after_tool, false)
        |> put_output(state.output <> gap <> text)

      _ ->
        state
    end
  end

  defp update(%{"sessionUpdate" => "agent_thought_chunk"}, state),
    do: activity(state, Activity.thinking())

  defp update(%{"sessionUpdate" => "tool_call"} = call, state),
    do: state |> Map.put(:after_tool, true) |> activity(Activity.acp(call))

  defp update(%{"sessionUpdate" => "tool_call_update", "status" => status}, state)
       when status in ["completed", "failed"],
       do: activity(state, Activity.thinking())

  defp update(_update, state), do: state

  # The turn's reason for stopping. A refusal or cancel with nothing said is a
  # failure the room should see; one that said something is its answer.
  defp stopped(reason, state, label)
       when reason in ["end_turn", "max_tokens", "max_turn_requests"] do
    if state.output != "",
      do: {"completed", nil},
      else: {"failed", "#{label} ended its turn (#{reason}) without a reply."}
  end

  defp stopped("refusal", _state, label),
    do: {"failed", "#{label} declined to answer this request."}

  defp stopped("cancelled", _state, label), do: {"failed", "#{label} cancelled this turn."}
  defp stopped(reason, _state, label), do: {"failed", "#{label} stopped (#{inspect(reason)})."}

  defp tokens(usage) do
    Roundtable.Usage.tokens(usage, [
      {"input", "inputTokens"},
      {"output", "outputTokens"},
      {"cached", "cachedReadTokens"},
      {"cache_write", "cachedWriteTokens"}
    ])
  end

  defp open_session(state, method, id \\ @open_session) do
    params = %{cwd: state.agent.directory, mcpServers: tools(state.agent)}
    params = if state.session, do: Map.put(params, :sessionId, state.session), else: params
    write(state, %{jsonrpc: "2.0", id: id, method: method, params: params})
    state
  end

  # The token travels over stdin in the session request, never in the argument
  # list, and is good only for this turn: see `Roundtable.MCP.token/1`.
  defp tools(agent) do
    if MCP.offered?(agent) do
      [
        %{
          type: "http",
          name: "roundtable",
          url: MCP.url(),
          headers: [%{name: "Authorization", value: "Bearer #{MCP.token(agent)}"}]
        }
      ]
    else
      []
    end
  end
end
