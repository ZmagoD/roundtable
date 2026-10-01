defmodule Roundtable.CoordinatorTest do
  use Roundtable.DataCase, async: false
  alias Roundtable.{Chat, Coordinator, Repo}
  alias Roundtable.Chat.Run

  setup do
    Application.put_env(:roundtable, :agent_worker, Roundtable.TestWorker)
    Application.put_env(:roundtable, :test_observer, self())
    Application.put_env(:roundtable, :start_agents, true)
    {:ok, room} = Chat.create_room(%{"name" => "Runtime", "directory" => File.cwd!()})

    {:ok, ada} =
      Chat.create_agent(room.id, %{
        "name" => "ada",
        "provider" => "codex",
        "directory" => File.cwd!()
      })

    {:ok, linus} =
      Chat.create_agent(room.id, %{
        "name" => "linus",
        "provider" => "claude",
        "directory" => File.cwd!()
      })

    on_exit(fn ->
      Application.put_env(:roundtable, :start_agents, false)
      Application.delete_env(:roundtable, :agent_worker)
      Application.delete_env(:roundtable, :test_observer)
    end)

    Chat.clear_team_head(room.id)
    %{room: room, ada: ada, linus: linus}
  end

  test "clearing history stops workers, queued turns and approvals and ignores late output",
       ctx do
    Coordinator.post(ctx.room.id, "@ada active work")
    assert_receive {:agent_started, pid, _, run, _}, 1000
    Coordinator.event(run.id, {:session, "old-session"})
    Coordinator.event(run.id, {:approval, "tool", %{"command" => "check"}})
    assert map_size(Coordinator.approvals()) == 1
    Coordinator.post(ctx.room.id, "@ada queued work")
    ref = Process.monitor(pid)
    assert {:ok, :ok} = Coordinator.clear_history(ctx.room.id)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    assert Coordinator.approvals() == %{}
    assert Chat.runs(ctx.room.id) == []
    assert Chat.agent!(ctx.ada.id).session_id == nil
    Coordinator.event(run.id, {:output, "late output"})
    _ = :sys.get_state(Coordinator)
    assert Chat.messages(ctx.room.id) == []
    Coordinator.post(ctx.room.id, "@ada start again")
    assert_receive {:agent_started, _, agent, _, prompt}, 1000
    assert agent.session_id == nil
    refute prompt =~ "active work"
    Coordinator.stop(agent.id)
  end

  test "specialists start fresh while the primary contact keeps its session", ctx do
    Chat.set_team_head(ctx.ada.id)

    for agent <- [ctx.ada, ctx.linus] do
      Chat.change(agent,
        session_id: "existing",
        session_model: agent.model,
        session_directory: agent.directory
      )
    end

    Coordinator.post(ctx.room.id, "@linus Check T1")
    assert_receive {:agent_started, worker_pid, worker, run, _}, 1000
    assert worker.session_id == nil
    ref = Process.monitor(worker_pid)
    GenServer.cast(worker_pid, {:finish, "Checked"})
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)
    assert Repo.get!(Run, run.id).status == "completed"
    Coordinator.post(ctx.room.id, "Summarize progress")
    assert_receive {:agent_started, lead_pid, lead, _, _}, 1000
    assert lead.id == ctx.ada.id
    assert lead.session_id == "existing"
    Coordinator.stop(lead.id)
    ref = Process.monitor(lead_pid)
    assert_receive {:DOWN, ^ref, :process, ^lead_pid, _}, 1000
  end

  test "completed head turns preserve a bounded delegation lineage", ctx do
    Chat.set_team_head(ctx.ada.id)
    {:ok, root} = Coordinator.post(ctx.room.id, "Please implement this")

    for _ <- 1..3 do
      assert_receive {:agent_started, head_pid, head, _, _}, 1000
      assert head.id == ctx.ada.id
      GenServer.cast(head_pid, {:finish, "@linus review"})
      assert_receive {:agent_started, dev_pid, dev, _, _}, 1000
      assert dev.id == ctx.linus.id
      GenServer.cast(dev_pid, {:finish, "@ada needs changes"})
    end

    # The spent allowance falls back to the ordinary count, so this still runs.
    assert_receive {:agent_started, head_pid, _, _, _}, 1000
    GenServer.cast(head_pid, {:finish, "@linus try again"})
    assert_receive {:agent_started, dev_pid, dev, _, _}, 1000
    assert dev.id == ctx.linus.id
    ref = Process.monitor(dev_pid)
    GenServer.cast(dev_pid, {:finish, "done"})
    assert_receive {:DOWN, ^ref, :process, ^dev_pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)
    assert Repo.get!(Roundtable.Chat.Message, root.id).metadata["head_restarts"] == 3

    # "done" hands the work to nobody, so the watchdog wakes the head once more,
    # outside the delegation chain; every turn in the chain itself completed.
    {woken, chain} =
      Enum.split_with(Chat.runs(ctx.room.id), fn run ->
        Repo.get!(Roundtable.Chat.Message, run.message_id).sender == "supervisor"
      end)

    assert [%{agent_id: head_id}] = woken
    assert head_id == ctx.ada.id
    assert Enum.all?(chain, &(&1.status == "completed"))
    Coordinator.stop(ctx.ada.id)
  end

  test "team builder starts, requests approval, and completes through the normal worker" do
    assert {:ok, room} =
             Coordinator.build_team(%{
               name: "New team",
               directory: File.cwd!(),
               provider: "codex",
               context: "Choose a reviewer for this project."
             })

    assert_receive {:agent_started, pid, agent, run, prompt}, 1000
    assert agent.name == "team-builder"
    assert agent.room_id == room.id
    assert prompt =~ "Choose a reviewer for this project."
    assert prompt =~ "assemble a small, useful team"
    Coordinator.event(run.id, {:approval, "setup-tool", %{"command" => "add_participant"}})
    assert map_size(Coordinator.approvals()) == 1
    assert :ok = Coordinator.approve(run.id, "setup-tool", "accept")
    assert_receive {:decision, "setup-tool", "accept"}
    ref = Process.monitor(pid)
    GenServer.cast(pid, {:finish, "Your team is ready."})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)
    assert Repo.get!(Run, run.id).status == "completed"
    assert Enum.any?(Chat.messages(room.id), &(&1.body == "Your team is ready."))
  end

  test "invalid team setup does not start a worker" do
    assert {:error, _} =
             Coordinator.build_team(%{
               name: "New team",
               directory: File.cwd!(),
               provider: "codex",
               context: ""
             })

    refute_receive {:agent_started, _, _, _, _}
  end

  test "serializes a participant's turns while others work in parallel, then delegates", %{
    room: room,
    ada: ada,
    linus: linus
  } do
    Coordinator.post(room.id, "@ada first")
    assert_receive {:agent_started, first, %{id: aid}, first_run, _}, 1000
    assert aid == ada.id
    Coordinator.post(room.id, "@ada second")
    refute_receive {:agent_started, _, _, _, _}, 30
    Coordinator.post(room.id, "@linus review")
    assert_receive {:agent_started, reviewer, %{id: lid}, _, _}, 1000
    assert lid == linus.id
    GenServer.cast(first, {:finish, "Implementation complete"})
    assert_receive {:agent_started, second, %{id: ^aid}, _, prompt}, 1000
    refute prompt =~ "Implementation complete"
    assert prompt =~ "Earlier standing instructions still apply"
    assert Repo.get!(Run, first_run.id).status == "completed"
    assert Chat.agent!(ada.id).session_id == "session-#{ada.id}"
    GenServer.cast(second, {:finish, "@linus please review the finished implementation"})
    GenServer.cast(reviewer, {:finish, "Initial review complete"})
    assert_receive {:agent_started, review2, %{id: ^lid}, _, delegated}, 1000
    assert delegated =~ "please review the finished implementation"
    ref = Process.monitor(review2)
    GenServer.cast(review2, {:finish, "Approved"})
    assert_receive {:DOWN, ^ref, :process, ^review2, :normal}, 1000
    _ = :sys.get_state(Coordinator)
    assert Enum.any?(Chat.messages(room.id), &(&1.body == "Approved"))
  end

  test "approvals route only to the pending run and stop clears the queue", %{
    room: room,
    ada: ada
  } do
    Coordinator.post(room.id, "@ada do work")
    assert_receive {:agent_started, _pid, _, run, _}, 1000
    Coordinator.event(run.id, {:approval, "req-1", %{"command" => "mix test"}})
    assert map_size(Coordinator.approvals()) == 1
    assert {:error, _} = Coordinator.approve(run.id, "wrong", "accept")
    assert :ok = Coordinator.approve(run.id, "req-1", "decline")
    assert_receive {:decision, "req-1", "decline"}
    Coordinator.post(room.id, "@ada queued")
    Coordinator.stop(ada.id)
    assert Enum.all?(Chat.runs(room.id), &(&1.status == "stopped"))
    assert Coordinator.approvals() == %{}
  end

  test "a participant set to approve its own tools is never held", %{room: room, ada: ada} do
    Chat.change(ada, auto_approve: true)
    Coordinator.post(room.id, "@ada do work")
    assert_receive {:agent_started, _pid, _, run, _}, 1000
    Coordinator.event(run.id, {:approval, "req-1", %{"command" => "mix test"}})

    assert_receive {:decision, "req-1", "accept"}, 1000
    assert Coordinator.approvals() == %{}
    # The turn never stopped, so it is still the running one.
    assert Repo.get!(Run, run.id).status == "running"
    Coordinator.stop(ada.id)
  end

  test "retrying takes the model the participant runs on now", %{room: room, ada: ada} do
    Coordinator.post(room.id, "@ada do work")
    assert_receive {:agent_started, pid, _, run, _}, 1000
    ref = Process.monitor(pid)
    GenServer.cast(pid, {:fail, "provider said no"})
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    _ = :sys.get_state(Coordinator)

    Chat.update_agent(ada.id, %{"model" => "a-model-that-works"})
    Coordinator.retry(run.id)

    assert_receive {:agent_started, _pid, %{model: "a-model-that-works"}, _, _}, 1000
    assert Repo.get!(Run, run.id).model == "a-model-that-works"
    Coordinator.stop(ada.id)
  end

  test "retrying keeps a model that was chosen for that turn", %{room: room, ada: ada} do
    {:ok, preset} =
      Chat.create_model_preset(%{
        "name" => "Planner",
        "provider" => "codex",
        "model" => "premium-model",
        "cost_tier" => "premium"
      })

    {:ok, options} = Chat.assignment(ada, to_string(preset.id), "planning")
    Coordinator.post(room.id, "@ada plan", assignment: options)
    assert_receive {:agent_started, pid, _, run, _}, 1000
    ref = Process.monitor(pid)
    GenServer.cast(pid, {:fail, "provider said no"})
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    _ = :sys.get_state(Coordinator)

    Chat.update_agent(ada.id, %{"model" => "something-else"})
    Coordinator.retry(run.id)

    assert_receive {:agent_started, _pid, %{model: "premium-model"}, _, _}, 1000
    Coordinator.stop(ada.id)
  end

  test "reset removes the native session while keeping room history", %{room: room, ada: ada} do
    Chat.change(ada, session_id: "native", session_role: "old brief", last_seen_id: 42)
    Coordinator.post(room.id, "A note without a mention")
    Coordinator.reset(ada.id)
    assert Chat.agent!(ada.id).session_id == nil
    assert Chat.agent!(ada.id).session_role == nil
    assert Chat.agent!(ada.id).last_seen_id == 0
    assert length(Chat.messages(room.id)) == 1
  end

  test "a session remembers the brief it was started under", %{room: room, ada: ada} do
    Chat.change(ada, role: "Review changes, never write them")
    Coordinator.post(room.id, "@ada take a look")
    assert_receive {:agent_started, pid, _, _, prompt}, 1000
    assert prompt =~ "Your role: Review changes, never write them"

    ref = Process.monitor(pid)
    GenServer.cast(pid, {:finish, "Looked."})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)

    assert Chat.agent!(ada.id).session_role == "Review changes, never write them"

    # The next turn on that session says which brief it is replacing.
    Chat.change(Chat.agent!(ada.id), role: "Write the API after all")
    Coordinator.post(room.id, "@ada carry on")
    assert_receive {:agent_started, _pid, _, _, prompt}, 1000
    assert prompt =~ "Earlier standing instructions still apply"
    refute prompt =~ "WHO YOU ARE AND HOW YOU WORK"
    assert prompt =~ "Your role: Write the API after all"
    assert prompt =~ "It used to be: Review changes, never write them"
    Coordinator.stop(ada.id)
  end

  test "a role edited mid-turn is delivered on the next resumed turn", %{room: room, ada: ada} do
    Chat.change(ada, role: "Original role")
    Coordinator.post(room.id, "@ada first")
    assert_receive {:agent_started, pid, _, _, prompt}, 1000
    assert prompt =~ "Your role: Original role"
    Chat.change(Chat.agent!(ada.id), role: "Changed while running")
    ref = Process.monitor(pid)
    GenServer.cast(pid, {:finish, "Done"})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)
    assert Chat.agent!(ada.id).session_role == "Original role"

    Coordinator.post(room.id, "@ada continue")
    assert_receive {:agent_started, _, _, _, prompt}, 1000
    assert prompt =~ "Earlier standing instructions still apply"
    assert prompt =~ "Your role: Changed while running"
    Coordinator.stop(ada.id)
  end

  test "returning to default after a premium assignment does not retain the expensive model", %{
    room: room,
    ada: ada
  } do
    Chat.change(ada, session_id: "old-default-session", session_model: nil, last_seen_id: 0)
    Coordinator.post(room.id, "Keep this history")

    {:ok, preset} =
      Chat.create_model_preset(%{
        "name" => "Planner",
        "provider" => "codex",
        "model" => "premium-model",
        "cost_tier" => "premium"
      })

    {:ok, options} = Chat.assignment(ada, to_string(preset.id), "planning")
    Coordinator.post(room.id, "@ada plan", assignment: options)

    assert_receive {:agent_started, first, %{model: "premium-model", session_id: nil}, _, prompt},
                   1000

    assert prompt =~ "Keep this history"
    ref = Process.monitor(first)
    GenServer.cast(first, {:finish, "Plan ready"})
    assert_receive {:DOWN, ^ref, :process, ^first, :normal}, 1000
    _ = :sys.get_state(Coordinator)
    assert Chat.agent!(ada.id).session_model == "premium-model"
    Coordinator.post(room.id, "@ada routine task")
    assert_receive {:agent_started, second, %{model: nil, session_id: nil}, _, prompt}, 1000
    assert prompt =~ "Keep this history"
    assert prompt =~ "Plan ready"
    assert prompt =~ "WHO YOU ARE AND HOW YOU WORK"
    ref = Process.monitor(second)
    GenServer.cast(second, {:finish, "Done"})
    assert_receive {:DOWN, ^ref, :process, ^second, :normal}, 1000
    _ = :sys.get_state(Coordinator)
    assert Chat.agent!(ada.id).session_model == nil
  end

  test "a turn in a team that inherits works in the project's folder" do
    {:ok, organization} =
      Chat.create_organization(%{"name" => "Checkout", "directory" => File.cwd!()})

    {:ok, room} =
      Chat.create_room(%{"name" => "Engineering", "organization_id" => organization.id})

    {:ok, ada} = Chat.create_agent(room.id, %{"name" => "ada", "provider" => "codex"})

    Coordinator.post(room.id, "@ada take a look")

    assert_receive {:agent_started, _pid, agent, _run, prompt}, 1000
    assert agent.directory == File.cwd!()
    assert prompt =~ "Working directory: #{File.cwd!()}"
    Coordinator.stop(ada.id)
  end

  test "a turn after the project's folder moved starts a fresh session" do
    {:ok, organization} =
      Chat.create_organization(%{"name" => "Checkout", "directory" => File.cwd!()})

    {:ok, room} =
      Chat.create_room(%{"name" => "Engineering", "organization_id" => organization.id})

    {:ok, ada} = Chat.create_agent(room.id, %{"name" => "ada", "provider" => "codex"})

    Coordinator.post(room.id, "@ada do work")
    assert_receive {:agent_started, pid, _, _, _}, 1000
    ref = Process.monitor(pid)
    GenServer.cast(pid, {:finish, "Done"})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)
    assert Chat.agent!(ada.id).session_id
    assert Chat.agent!(ada.id).session_directory == File.cwd!()

    # The room keeps no folder of its own, so the project's edit is where this
    # team works now; a session rooted in the old tree does not resume.
    {:ok, _} = Chat.update_organization(organization.id, %{"directory" => System.tmp_dir!()})
    Coordinator.post(room.id, "@ada again")

    assert_receive {:agent_started, _pid, agent, _, prompt}, 1000
    assert prompt =~ "WHO YOU ARE AND HOW YOU WORK"
    assert agent.session_id == nil
    assert agent.directory == System.tmp_dir!()
    # The old session is gone; a new one records the new folder when it starts.
    assert Chat.agent!(ada.id).session_directory == nil
    Coordinator.stop(ada.id)
  end

  test "a team whose project lost its folder fails its turn with a reason" do
    {:ok, organization} =
      Chat.create_organization(%{"name" => "Checkout", "directory" => File.cwd!()})

    {:ok, room} =
      Chat.create_room(%{"name" => "Engineering", "organization_id" => organization.id})

    {:ok, ada} = Chat.create_agent(room.id, %{"name" => "ada", "provider" => "codex"})

    {:ok, _} = Chat.update_organization(organization.id, %{"directory" => ""})
    {:ok, message} = Coordinator.post(room.id, "@ada take a look")
    _ = :sys.get_state(Coordinator)

    run = Repo.get_by!(Run, message_id: message.id)
    assert run.status == "failed"
    assert run.error =~ "no folder"
    Coordinator.stop(ada.id)
  end

  test "a turn silent for twenty minutes is stopped and left for the watchdog to retry", ctx do
    Coordinator.post(ctx.room.id, "@ada long job")
    assert_receive {:agent_started, pid, _, run, _}, 1000
    ref = Process.monitor(pid)

    # One pass both stops it and, its backoff long past at this clock, restarts it.
    Coordinator.supervise(DateTime.add(Repo.get!(Run, run.id).updated_at, 21 * 60, :second))

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    assert_receive {:agent_started, _, _, restarted, _}, 1000
    assert restarted.id == run.id
    assert Repo.get!(Run, run.id).supervised_retries == 1

    assert Enum.any?(
             Chat.messages(ctx.room.id),
             &(&1.sender == "supervisor" and &1.body =~ "No activity for 20 minutes")
           )

    Coordinator.stop(ctx.ada.id)
  end

  test "stopping an agent whose turn just crashed leaves the watchdog nothing to restart", ctx do
    Coordinator.post(ctx.room.id, "@ada first")
    assert_receive {:agent_started, pid, _, first, _}, 1000
    Coordinator.post(ctx.room.id, "@ada second")
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1000
    _ = :sys.get_state(Coordinator)

    assert %{status: "interrupted"} = Repo.get!(Run, first.id)
    [second] = Enum.filter(Chat.runs(ctx.room.id), &(&1.id != first.id))
    assert second.error == Roundtable.Supervision.held_back()

    Coordinator.stop(ctx.ada.id)

    stopped = Repo.reload!(first)
    assert stopped.status == "stopped"
    assert stopped.error == Roundtable.Supervision.stopped()

    # Held back behind a failure stays separate: a retry there puts it back in
    # the queue, it is not swept up with the turn the human gave up on.
    assert %{status: "stopped"} = Repo.get!(Run, second.id)

    Coordinator.supervise(DateTime.add(DateTime.utc_now(:second), 120, :second))
    _ = :sys.get_state(Coordinator)
    assert %{status: "stopped"} = Repo.get!(Run, first.id)
    refute_receive {:agent_started, _, _, _, _}, 0
    Coordinator.stop(ctx.ada.id)
  end

  test "a crashed turn is restarted ahead of the turn queued behind it", ctx do
    Coordinator.post(ctx.room.id, "@ada first")
    assert_receive {:agent_started, pid, _, first, _}, 1000
    Coordinator.post(ctx.room.id, "@ada second")
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1000
    _ = :sys.get_state(Coordinator)

    assert %{status: "interrupted"} = Repo.get!(Run, first.id)
    [second] = Enum.filter(Chat.runs(ctx.room.id), &(&1.id != first.id))
    assert second.error == Roundtable.Supervision.held_back()

    Coordinator.supervise(DateTime.add(DateTime.utc_now(:second), 120, :second))
    assert_receive {:agent_started, _, _, restarted, _}, 1000
    assert restarted.id == first.id
    assert Repo.get!(Run, second.id).status == "queued"
    Coordinator.stop(ctx.ada.id)
  end

  test "a specialist that finishes without handing on wakes the head", ctx do
    Chat.set_team_head(ctx.linus.id)
    Coordinator.post(ctx.room.id, "@ada build it")
    assert_receive {:agent_started, pid, %{id: ada_id}, _, _}, 1000
    assert ada_id == ctx.ada.id

    GenServer.cast(pid, {:finish, "Built it in abc123.\nTests pass."})
    assert_receive {:agent_started, _, head, _, prompt}, 1000
    assert head.id == ctx.linus.id
    assert prompt =~ "ada finished without handing the work on"
    assert prompt =~ "Built it in abc123."
    Coordinator.stop(ctx.linus.id)
  end

  test "a specialist that hands the work on does not wake the head as well", ctx do
    Chat.set_team_head(ctx.linus.id)
    Coordinator.post(ctx.room.id, "@ada build it")
    assert_receive {:agent_started, pid, _, _, _}, 1000

    GenServer.cast(pid, {:finish, "@linus done"})
    assert_receive {:agent_started, _, head, _, prompt}, 1000
    assert head.id == ctx.linus.id
    refute prompt =~ "finished without handing the work on"
    Coordinator.stop(ctx.linus.id)
  end
end
