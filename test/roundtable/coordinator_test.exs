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

    %{room: room, ada: ada, linus: linus}
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
    assert prompt =~ "Implementation complete"
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
    Chat.change(ada, session_id: "native", last_seen_id: 42)
    Coordinator.post(room.id, "A note without a mention")
    Coordinator.reset(ada.id)
    assert Chat.agent!(ada.id).session_id == nil
    assert Chat.agent!(ada.id).last_seen_id == 0
    assert length(Chat.messages(room.id)) == 1
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
    ref = Process.monitor(second)
    GenServer.cast(second, {:finish, "Done"})
    assert_receive {:DOWN, ^ref, :process, ^second, :normal}, 1000
    _ = :sys.get_state(Coordinator)
    assert Chat.agent!(ada.id).session_model == nil
  end
end
