defmodule Roundtable.QuotaRetryTest do
  use Roundtable.DataCase, async: false
  alias Roundtable.{Chat, Coordinator, QuotaRetry}
  alias Roundtable.Chat.{CrossRoomRequest, Run}

  setup do
    Application.put_env(:roundtable, :agent_worker, Roundtable.TestWorker)
    Application.put_env(:roundtable, :test_observer, self())
    Application.put_env(:roundtable, :start_agents, true)
    {:ok, room} = Chat.create_room(%{name: "Quota", directory: File.cwd!()})

    {:ok, agent} =
      Chat.create_agent(room.id, %{name: "ada", provider: "claude", auto_retry: true})

    on_exit(fn ->
      Application.put_env(:roundtable, :start_agents, false)
      Application.delete_env(:roundtable, :agent_worker)
      Application.delete_env(:roundtable, :test_observer)
    end)

    %{room: room, agent: agent}
  end

  defp wait_for_quota(ctx, error \\ "Usage limit reached") do
    {:ok, message} = Coordinator.post(ctx.room.id, "@ada Implement T1")
    assert_receive {:agent_started, pid, _, run, _}, 1000
    Coordinator.event(run.id, {:session, "saved-session"})
    Coordinator.event(run.id, {:output, "T1 files updated, tests still pending"})
    ref = Process.monitor(pid)
    GenServer.cast(pid, {:fail, error})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)
    {message, Repo.get!(Run, run.id)}
  end

  test "waiting survives recovery, resumes the same specialist session and preserves queue order",
       ctx do
    {:ok, lead} = Chat.create_agent(ctx.room.id, %{name: "lead", provider: "codex"})
    Chat.set_team_head(lead.id)
    {message, waiting} = wait_for_quota(ctx)
    assert waiting.status == "waiting_quota"
    assert waiting.retry_count == 1
    assert waiting.output =~ "files updated"
    assert waiting.retry_context =~ "files updated"
    Coordinator.post(ctx.room.id, "@ada Next task")
    refute_receive {:agent_started, _, _, _, _}, 50
    Chat.recover()
    assert Repo.get!(Run, waiting.id).status == "waiting_quota"
    Coordinator.resume_due(DateTime.add(waiting.retry_at, -1))
    refute_receive {:agent_started, _, _, _, _}, 50
    Coordinator.resume_due(waiting.retry_at)
    assert_receive {:agent_started, pid, agent, run, prompt}, 1000
    assert agent.session_id == "saved-session"
    assert run.id == waiting.id
    assert run.message_id == message.id
    assert prompt =~ "RESUMING AFTER A QUOTA WAIT"
    assert prompt =~ "files updated"
    Coordinator.resume_due(waiting.retry_at)
    refute_receive {:agent_started, _, _, _, _}, 50
    ref = Process.monitor(pid)
    GenServer.cast(pid, {:finish, "T1 complete"})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    assert_receive {:agent_started, _, next_agent, next, _}, 1000
    assert next.id != waiting.id
    assert next_agent.session_id == nil
    assert Enum.count(Chat.messages(ctx.room.id), &(&1.body == "T1 complete")) == 1
    Coordinator.stop(ctx.agent.id)
  end

  test "the supervised clock picks up overdue persisted waits", ctx do
    {_, waiting} = wait_for_quota(ctx)
    Chat.change(waiting, retry_at: DateTime.add(DateTime.utc_now(:second), -3600))
    assert {:noreply, %{}} = QuotaRetry.handle_info(:tick, %{})
    assert_receive {:agent_started, _, _, run, _}, 1000
    assert run.id == waiting.id
    Coordinator.stop(ctx.agent.id)
  end

  test "waiting releases worker capacity and does not block unrelated agents", ctx do
    {_, waiting} = wait_for_quota(ctx)
    {:ok, other} = Chat.create_agent(ctx.room.id, %{name: "other", provider: "codex"})
    Coordinator.post(ctx.room.id, "@other Independent work")
    assert_receive {:agent_started, _, active, _, _}, 1000
    assert active.id == other.id
    assert Repo.get!(Run, waiting.id).status == "waiting_quota"
    Coordinator.stop(other.id)
    Coordinator.stop(ctx.agent.id)
  end

  test "a structured reset time persists and manual retry can bypass it", ctx do
    Coordinator.post(ctx.room.id, "@ada Work")
    assert_receive {:agent_started, pid, _, run, _}, 1000
    reset = DateTime.add(DateTime.utc_now(:second), 86_400)

    Coordinator.event(
      run.id,
      {:done, "rate_limited", %{message: "Wait", resets_at: DateTime.to_unix(reset)}}
    )

    _ = :sys.get_state(Coordinator)
    assert Repo.get!(Run, run.id).retry_at == DateTime.add(reset, 15)
    # The fake worker does not stop itself after a directly injected event.
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    Coordinator.retry(run.id)
    assert_receive {:agent_started, _, _, resumed, _}, 1000
    assert resumed.retry_at == nil
    assert resumed.id == run.id
    Coordinator.stop(ctx.agent.id)
  end

  test "each failed quota retry increases the backoff", ctx do
    {_, waiting} = wait_for_quota(ctx)
    Coordinator.resume_due(waiting.retry_at)
    assert_receive {:agent_started, pid, _, _, _}, 1000
    ref = Process.monitor(pid)
    before = DateTime.utc_now(:second)
    GenServer.cast(pid, {:fail, "Rate limit exceeded"})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)
    second = Repo.get!(Run, waiting.id)
    assert second.retry_count == 2
    assert DateTime.diff(second.retry_at, before) >= 1800
    Coordinator.stop(ctx.agent.id)
  end

  test "stopping, resetting, clearing, removing or disabling retries cancels pending waits",
       ctx do
    for action <- [:stop, :reset, :clear, :disable] do
      Chat.update_agent(ctx.agent.id, %{auto_retry: true})
      {_, waiting} = wait_for_quota(ctx)
      Coordinator.post(ctx.room.id, "@ada queued")

      case action do
        :stop -> Coordinator.stop(ctx.agent.id)
        :reset -> Coordinator.reset(ctx.agent.id)
        :clear -> Coordinator.clear_history(ctx.room.id)
        :disable -> Chat.update_agent(ctx.agent.id, %{auto_retry: false})
      end

      Coordinator.resume_due(DateTime.add(waiting.retry_at, 86_400))
      refute_receive {:agent_started, _, _, _, _}, 50
      refute Chat.waiting_for_quota?(ctx.agent.id)
    end

    Chat.update_agent(ctx.agent.id, %{auto_retry: true})
    {_, waiting} = wait_for_quota(ctx)
    Coordinator.remove_agent(ctx.agent.id)
    Coordinator.resume_due(waiting.retry_at)
    refute_receive {:agent_started, _, _, _, _}, 50
  end

  test "a stale clock selection cannot resurrect a cancelled wait", ctx do
    {_, waiting} = wait_for_quota(ctx)
    Chat.update_agent(ctx.agent.id, %{auto_retry: false})
    refute Chat.resume_quota_retry(waiting, [])
    assert Repo.get!(Run, waiting.id).status == "stopped"
  end

  test "quota retries are opt-in and ordinary failures remain failed", ctx do
    Chat.update_agent(ctx.agent.id, %{auto_retry: false})
    {_, run} = wait_for_quota(ctx)
    assert run.status == "failed"
    assert run.retry_at == nil
    Chat.update_agent(ctx.agent.id, %{auto_retry: true})

    for error <- ["Context window exceeded", "Authentication failed", "Turn exceeded 30 minutes"] do
      {_, run} = wait_for_quota(ctx, error)
      assert run.status == "failed"
      assert run.retry_at == nil
    end
  end

  test "cross-room requests remain open during a quota wait", _ctx do
    {:ok, other} = Chat.create_room(%{name: "Asker", directory: File.cwd!()})
    {:ok, _} = Chat.request_from_room("ask", other.id, "quota/ada", "Check T1")
    Coordinator.resume_due(DateTime.utc_now(:second))
    assert_receive {:agent_started, pid, _, run, _}, 1000
    ref = Process.monitor(pid)
    GenServer.cast(pid, {:fail, "Usage limit reached"})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)
    assert Repo.one!(CrossRoomRequest).status == "delivered"
    waiting = Repo.get!(Run, run.id)
    Coordinator.resume_due(waiting.retry_at)
    assert_receive {:agent_started, next_pid, _, _, _}, 1000
    next_ref = Process.monitor(next_pid)
    GenServer.cast(next_pid, {:finish, "T1 verified"})
    assert_receive {:DOWN, ^next_ref, :process, ^next_pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)
    assert Repo.one!(CrossRoomRequest).status == "answered"
    assert Enum.any?(Chat.messages(other.id), &String.contains?(&1.body, "T1 verified"))
  end
end
