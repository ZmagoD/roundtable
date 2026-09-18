defmodule Roundtable.Coordinator do
  @moduledoc """
  Serialises every queue transition in the service.

  One process owns which turns are running, so two clients cannot start the
  same agent twice and a delivery cannot interleave with a retry. It holds no
  durable state of its own: runs live in the database, and this process only
  decides what happens next.
  """
  use GenServer

  # Turns that may run at once, across every room.
  @max_workers 4
  import Ecto.Query
  alias Roundtable.{Chat, Repo}
  alias Roundtable.Chat.{Agent, Message, Run}

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def post(room_id, body, opts \\ []),
    do: GenServer.call(__MODULE__, {:post, room_id, body, opts})

  def stop(agent_id), do: GenServer.call(__MODULE__, {:stop, agent_id})
  def reset(agent_id), do: GenServer.call(__MODULE__, {:reset, agent_id})
  def retry(run_id), do: GenServer.call(__MODULE__, {:retry, run_id})

  def approve(run_id, request_id, decision),
    do: GenServer.call(__MODULE__, {:approve, run_id, request_id, decision})

  def approvals, do: GenServer.call(__MODULE__, :approvals)
  def event(run_id, event), do: GenServer.cast(__MODULE__, {:event, run_id, event})

  @impl true
  def init(_) do
    {:ok, %{workers: %{}, approvals: %{}}, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    if Application.get_env(:roundtable, :start_agents, true), do: Chat.recover()
    {:noreply, schedule(state)}
  end

  @impl true
  def handle_call({:post, room_id, body, opts}, _, state) do
    result = Chat.post(room_id, body, opts)
    {:reply, result, schedule(state)}
  end

  def handle_call(:approvals, _, state), do: {:reply, state.approvals, state}

  def handle_call({:stop, agent_id}, _, state) do
    {:reply, :ok, schedule(cancel_agent(state, agent_id))}
  end

  def handle_call({:reset, agent_id}, _, state) do
    state = cancel_agent(state, agent_id)
    agent = Chat.agent!(agent_id)
    Chat.change(agent, session_id: nil, session_model: nil, last_seen_id: 0)
    Chat.broadcast(agent.room_id)
    {:reply, :ok, state}
  end

  def handle_call({:retry, run_id}, _, state) do
    run = Repo.get!(Run, run_id)

    if run.status in ["failed", "interrupted", "stopped"] do
      Chat.change(run, status: "queued", error: nil, output: "")
    end

    {:reply, :ok, schedule(state)}
  end

  def handle_call({:approve, id, request_id, decision}, _, state) do
    key = {id, request_id}

    with %{pid: pid} <- state.workers[id],
         approval when not is_nil(approval) <- state.approvals[key],
         true <- decision in ["accept", "decline"] do
      send(pid, {:approval, request_id, decision})
      state = %{state | approvals: Map.delete(state.approvals, key)}
      run = Repo.get!(Run, id)
      resume_if_last_approval(state, run)
      Chat.broadcast(Chat.agent!(run.agent_id).room_id)
      {:reply, :ok, state}
    else
      _ -> {:reply, {:error, "This approval is no longer pending."}, state}
    end
  end

  @impl true
  def handle_cast({:event, id, event}, state) do
    if Map.has_key?(state.workers, id) do
      run = Repo.get!(Run, id)
      agent = Chat.agent!(run.agent_id)
      state = apply_event(state, run, agent, event)
      Chat.broadcast(agent.room_id)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  defp apply_event(state, run, agent, {:session, session}) do
    Chat.change(agent, session_id: session, session_model: run.model)
    state
  end

  defp apply_event(state, run, _agent, {:output, text}) do
    Chat.change(run, output: String.slice(text, 0, 256_000))
    state
  end

  defp apply_event(state, run, agent, {:approval, request_id, params}) do
    Chat.change(run, status: "approval")

    approval = %{
      run_id: run.id,
      request_id: request_id,
      agent: agent.name,
      room_id: agent.room_id,
      params: params
    }

    %{state | approvals: Map.put(state.approvals, {run.id, request_id}, approval)}
  end

  defp apply_event(state, run, agent, {:done, status, error}) do
    Repo.transaction(fn ->
      Chat.change(run, status: status, error: error)
      finish_turn(status, run, agent, error)
    end)

    state = forget(state, run.id)
    # A failed turn blocks queued turns for this participant until explicitly retried.
    state = if status != "completed", do: cancel_agent(state, agent.id), else: state
    schedule(state)
  end

  # A turn's last approval is what unblocks it; the others were answered while
  # more were still outstanding.
  defp resume_if_last_approval(state, run) do
    if Enum.any?(state.approvals, fn {{run_id, _}, _} -> run_id == run.id end),
      do: :ok,
      else: Chat.change(run, status: "running")
  end

  defp finish_turn("completed", run, agent, _error) do
    Chat.change(agent, last_seen_id: run.context_until_id)
    publish_output(run, agent)
    # If this turn was another room's question, carry the answer home.
    Chat.deliver_answer(run.message_id, run.output)
  end

  defp finish_turn(status, run, _agent, error),
    do: Chat.fail_request(run.message_id, error || status)

  defp publish_output(run, agent) do
    if String.trim(run.output) != "" do
      source = Repo.get!(Message, run.message_id)

      Chat.post(agent.room_id, run.output,
        sender: agent.name,
        agent_id: agent.id,
        kind: "agent",
        metadata: %{
          "name" => agent.name,
          "model" => run.model,
          "cost_tier" => run.cost_tier,
          "purpose" => run.purpose
        },
        broadcast: false,
        depth: source.depth + 1
      )
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.workers, fn {_, w} -> w.ref == ref end) do
      {id, _} ->
        run = Repo.get!(Run, id)
        Chat.change(run, status: "interrupted", error: "Agent process exited: #{inspect(reason)}")
        Chat.broadcast(Chat.agent!(run.agent_id).room_id)
        {:noreply, state |> forget(id) |> cancel_agent(run.agent_id) |> schedule()}

      nil ->
        {:noreply, state}
    end
  end

  # One turn per participant, and @max_workers across the service. A run that
  # cannot start now stays queued and is reconsidered on the next transition.
  defp start_if_free(run, state) do
    busy = Enum.any?(state.workers, fn {_, w} -> w.agent_id == run.agent_id end)

    if map_size(state.workers) < @max_workers and not busy,
      do: start_worker(run, state),
      else: state
  end

  defp start_worker(run, state) do
    agent = run.agent_id |> then(&Repo.get!(Agent, &1)) |> reset_stale_session(run)
    agent = %{agent | model: run.model, cost_tier: run.cost_tier}
    {prompt, until_id} = Chat.prompt(agent, run)
    run = Chat.change(run, status: "running", context_until_id: until_id)
    worker_module = Application.get_env(:roundtable, :agent_worker, Roundtable.Agents.Worker)

    case DynamicSupervisor.start_child(
           Roundtable.AgentSupervisor,
           {worker_module, {agent, run, prompt}}
         ) do
      {:ok, pid} ->
        Chat.broadcast(agent.room_id)
        worker = %{pid: pid, ref: Process.monitor(pid), agent_id: agent.id}
        %{state | workers: Map.put(state.workers, run.id, worker)}

      {:error, reason} ->
        Chat.change(run, status: "failed", error: inspect(reason))
        Chat.broadcast(agent.room_id)
        state
    end
  end

  # A model change starts a fresh native session, so a resumed one cannot
  # silently keep running on the model the human moved away from.
  defp reset_stale_session(%{session_id: nil} = agent, _run), do: agent

  defp reset_stale_session(%{session_model: model} = agent, %{model: model}), do: agent

  defp reset_stale_session(agent, _run),
    do: Chat.change(agent, session_id: nil, session_model: nil, last_seen_id: 0)

  defp cancel_agent(state, agent_id) do
    state =
      Enum.reduce(state.workers, state, fn {id, worker}, acc ->
        if worker.agent_id == agent_id do
          DynamicSupervisor.terminate_child(Roundtable.AgentSupervisor, worker.pid)
          forget(acc, id)
        else
          acc
        end
      end)

    Repo.update_all(
      from(r in Run,
        where: r.agent_id == ^agent_id and r.status in ["queued", "running", "approval"]
      ),
      set: [status: "stopped", error: "Stopped. Retry to continue this assignment."]
    )

    Chat.broadcast(Chat.agent!(agent_id).room_id)
    state
  end

  defp forget(state, id) do
    if worker = state.workers[id], do: Process.demonitor(worker.ref, [:flush])

    %{
      state
      | workers: Map.delete(state.workers, id),
        approvals: Map.reject(state.approvals, fn {{run_id, _}, _} -> run_id == id end)
    }
  end

  defp schedule(state) do
    if Application.get_env(:roundtable, :start_agents, true) do
      Repo.all(from r in Run, where: r.status == "queued", order_by: r.id)
      |> Enum.reduce(state, &start_if_free/2)
    else
      state
    end
  end
end
