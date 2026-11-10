defmodule Roundtable.FailoverTest do
  use Roundtable.DataCase, async: false
  alias Roundtable.{Chat, Coordinator, Repo}
  alias Roundtable.Chat.Run

  @installed %{"claude" => true, "codex" => true, "opencode" => true, "grok" => true}

  setup do
    Application.put_env(:roundtable, :agent_worker, Roundtable.TestWorker)
    Application.put_env(:roundtable, :test_observer, self())
    Application.put_env(:roundtable, :start_agents, true)
    Application.put_env(:roundtable, :installed_providers, @installed)

    {:ok, room} = Chat.create_room(%{name: "Handover", directory: File.cwd!()})

    {:ok, ada} =
      Chat.create_agent(room.id, %{
        name: "ada",
        provider: "claude",
        role: "Implement the ticket",
        auto_retry: true
      })

    {:ok, bob} =
      Chat.create_agent(room.id, %{
        name: "bob",
        provider: "codex",
        role: "Implement the ticket",
        cost_tier: "standard"
      })

    {:ok, local} =
      Chat.create_agent(room.id, %{
        name: "local",
        provider: "opencode",
        role: "Implement the ticket",
        cost_tier: "economy"
      })

    on_exit(fn ->
      Application.put_env(:roundtable, :start_agents, false)
      Application.delete_env(:roundtable, :agent_worker)
      Application.delete_env(:roundtable, :test_observer)
      Application.delete_env(:roundtable, :installed_providers)
    end)

    # No team head anywhere: a finished turn would otherwise wake the head and
    # its turn would race the next assertion in the shared observer mailbox.
    Chat.clear_team_head(room.id)

    %{room: room, ada: ada, bob: bob, local: local}
  end

  defp stop_all(room_id) do
    Enum.each(Chat.agents(room_id), &Coordinator.stop(&1.id))
  end

  defp run_out_of_quota(ctx, body \\ "@ada Implement T1") do
    {:ok, message} = Coordinator.post(ctx.room.id, body)
    assert_receive {:agent_started, pid, _, run, _}, 1000
    Coordinator.event(run.id, {:output, "T1 files updated, tests still pending"})
    ref = Process.monitor(pid)
    GenServer.cast(pid, {:fail, "Usage limit reached"})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)
    {message, run}
  end

  test "a quota failure hands the turn to the teammate with the same role", ctx do
    {_message, run} = run_out_of_quota(ctx)

    assert_receive {:agent_started, pid, agent, moved, prompt}, 1000
    assert agent.id == ctx.bob.id
    assert moved.id == run.id
    assert moved.agent_id == ctx.bob.id
    assert prompt =~ "RESUMING AN INTERRUPTED ASSIGNMENT"
    assert prompt =~ "T1 files updated"

    notice =
      ctx.room.id
      |> Chat.messages()
      |> Enum.find(&(&1.sender == "supervisor"))

    assert notice.body =~ "ada ran out of provider quota"
    assert notice.body =~ "bob"
    # The backup's turn is already queued; a mention here would queue it twice.
    refute notice.body =~ "@bob"

    ref = Process.monitor(pid)
    GenServer.cast(pid, {:finish, "Done by bob"})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)
    assert Enum.any?(Chat.messages(ctx.room.id), &(&1.body == "Done by bob"))
    stop_all(ctx.room.id)
  end

  test "the turns queued behind the failure move with it and keep their order", ctx do
    {:ok, _first} = Coordinator.post(ctx.room.id, "@ada Task one")
    assert_receive {:agent_started, pid, _, run, _}, 1000
    {:ok, second} = Coordinator.post(ctx.room.id, "@ada Task two")
    Coordinator.event(run.id, {:output, "T1 files updated, tests still pending"})
    ref = Process.monitor(pid)
    GenServer.cast(pid, {:fail, "Usage limit reached"})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)

    assert_receive {:agent_started, p2, agent, moved, prompt}, 1000
    assert agent.id == ctx.bob.id
    assert moved.id == run.id
    assert prompt =~ "Task one"
    assert prompt =~ "RESUMING AN INTERRUPTED ASSIGNMENT"

    ref2 = Process.monitor(p2)
    GenServer.cast(p2, {:finish, "One done"})
    assert_receive {:DOWN, ^ref2, :process, ^p2, :normal}, 1000

    assert_receive {:agent_started, _, _, next, prompt2}, 1000
    assert next.message_id == second.id
    assert Repo.get!(Run, next.id).agent_id == ctx.bob.id
    assert prompt2 =~ "Task two"
    refute prompt2 =~ "RESUMING AN INTERRUPTED ASSIGNMENT"
    stop_all(ctx.room.id)
  end

  test "a pinned model follows the turn on the same provider and yields on another" do
    {:ok, other} = Chat.create_room(%{name: "Pinned", directory: File.cwd!()})

    {:ok, peer} =
      Chat.create_agent(other.id, %{
        name: "peer",
        provider: "claude",
        role: "Implement the ticket"
      })

    # Without this, finishing a handover below wakes the head and races the
    # next assertion in the shared observer mailbox.
    Chat.clear_team_head(other.id)

    Coordinator.post(other.id, "@peer Pinned work")
    assert_receive {:agent_started, pid, _, run, _}, 1000
    Chat.change(run, model: "opus", model_pinned: true)
    ref = Process.monitor(pid)
    GenServer.cast(pid, {:fail, "Usage limit reached"})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)

    # The room has no other participant, so nobody can take it and the turn fails.
    assert Repo.get!(Run, run.id).status == "failed"

    {:ok, mate} =
      Chat.create_agent(other.id, %{name: "mate", provider: "codex", role: "Implement the ticket"})

    Coordinator.post(other.id, "@peer Pinned again")
    assert_receive {:agent_started, pid2, _, run2, _}, 1000
    Chat.change(run2, model: "opus", model_pinned: true)
    Coordinator.event(run2.id, {:output, "partly done"})
    ref2 = Process.monitor(pid2)
    GenServer.cast(pid2, {:fail, "Usage limit reached"})
    assert_receive {:DOWN, ^ref2, :process, ^pid2, :normal}, 1000
    _ = :sys.get_state(Coordinator)

    assert_receive {:agent_started, moved_pid, _, moved, _}, 1000
    assert moved.agent_id == mate.id
    # opus means nothing to the backup's CLI, so the backup works on its default.
    assert moved.model == mate.model

    # The handover ran; let it finish so the pool is free again.
    ref = Process.monitor(moved_pid)
    GenServer.cast(moved_pid, {:finish, "Continued by mate"})
    assert_receive {:DOWN, ^ref, :process, ^moved_pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)

    # Same provider: the human's pinned choice is kept. Mate is taken out of
    # the pool so the handover stays inside the claude participants.
    Chat.change(mate, role: "Reviewer only")

    {:ok, _twin} =
      Chat.create_agent(other.id, %{
        name: "twin",
        provider: "claude",
        role: "Implement the ticket"
      })

    Coordinator.post(other.id, "@twin Pinned third")

    assert_receive {:agent_started, pid3, twin_agent, run3, _}, 1000
    assert twin_agent.id != peer.id
    Chat.change(run3, model: "opus", model_pinned: true)
    ref3 = Process.monitor(pid3)
    GenServer.cast(pid3, {:fail, "Usage limit reached"})
    assert_receive {:DOWN, ^ref3, :process, ^pid3, :normal}, 1000
    _ = :sys.get_state(Coordinator)

    assert_receive {:agent_started, _, agent3, moved3, _}, 1000
    assert agent3.provider == "claude"
    assert moved3.model == "opus"
    assert moved3.model_pinned
    stop_all(other.id)
  end

  test "a busy teammate is skipped for the next one in the pool", ctx do
    Coordinator.post(ctx.room.id, "@bob Own work")
    assert_receive {:agent_started, _, _, _, _}, 1000

    {_message, run} = run_out_of_quota(ctx)

    assert_receive {:agent_started, _, agent, moved, _}, 1000
    assert agent.id == ctx.local.id
    assert moved.id == run.id
    stop_all(ctx.room.id)
  end

  test "a provider already near its limit is not handed work", ctx do
    Chat.record_provider_usage("codex", %{"percent" => 90.0})
    {_message, run} = run_out_of_quota(ctx)

    assert_receive {:agent_started, _, agent, moved, _}, 1000
    assert agent.id == ctx.local.id
    assert moved.id == run.id
    stop_all(ctx.room.id)
  end

  test "a failed economy tier hands to the premium teammate rather than idling" do
    {:ok, room} = Chat.create_room(%{name: "Tiers", directory: File.cwd!()})

    {:ok, _cheap} =
      Chat.create_agent(room.id, %{
        name: "cheap",
        provider: "opencode",
        role: "Do the work",
        cost_tier: "economy"
      })

    {:ok, _mid} =
      Chat.create_agent(room.id, %{
        name: "mid",
        provider: "codex",
        role: "Do the work",
        cost_tier: "standard"
      })

    {:ok, dear} =
      Chat.create_agent(room.id, %{
        name: "dear",
        provider: "claude",
        role: "Do the work",
        cost_tier: "premium"
      })

    Chat.clear_team_head(room.id)

    {:ok, message} = Coordinator.post(room.id, "@cheap Bounded task")
    assert_receive {:agent_started, pid, _, run, _}, 1000
    ref = Process.monitor(pid)
    GenServer.cast(pid, {:fail, "Usage limit reached"})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)

    assert_receive {:agent_started, _, agent, moved, _}, 1000
    assert agent.id == dear.id
    assert moved.id == run.id
    assert moved.message_id == message.id
    stop_all(room.id)
  end

  test "without a teammate the turn waits or fails exactly as before", ctx do
    Chat.change(ctx.bob, role: "Reviewer")
    Chat.change(ctx.local, role: "Reviewer")
    {_, run} = run_out_of_quota(ctx)
    waiting = Repo.get!(Run, run.id)
    assert waiting.status == "waiting_quota"
    assert waiting.agent_id == ctx.ada.id
    stop_all(ctx.room.id)

    {:ok, room} = Chat.create_room(%{name: "Alone", directory: File.cwd!()})

    {:ok, _solo} =
      Chat.create_agent(room.id, %{name: "solo", provider: "claude", role: "Implement the ticket"})

    Coordinator.post(room.id, "@solo Team task")
    assert_receive {:agent_started, pid, _, run, _}, 1000
    ref = Process.monitor(pid)
    GenServer.cast(pid, {:fail, "Usage limit reached"})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)
    assert Repo.get!(Run, run.id).status == "failed"
    stop_all(room.id)
  end

  test "roles that are not shared form no pool, however many empty ones there are", ctx do
    Chat.change(ctx.bob, role: "")
    Chat.change(ctx.local, role: "")
    {_, run} = run_out_of_quota(ctx)
    assert Repo.get!(Run, run.id).status == "waiting_quota"
    assert Repo.get!(Run, run.id).agent_id == ctx.ada.id
    stop_all(ctx.room.id)
  end

  test "the watchdog hands over a failed quota run once a teammate frees up" do
    {:ok, room} = Chat.create_room(%{name: "Watchdog", directory: File.cwd!()})

    {:ok, loner} =
      Chat.create_agent(room.id, %{
        name: "loner",
        provider: "claude",
        role: "Implement the ticket"
      })

    {:ok, mate} =
      Chat.create_agent(room.id, %{name: "mate", provider: "codex", role: "Implement the ticket"})

    Chat.clear_team_head(room.id)

    Coordinator.post(room.id, "@mate Mate's own work")
    assert_receive {:agent_started, mate_pid, _, _, _}, 1000

    Coordinator.post(room.id, "@loner Team task")
    assert_receive {:agent_started, pid, _, run, _}, 1000
    ref = Process.monitor(pid)
    GenServer.cast(pid, {:fail, "Usage limit reached"})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)

    # Nobody could take it at failure time and automatic retry is off, so the
    # run simply failed.
    failed = Repo.get!(Run, run.id)
    assert failed.status == "failed"
    assert failed.agent_id == loner.id

    ref2 = Process.monitor(mate_pid)
    GenServer.cast(mate_pid, {:finish, "Own work done"})
    assert_receive {:DOWN, ^ref2, :process, ^mate_pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)

    Coordinator.supervise(DateTime.utc_now(:second))
    assert_receive {:agent_started, _, agent, moved, _}, 1000
    assert agent.id == mate.id
    assert moved.id == run.id
    stop_all(room.id)
  end
end
