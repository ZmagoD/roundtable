defmodule Roundtable.InstructionRefreshTest do
  use Roundtable.DataCase, async: false

  alias Roundtable.Agents.{Claude, Codex}
  alias Roundtable.{Chat, Coordinator}

  setup do
    Application.put_env(:roundtable, :agent_worker, Roundtable.TestWorker)
    Application.put_env(:roundtable, :test_observer, self())
    Application.put_env(:roundtable, :start_agents, true)

    on_exit(fn ->
      Application.put_env(:roundtable, :start_agents, false)
      Application.delete_env(:roundtable, :agent_worker)
      Application.delete_env(:roundtable, :test_observer)
    end)

    {:ok, room} = Chat.create_room(%{name: "Refresh", directory: File.cwd!()})
    %{room: room}
  end

  for {label, adapter, event} <- [
        {"Claude boundary with session", Claude,
         %{"type" => "system", "subtype" => "compact_boundary", "session_id" => "native"}},
        {"Claude boundary without optional metadata", Claude,
         %{"type" => "system", "subtype" => "compact_boundary"}},
        {"Codex completed compaction", Codex,
         %{
           "method" => "item/completed",
           "params" => %{"item" => %{"type" => "contextCompaction", "id" => "compact-1"}}
         }},
        {"Codex legacy notification", Codex,
         %{
           "method" => "thread/compacted",
           "params" => %{"threadId" => "native", "turnId" => "turn-1"}
         }}
      ] do
    @adapter adapter
    @event event
    test "#{label} persists a full refresh for the next turn", %{room: room} do
      {:ok, agent} = Chat.create_agent(room.id, %{name: "ada", provider: @adapter.id()})
      Coordinator.post(room.id, "@ada first")
      assert_receive {:agent_started, pid, _, run, _}, 1000
      state = %{run: run, session: "native"}
      @adapter.handle_event(@event, state)
      @adapter.handle_event(@event, state)
      _ = :sys.get_state(Coordinator)
      assert Chat.agent!(agent.id).instruction_turns == 20
      finish(pid)
      assert Chat.agent!(agent.id).instruction_turns == 20

      Coordinator.post(room.id, "@ada next")
      assert_receive {:agent_started, pid, participant, _, prompt}, 1000
      assert participant.session_id != nil
      assert prompt =~ "WHO YOU ARE AND HOW YOU WORK"
      assert Chat.agent!(agent.id).instruction_turns == 0
      finish(pid)

      Coordinator.post(room.id, "@ada continue")
      assert_receive {:agent_started, _, _, _, prompt}, 1000
      assert prompt =~ "Earlier standing instructions still apply"
      refute prompt =~ "WHO YOU ARE AND HOW YOU WORK"
      Coordinator.stop(agent.id)
    end
  end

  test "every twentieth resumed dispatch refreshes across database reloads", %{room: room} do
    {:ok, agent} = Chat.create_agent(room.id, %{name: "ada", provider: "codex"})

    for turn <- 0..40 do
      Coordinator.post(room.id, "@ada turn #{turn}")
      assert_receive {:agent_started, pid, _, _, prompt}, 1000
      assert prompt =~ "WHO YOU ARE AND HOW YOU WORK" == (rem(turn, 20) == 0)
      assert Chat.agent!(agent.id).instruction_turns == rem(turn, 20)
      finish(pid)
    end
  end

  test "unrelated and started compaction events do not request a refresh", %{room: room} do
    {:ok, agent} = Chat.create_agent(room.id, %{name: "ada", provider: "codex"})
    Coordinator.post(room.id, "@ada first")
    assert_receive {:agent_started, _, _, run, _}, 1000
    state = %{run: run, session: "native"}
    Claude.handle_event(%{"type" => "system", "subtype" => "other"}, state)

    Codex.handle_event(
      %{"method" => "item/started", "params" => %{"item" => %{"type" => "contextCompaction"}}},
      state
    )

    _ = :sys.get_state(Coordinator)
    assert Chat.agent!(agent.id).instruction_turns == 0
    Coordinator.stop(agent.id)
    Coordinator.event(run.id, :compacted)
    _ = :sys.get_state(Coordinator)
    assert Chat.agent!(agent.id).instruction_turns == 0
  end

  defp finish(pid) do
    ref = Process.monitor(pid)
    GenServer.cast(pid, {:finish, "Done"})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)
  end
end
