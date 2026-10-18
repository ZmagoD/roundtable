defmodule RoundtableWeb.RoomActivityTest do
  use RoundtableWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
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

    {:ok, room} = Chat.create_room(%{name: "Activity", directory: File.cwd!()})
    {:ok, agent} = Chat.create_agent(room.id, %{name: "worker", provider: "codex"})
    on_exit(fn -> Coordinator.stop(agent.id) end)
    %{room: room, agent: agent}
  end

  test "open room moves through working, approval, queued, stop, retry and idle", %{
    conn: conn,
    room: room,
    agent: agent
  } do
    {:ok, view, _} = live(conn, "/rooms/#{room.id}")
    assert_activity(view, room, "idle", "Idle")
    Coordinator.post(room.id, "@worker begin")
    assert_receive {:agent_started, _, _, run, _}, 1000
    sync(view)
    assert_activity(view, room, "running", "1 working")

    Coordinator.event(run.id, {:approval, "permission", %{"command" => "pwd"}})
    sync(view)
    assert_activity(view, room, "approval", "1 awaiting approval")
    assert has_element?(view, ".approval-card")

    Coordinator.post(room.id, "@worker next")
    sync(view)
    assert_activity(view, room, "approval", "1 awaiting approval, 1 queued")
    Coordinator.approve(run.id, "permission", "accept")
    sync(view)
    assert_activity(view, room, "running", "1 working, 1 queued")
    Coordinator.stop(agent.id)
    sync(view)
    assert_activity(view, room, "idle", "Idle")

    Coordinator.retry(run.id)
    assert_receive {:agent_started, pid, _, _, _}, 1000
    sync(view)
    assert_activity(view, room, "running", "1 working")
    GenServer.cast(pid, {:finish, "Finished without mentions"})
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    sync(view)
    assert_activity(view, room, "idle", "Idle")
  end

  test "new descendants update an idle parent without leaking messages and disappear on deletion",
       %{
         conn: conn,
         room: room,
         agent: agent
       } do
    {:ok, view, _} = live(conn, "/rooms/#{room.id}")
    {:ok, child} = Chat.create_room(%{name: "Child", directory: File.cwd!()}, parent_id: room.id)

    {:ok, grandchild} =
      Chat.create_room(%{name: "Grandchild", directory: File.cwd!()}, parent_id: child.id)

    {:ok, member} =
      Chat.create_agent(grandchild.id, %{
        name: "nested",
        provider: "codex"
      })

    Coordinator.post(grandchild.id, "@nested private descendant task")
    assert_receive {:agent_started, _, _, _, _}, 1000
    sync(view)
    assert_activity(view, room, "running", "1 working in sub-rooms")
    assert_activity(view, child, "running", "1 working in sub-rooms")
    assert_activity(view, grandchild, "running", "1 working")
    refute has_element?(view, "#messages", "private descendant task")

    Coordinator.post(room.id, "@worker local task")
    assert_receive {:agent_started, _, _, own_run, _}, 1000
    Coordinator.event(own_run.id, {:approval, "local", %{"command" => "pwd"}})
    sync(view)
    assert_activity(view, room, "approval", "1 awaiting approval")
    Coordinator.stop(agent.id)
    Coordinator.stop(member.id)
    Chat.delete_room(child.id)
    sync(view)
    assert_activity(view, room, "idle", "Idle")
    refute has_element?(view, "#room-activity-#{grandchild.id}")
  end

  test "quota waits and mixed states stay explicit while completed history is idle", %{
    conn: conn,
    room: room
  } do
    Application.put_env(:roundtable, :start_agents, false)
    Chat.post(room.id, "@worker queued work")
    [run] = Chat.runs(room.id)
    {:ok, view, _} = live(conn, "/rooms/#{room.id}")
    assert_activity(view, room, "queued", "1 queued")
    Chat.change(run, status: "waiting_quota", retry_at: DateTime.utc_now(:second))
    sync(view)
    assert_activity(view, room, "waiting_quota", "1 waiting for quota")
    Chat.post(room.id, "@worker another task")
    [new | _] = Chat.runs(room.id)
    Chat.change(new, status: "running")
    sync(view)
    assert_activity(view, room, "running", "1 working, 1 waiting for quota")
    Chat.change(new, status: "completed")
    Chat.change(run, status: "completed")
    sync(view)
    assert_activity(view, room, "idle", "Idle")
  end

  test "streamed output does not invalidate sidebar activity", %{room: room} do
    Coordinator.post(room.id, "@worker begin")
    assert_receive {:agent_started, _, _, run, _}, 1000
    Phoenix.PubSub.subscribe(Roundtable.PubSub, "rooms")
    Coordinator.event(run.id, {:output, "a streamed chunk"})
    _ = :sys.get_state(Coordinator)
    refute_receive :room_activity_updated
  end

  defp sync(view) do
    _ = :sys.get_state(Coordinator)
    render(view)
  end

  defp assert_activity(view, room, state, label) do
    assert has_element?(
             view,
             "#room-activity-#{room.id}[data-state='#{state}'][role='status'][aria-label='#{label}'][title='#{label}']"
           )
  end
end
