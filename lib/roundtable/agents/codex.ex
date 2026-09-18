defmodule Roundtable.Agents.Codex do
  @behaviour Roundtable.Agents.Adapter
  import Roundtable.Agents.Worker, only: [write: 2, put_output: 2, joined: 1, approval: 3]
  alias Roundtable.Coordinator
  def id, do: "codex"
  def label, do: "Codex"
  def command(_agent, _prompt), do: {"codex", ["app-server"]}

  def start(state),
    do:
      write(state, %{
        id: 1,
        method: "initialize",
        params: %{clientInfo: %{name: "roundtable", version: "0.1.0"}}
      })

  def approve(state, id, decision, _request),
    do: write(state, %{id: id, result: %{decision: decision}})

  def exit_status(code, state), do: {"failed", "Codex exited (#{code}). #{state.diagnostics}"}

  def handle_event(%{"id" => 1, "result" => _}, state) do
    write(state, %{method: "initialized", params: %{}})

    params = %{
      cwd: state.agent.directory,
      approvalPolicy: "on-request",
      sandbox: "workspace-write"
    }

    params = if state.agent.model, do: Map.put(params, :model, state.agent.model), else: params

    {method, params} =
      if state.session,
        do: {"thread/resume", Map.put(params, :threadId, state.session)},
        else: {"thread/start", params}

    write(state, %{id: 2, method: method, params: params})
    state
  end

  def handle_event(%{"id" => 2, "result" => %{"thread" => %{"id" => session}}}, state) do
    Coordinator.event(state.run.id, {:session, session})

    write(state, %{
      id: 3,
      method: "turn/start",
      params: %{threadId: session, input: [%{type: "text", text: state.prompt}]}
    })

    %{state | session: session}
  end

  def handle_event(%{"error" => error, "id" => _}, state),
    do: %{state | finished: {"failed", error["message"] || inspect(error)}}

  def handle_event(%{"method" => "item/agentMessage/delta", "params" => p}, state) do
    items = Map.update(state.items, p["itemId"], p["delta"], &(&1 <> p["delta"]))

    order =
      if p["itemId"] in state.item_order,
        do: state.item_order,
        else: state.item_order ++ [p["itemId"]]

    state = %{state | items: items, item_order: order}
    put_output(state, joined(state))
  end

  def handle_event(
        %{
          "method" => "item/completed",
          "params" => %{"item" => %{"type" => "agentMessage"} = item}
        },
        state
      ) do
    items = Map.put(state.items, item["id"], item["text"] || "")

    order =
      if item["id"] in state.item_order,
        do: state.item_order,
        else: state.item_order ++ [item["id"]]

    final = if item["phase"] == "final_answer", do: item["text"], else: state.final_output
    state = %{state | items: items, item_order: order, final_output: final}
    put_output(state, joined(state))
  end

  def handle_event(%{"method" => "turn/completed", "params" => %{"turn" => turn}}, state) do
    state = if state.final_output, do: put_output(state, state.final_output), else: state
    status = if turn["status"] == "completed", do: "completed", else: "failed"
    %{state | finished: {status, get_in(turn, ["error", "message"])}}
  end

  def handle_event(%{"id" => id, "method" => method, "params" => params}, state)
      when method in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"] do
    approval(state, id, params)
  end

  def handle_event(%{"id" => id, "method" => method}, state) do
    write(state, %{
      id: id,
      error: %{
        code: -32601,
        message: "Roundtable does not support #{method}. Ask the human in the room instead."
      }
    })

    state
  end

  def handle_event(_, state), do: state
end
