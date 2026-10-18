defmodule RoundtableWeb.RunActivityTest do
  @moduledoc """
  A turn inside one long command emits no text. The room still says what it is
  doing and what is queued behind it, so a busy participant does not look stuck.
  """
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

    {:ok, room} = Chat.create_room(%{"name" => "Engineering", "directory" => File.cwd!()})
    {:ok, _} = Chat.create_agent(room.id, %{"name" => "ada", "provider" => "claude"})
    %{room: room}
  end

  test "a running turn shows its step, its age and the messages waiting behind it",
       %{conn: conn, room: room} do
    Coordinator.post(room.id, "@ada task")
    assert_receive {:agent_started, _, _, run, _}, 1000
    {:ok, view, _} = live(conn, "/rooms/#{room.id}")

    assert render(view |> element("#run-activity-#{run.id}")) =~
             "Turn running for under a minute"

    Coordinator.event(run.id, {:activity, "Running a shell command: Run the test suite"})
    Coordinator.post(room.id, "@ada are you ok")
    _ = :sys.get_state(Coordinator)

    line = render(view |> element("#run-activity-#{run.id}"))
    assert line =~ "Running a shell command: Run the test suite · under a minute"
    assert line =~ "1 message waiting; ada reads them when this turn ends"
  end

  test "a queued turn shows no activity line", %{conn: conn, room: room} do
    Coordinator.post(room.id, "@ada task")
    assert_receive {:agent_started, _, _, _run, _}, 1000
    Coordinator.post(room.id, "@ada next")
    _ = :sys.get_state(Coordinator)

    {:ok, view, _} = live(conn, "/rooms/#{room.id}")
    [_running, queued] = room.id |> Chat.runs() |> Enum.sort_by(& &1.id)
    assert queued.status == "queued"
    refute has_element?(view, "#run-activity-#{queued.id}")
  end
end
