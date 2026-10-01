defmodule Roundtable.Coordinator do
  @moduledoc """
  Serialises every queue transition in the service.

  One process owns which turns are running, so concurrent requests cannot start the
  same agent twice and a delivery cannot interleave with a retry. It holds no
  durable state of its own: runs live in the database, and this process only
  decides what happens next.
  """
  use GenServer
  require Logger

  # Turns that may run at once, across every room.
  @max_workers 4
  import Ecto.Query
  alias Roundtable.{Chat, Git, Repo, Supervision, Usage}
  alias Roundtable.Chat.{Agent, Message, Run}

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def post(room_id, body, opts \\ []),
    do: GenServer.call(__MODULE__, {:post, room_id, body, opts})

  def build_team(attrs), do: GenServer.call(__MODULE__, {:build_team, attrs})

  def stop(agent_id), do: GenServer.call(__MODULE__, {:stop, agent_id})
  def reset(agent_id), do: GenServer.call(__MODULE__, {:reset, agent_id})
  def clear_history(room_id), do: GenServer.call(__MODULE__, {:clear_history, room_id})
  def resume_due(now), do: GenServer.call(__MODULE__, {:resume_due, now})
  def retry(run_id), do: GenServer.call(__MODULE__, {:retry, run_id})

  @doc "Runs the watchdog once: see `Roundtable.Watchdog`."
  def supervise(now), do: GenServer.call(__MODULE__, {:supervise, now})

  @doc "Stops a participant's queue, then removes it."
  def remove_agent(agent_id), do: GenServer.call(__MODULE__, {:remove_agent, agent_id})

  @doc "Stops every participant in a room, then removes the room and its history."
  def remove_room(room_id), do: GenServer.call(__MODULE__, {:remove_room, room_id})

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

  def handle_call({:build_team, attrs}, _, state) do
    result = Chat.build_team(attrs)
    {:reply, result, schedule(state)}
  end

  def handle_call(:approvals, _, state), do: {:reply, state.approvals, state}

  def handle_call({:stop, agent_id}, _, state) do
    state = cancel_agent(state, agent_id)
    # /stop cannot cancel a turn that already ended in a crash, and leaving it
    # interrupted invites the watchdog to restart it about a minute later.
    Chat.abandon_latest_failure(agent_id)
    {:reply, :ok, schedule(state)}
  end

  def handle_call({:reset, agent_id}, _, state) do
    state = cancel_agent(state, agent_id)
    agent = Chat.agent!(agent_id)

    Chat.change(agent,
      session_id: nil,
      session_model: nil,
      session_role: nil,
      session_directory: nil,
      last_seen_id: 0
    )

    Chat.broadcast(agent.room_id)
    {:reply, :ok, state}
  end

  def handle_call({:remove_agent, agent_id}, _, state) do
    # Cancel before deleting: a worker mid-turn holds a row that is about to go.
    state = cancel_agent(state, agent_id)
    {:reply, Chat.delete_agent(agent_id), state}
  end

  def handle_call({:remove_room, room_id}, _, state) do
    state =
      room_id
      |> Chat.agents()
      |> Enum.reduce(state, &cancel_agent(&2, &1.id))

    {:reply, Chat.delete_room(room_id), state}
  end

  def handle_call({:clear_history, room_id}, _, state) do
    state =
      room_id
      |> Chat.agents()
      |> Enum.reduce(state, &cancel_agent(&2, &1.id))

    result = Chat.clear_history(room_id)
    {:reply, result, schedule(state)}
  end

  def handle_call({:resume_due, now}, _, state) do
    for run <- Chat.due_quota_retries(now) do
      if Chat.resume_quota_retry(run, current_model(run)),
        do: Chat.broadcast(Chat.agent!(run.agent_id).room_id)
    end

    {:reply, :ok, schedule(state)}
  end

  def handle_call({:retry, run_id}, _, state) do
    run = Repo.get!(Run, run_id)

    if run.status in ["failed", "interrupted", "stopped", "waiting_quota"] do
      Chat.change(
        run,
        [status: "queued", error: nil, output: "", retry_at: nil] ++ current_model(run)
      )

      Chat.release_held(run.agent_id)
    end

    {:reply, :ok, schedule(state)}
  end

  def handle_call({:supervise, now}, _, state) do
    state = Enum.reduce(state.workers, state, &stop_if_silent(&1, &2, now))
    Enum.each(Chat.supervision_candidates(now), &supervise_run(&1, now))
    Enum.each(Chat.rooms_with_head(), &wake_for_uncommitted(&1, now))
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
    worker = state.workers[run.id]

    # A role edited mid-turn has not reached this session yet.
    Chat.change(agent,
      session_id: session,
      session_model: run.model,
      session_role: worker.role,
      session_directory: worker.directory
    )

    state
  end

  defp apply_event(state, _run, agent, :compacted) do
    Chat.session_compacted(agent)
    state
  end

  defp apply_event(state, run, _agent, {:output, text}) do
    Chat.change(run, output: String.slice(text, 0, 256_000))
    state
  end

  defp apply_event(state, run, _agent, {:tokens, attempt, tokens}) do
    Chat.record_tokens(run, attempt, tokens)
    state
  end

  defp apply_event(state, run, _agent, {:provider_usage, data}) do
    provider = state.workers[run.id].provider

    # Which of Claude's two windows a slot keeps is decided before the write:
    # the choice is Usage's policy, the write stays Chat's. See `Usage.keep/2`.
    current = Map.get(Chat.provider_usage(), provider)

    Chat.record_provider_usage(provider, Usage.keep(current && current.data, data))
    state
  end

  defp apply_event(state, run, agent, {:approval, request_id, params}) do
    if agent.auto_approve do
      grant(state, run, agent, request_id, params)
    else
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
  end

  defp apply_event(state, run, agent, {:done, "failed", error}) do
    case Roundtable.Quota.failure(error) do
      {"rate_limited", quota} -> apply_event(state, run, agent, {:done, "rate_limited", quota})
      {"failed", message} -> complete_event(state, run, agent, "failed", message)
    end
  end

  defp apply_event(state, run, agent, {:done, "rate_limited", quota}) do
    if agent.auto_retry &&
         Chat.wait_for_quota(run, quota.message, quota[:resets_at], DateTime.utc_now(:second)) do
      state |> forget(run.id) |> schedule()
    else
      complete_event(state, run, agent, "failed", quota.message)
    end
  end

  defp apply_event(state, run, agent, {:done, status, error}),
    do: complete_event(state, run, agent, status, error)

  defp complete_event(state, run, agent, status, error) do
    Repo.transaction(fn ->
      Chat.change(run, status: status, error: error)
      finish_turn(status, run, agent, error)
    end)

    if status == "completed", do: wake_if_unhanded(Repo.get!(Run, run.id), agent)

    state = forget(state, run.id)
    # A failed turn blocks queued turns for this participant until explicitly retried.
    state =
      if status != "completed",
        do: cancel_agent(state, agent.id, Supervision.held_back()),
        else: state

    schedule(state)
  end

  # A turn's last approval is what unblocks it; the others were answered while
  # more were still outstanding.
  defp resume_if_last_approval(state, run) do
    if Enum.any?(state.approvals, fn {{run_id, _}, _} -> run_id == run.id end),
      do: :ok,
      else: Chat.change(run, status: "running")
  end

  # A participant set to approve its own tools never stops for the human, so
  # the run stays running and the log is where the decision can be read back.
  defp grant(state, run, agent, request_id, params) do
    %{pid: pid} = state.workers[run.id]
    send(pid, {:approval, request_id, "accept"})
    Logger.info("auto-approved for @#{agent.name} (run #{run.id}): #{tool_name(params)}")
    state
  end

  # The tool's name, never its input: a command can carry a secret typed
  # inline, and the log outlives the turn.
  defp tool_name(params) when is_map(params),
    do: params["display_name"] || params["tool_name"] || params["name"] || "a tool"

  defp tool_name(_params), do: "a tool"

  # A retry is a fresh attempt, so it runs on what the participant runs on now.
  # Retrying after changing the model is how someone gets off a model that just
  # failed — keeping the old one would defeat that.
  defp current_model(%{model_pinned: true}), do: []

  defp current_model(run) do
    agent = Chat.agent!(run.agent_id)
    [model: agent.model, cost_tier: agent.cost_tier]
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
        reply_to: source.id,
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

        {:noreply,
         state |> forget(id) |> cancel_agent(run.agent_id, Supervision.held_back()) |> schedule()}

      nil ->
        {:noreply, state}
    end
  end

  # A turn that has gone quiet is stopped and left interrupted, which is what
  # the rest of the watchdog already knows how to retry.
  defp stop_if_silent({id, worker}, state, now) do
    # A row can be gone while its worker is still being torn down.
    run = Repo.get(Run, id)

    if run && Supervision.silent?(run, now) do
      Chat.change(run,
        status: "interrupted",
        error:
          "No activity for #{div(Supervision.silent_after(), 60)} minutes, so it was stopped."
      )

      # Holding the turns queued behind it keeps the stopped one the
      # participant's latest, which is the one the watchdog restarts.
      cancel_agent(state, worker.agent_id, Supervision.held_back())
    else
      state
    end
  end

  defp supervise_run(run, now) do
    agent = run.agent

    case Supervision.decide(run, now) do
      :wait ->
        :ok

      {:quota, quota} ->
        if waiting = Chat.wait_for_quota(run, quota.message, quota[:resets_at], now) do
          Chat.release_held(agent.id)
          notice(agent, "hit its usage limit. Its turn resumes at #{clock(waiting.retry_at)}.")
        else
          give_up(run, agent, "hit its usage limit, and automatic quota retry is off for it")
        end

      {:retry, reason} ->
        Chat.supervised_retry(run, current_model(run))
        Chat.release_held(agent.id)
        attempt = run.supervised_retries + 1

        notice(
          agent,
          "stopped (#{Supervision.gist(reason)}). Restarting its turn, attempt #{attempt} of #{Supervision.max_retries()}."
        )

      {:give_up, reason} ->
        give_up(run, agent, "could not finish (#{Supervision.gist(reason)})")
    end
  end

  defp give_up(run, agent, what) do
    Chat.give_up(run)

    # Held turns follow the failed one only until someone retries, so the
    # notice says what stays stuck instead of implying all is well later.
    text =
      "#{agent.name} #{what}. It needs attention; its turn will not be restarted, " <>
        "and turns queued behind it stay held back until one is retried."

    case wake_target(agent) do
      nil -> Chat.supervisor_notice(agent.room_id, text, "notice")
      head -> wake(head, text)
    end
  end

  defp notice(agent, what),
    do: Chat.supervisor_notice(agent.room_id, "#{agent.name} #{what}", "notice")

  # A specialist that finishes without passing the work on leaves it with
  # nobody. The head is the one who decides what happens next.
  defp wake_if_unhanded(run, agent) do
    with head when not is_nil(head) <- wake_target(agent),
         [] <- Chat.recipients(run.output, Chat.agents(agent.room_id)),
         true <- String.trim(run.output) != "" do
      wake(
        head,
        "#{agent.name} finished without handing the work on. Its reply begins: " <>
          "“#{Supervision.gist(run.output)}”"
      )
    end
  end

  # Work left in the tree with nobody running is work nobody is looking at.
  # One reminder per quiet spell: a new turn has to end before there is another.
  defp wake_for_uncommitted(room_id, now) do
    with %DateTime{} = quiet <- Chat.room_quiet_since(room_id),
         true <- DateTime.diff(now, quiet) >= 600,
         0 <- Chat.supervisor_notices_since(room_id, "uncommitted", quiet),
         head when not is_nil(head) <- Chat.team_head(room_id),
         directory when directory not in [nil, ""] <- Chat.effective_directory(room_id),
         {:ok, %{entries: [_ | _] = entries}} <- Git.status(directory) do
      wake(
        head,
        "#{length(entries)} uncommitted change(s) have sat in #{directory} for over ten " <>
          "minutes with no turn running. Commit, park on a wip/ branch, or hand them on.",
        "uncommitted"
      )
    end
  end

  defp wake_target(agent) do
    case Chat.team_head(agent.room_id) do
      %{id: id} when id == agent.id -> nil
      head -> head
    end
  end

  # Bounded so a head and a specialist cannot keep waking each other: past
  # the limit the notice is still posted, it just starts no turn.
  @wakes_per_hour 6

  defp wake(head, text, topic \\ "wake") do
    since = DateTime.add(DateTime.utc_now(:second), -3600, :second)

    wakes =
      Chat.supervisor_notices_since(head.room_id, "wake", since) +
        Chat.supervisor_notices_since(head.room_id, "uncommitted", since)

    if wakes < @wakes_per_hour do
      Chat.supervisor_notice(head.room_id, "@#{head.name} #{text}", topic_for(topic))
    else
      Chat.supervisor_notice(head.room_id, "#{head.name}: #{text}", "notice")
    end
  end

  defp topic_for("uncommitted"), do: "uncommitted"
  defp topic_for(_), do: "wake"

  defp clock(%DateTime{} = at) do
    {{_, _, _}, {hour, minute, _}} =
      at
      |> DateTime.to_naive()
      |> NaiveDateTime.to_erl()
      |> :calendar.universal_time_to_local_time()

    :io_lib.format("~2..0B:~2..0B", [hour, minute]) |> to_string()
  end

  defp clock(_), do: "the provider's reset"

  # One turn per participant, and @max_workers across the service. A run that
  # cannot start now stays queued and is reconsidered on the next transition.
  defp start_if_free(run, state) do
    busy = Enum.any?(state.workers, fn {_, w} -> w.agent_id == run.agent_id end)

    if map_size(state.workers) < @max_workers and not busy and
         not Chat.waiting_for_quota?(run.agent_id),
       do: start_worker(run, state),
       else: state
  end

  defp start_worker(run, state) do
    agent = run.agent_id |> then(&Repo.get!(Agent, &1)) |> resolve_directory()

    if agent.directory do
      agent = reset_stale_session(agent, run)
      agent = %{agent | model: run.model, cost_tier: run.cost_tier}
      {prompt, until_id} = Chat.prompt(agent, run)

      run =
        Chat.change(run, status: "running", context_until_id: until_id, output: "", error: nil)

      worker_module = Application.get_env(:roundtable, :agent_worker, Roundtable.Agents.Worker)

      case DynamicSupervisor.start_child(
             Roundtable.AgentSupervisor,
             {worker_module, {agent, run, prompt}}
           ) do
        {:ok, pid} ->
          Chat.record_prompt(agent, run)
          Chat.broadcast(agent.room_id)

          worker = %{
            pid: pid,
            ref: Process.monitor(pid),
            agent_id: agent.id,
            provider: agent.provider,
            role: agent.role,
            directory: agent.directory
          }

          %{state | workers: Map.put(state.workers, run.id, worker)}

        {:error, reason} ->
          Chat.change(run, status: "failed", error: inspect(reason))
          Chat.broadcast(agent.room_id)
          state
      end
    else
      Chat.change(run,
        status: "failed",
        error:
          "The team has no folder to work in. Give this team or its project a folder, then retry."
      )

      Chat.broadcast(agent.room_id)
      state
    end
  end

  # A turn works where the team resolves to now: editing the project's folder
  # takes effect on the next turn, not inside a running one. The participant's
  # row follows the resolution so events arriving mid-turn read the same folder.
  defp resolve_directory(agent) do
    case Chat.effective_directory(agent.room_id) do
      directory when directory in [nil, ""] ->
        %{agent | directory: nil}

      directory when directory == agent.directory ->
        agent

      directory ->
        Chat.change(agent, directory: directory)
        %{agent | directory: directory}
    end
  end

  # A model change starts a fresh native session, so a resumed one cannot
  # silently keep running on the model the human moved away from. The same
  # goes for the folder: resuming a transcript rooted in another tree would
  # quietly keep working there.
  defp reset_stale_session(%{session_id: nil} = agent, _run), do: agent

  defp reset_stale_session(agent, %{model: model, retry_count: retries}) do
    head = Chat.team_head(agent.room_id)
    fresh_assignment = head != nil and head.id != agent.id and retries == 0

    if not fresh_assignment and agent.session_model == model and
         agent.session_directory == agent.directory do
      agent
    else
      Chat.change(
        agent,
        session_id: nil,
        session_model: nil,
        session_role: nil,
        session_directory: nil,
        last_seen_id: 0
      )
    end
  end

  defp cancel_agent(state, agent_id, error \\ Supervision.stopped()) do
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
        where:
          r.agent_id == ^agent_id and
            r.status in ["queued", "running", "approval", "waiting_quota"]
      ),
      set: [status: "stopped", retry_at: nil, error: error]
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
