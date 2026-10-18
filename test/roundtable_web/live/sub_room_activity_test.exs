defmodule RoundtableWeb.SubRoomActivityTest do
  @moduledoc """
  A participant whose copy is working in a sub-room is not idle from the
  parent's point of view: its card says so and links to where the work is.
  """
  use RoundtableWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Roundtable.{Chat, Repo}
  alias Roundtable.Chat.Run

  setup do
    {:ok, root} = Chat.create_room(%{"name" => "Engineering", "directory" => File.cwd!()})
    {:ok, ada} = Chat.create_agent(root.id, %{"name" => "ada", "provider" => "claude"})
    %{root: root, ada: ada}
  end

  defp sub_room(parent, name) do
    {:ok, room} =
      Chat.create_room(%{"name" => name, "directory" => File.cwd!()}, parent_id: parent.id)

    room
  end

  defp agent(room, name) do
    {:ok, agent} = Chat.create_agent(room.id, %{"name" => name, "provider" => "claude"})
    agent
  end

  defp turn(agent, status) do
    {:ok, message} = Chat.post(agent.room_id, "work", kind: "agent", sender: agent.name)
    Repo.insert!(%Run{agent_id: agent.id, message_id: message.id, status: status})
  end

  test "a copy working in a sub-room at any depth shows on the card, with a link",
       %{conn: conn, root: root, ada: ada} do
    task = root |> sub_room("Task") |> sub_room("Deep task")
    task |> agent("ada") |> turn("running")

    {:ok, view, _} = live(conn, "/rooms/#{root.id}")

    assert has_element?(view, "#agent-#{ada.id} .status-dot.running")
    assert has_element?(view, "#agent-#{ada.id} .status.running", "running")

    assert has_element?(
             view,
             "#busy-elsewhere-#{ada.id}-#{task.id} a[href='/rooms/#{task.id}']",
             "Deep task"
           )

    assert view |> element("#busy-elsewhere-#{ada.id}-#{task.id}") |> render() =~ "Running in"
  end

  for {status, label} <- [{"queued", "Queued in"}, {"waiting_quota", "Waiting for quota in"}] do
    test "a copy that is #{status} in a sub-room shows as #{status}",
         %{conn: conn, root: root, ada: ada} do
      task = sub_room(root, "Task")
      task |> agent("ada") |> turn(unquote(status))

      {:ok, view, _} = live(conn, "/rooms/#{root.id}")

      assert has_element?(view, "#agent-#{ada.id} .status-dot.#{unquote(status)}")
      assert has_element?(view, "#agent-#{ada.id} .status.#{unquote(status)}")

      assert view |> element("#busy-elsewhere-#{ada.id}-#{task.id}") |> render() =~
               unquote(label)

      assert has_element?(
               view,
               "#busy-elsewhere-#{ada.id}-#{task.id} a[href='/rooms/#{task.id}']",
               "Task"
             )
    end
  end

  test "copies busy in several sub-rooms each get their own link",
       %{conn: conn, root: root, ada: ada} do
    first = sub_room(root, "First task")
    second = sub_room(root, "Second task")
    first_ada = agent(first, "ada")
    turn(first_ada, "running")
    second |> agent("ada") |> turn("waiting_quota")
    # Two turns in one room are still one room to go and look at.
    turn(first_ada, "queued")

    {:ok, view, _} = live(conn, "/rooms/#{root.id}")

    assert has_element?(
             view,
             "#busy-elsewhere-#{ada.id}-#{first.id} a[href='/rooms/#{first.id}']",
             "First task"
           )

    assert has_element?(
             view,
             "#busy-elsewhere-#{ada.id}-#{second.id} a[href='/rooms/#{second.id}']",
             "Second task"
           )

    assert view |> element("#busy-elsewhere-#{ada.id}-#{second.id}") |> render() =~
             "Waiting for quota in"

    assert length(Regex.scan(~r/id="busy-elsewhere-#{ada.id}-/, render(view))) == 2
  end

  test "the card follows a copy that starts and finishes after the page opened",
       %{conn: conn, root: root, ada: ada} do
    {:ok, view, _} = live(conn, "/rooms/#{root.id}")
    assert has_element?(view, "#agent-#{ada.id} .status.idle")

    # Made after the page opened, so the page has to start listening to it.
    task = sub_room(root, "Task")
    run = task |> agent("ada") |> turn("approval")
    Chat.broadcast(task.id)

    assert has_element?(view, "#agent-#{ada.id} .status.approval")
    assert has_element?(view, "#busy-elsewhere-#{ada.id}-#{task.id}", "Approval in")

    run |> Ecto.Changeset.change(status: "done") |> Repo.update!()
    Chat.broadcast(task.id)

    assert has_element?(view, "#agent-#{ada.id} .status.idle")
    refute has_element?(view, "#busy-elsewhere-#{ada.id}-#{task.id}")
  end

  test "work in the room itself is shown first, and the link stays",
       %{conn: conn, root: root, ada: ada} do
    turn(ada, "approval")
    task = sub_room(root, "Task")
    task |> agent("ada") |> turn("running")

    {:ok, view, _} = live(conn, "/rooms/#{root.id}")

    assert has_element?(view, "#agent-#{ada.id} .status.approval")
    assert has_element?(view, "#busy-elsewhere-#{ada.id}-#{task.id}")
  end

  test "only a copy of the same name in a room below counts",
       %{conn: conn, root: root, ada: ada} do
    task = sub_room(root, "Task")
    task |> agent("grace") |> turn("running")
    sibling = sub_room(root, "Sibling")
    sibling_ada = agent(sibling, "ada")
    turn(ada, "running")
    {:ok, other} = Chat.create_room(%{"name" => "Elsewhere", "directory" => File.cwd!()})
    other |> agent("ada") |> turn("running")

    {:ok, top, _} = live(conn, "/rooms/#{root.id}")
    assert has_element?(top, "#agent-#{ada.id} .status.running")
    refute has_element?(top, "[id^='busy-elsewhere-#{ada.id}-']")

    # The parent's own turn is not the sub-room copy's: up and sideways do not count.
    {:ok, view, _} = live(conn, "/rooms/#{sibling.id}")
    assert has_element?(view, "#agent-#{sibling_ada.id} .status.idle")
    refute has_element?(view, "[id^='busy-elsewhere-']")
  end

  test "a sub-room's conversation stays out of the parent's",
       %{conn: conn, root: root} do
    task = sub_room(root, "Task")
    {:ok, view, _} = live(conn, "/rooms/#{root.id}")

    {:ok, _} = Chat.post(task.id, "said only in the task room", kind: "human", sender: "you")
    Chat.broadcast(task.id)

    refute render(view) =~ "said only in the task room"
  end
end
