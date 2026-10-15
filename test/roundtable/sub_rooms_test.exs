defmodule Roundtable.SubRoomsTest do
  @moduledoc """
  A room an agent spins off belongs to the room it was spun off from.

  Deleting the parent takes the whole subtree in one step, but never while a
  room in it still holds task work that has not been pushed: that would lose
  code without anyone being told.
  """
  use RoundtableWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Roundtable.{Chat, Coordinator, MCP, Repo}
  alias Roundtable.Chat.{Agent, Message, Room, Run}

  setup do
    Application.put_env(:roundtable, :mcp_url, "http://127.0.0.1:4002/mcp")
    on_exit(fn -> Application.delete_env(:roundtable, :mcp_url) end)

    {:ok, root} = Chat.create_room(%{"name" => "Engineering", "directory" => File.cwd!()})
    %{root: root}
  end

  defp sub_room(parent, name) do
    {:ok, room} =
      Chat.create_room(%{"name" => name, "directory" => File.cwd!()}, parent_id: parent.id)

    room
  end

  # A checkout is a real git clone; the refusal only reads these two fields, so
  # they are set directly rather than cloning a repository for each test.
  defp open_task(room) do
    room |> Ecto.Changeset.change(checkout_id: "task-#{room.id}") |> Repo.update!()
  end

  defp running_turn(agent) do
    {:ok, message} = Chat.post(agent.room_id, "work", kind: "agent", sender: agent.name)
    Repo.insert!(%Run{agent_id: agent.id, message_id: message.id, status: "running"})
  end

  describe "making a sub-room" do
    test "a room an agent creates belongs to the agent's room", %{root: root} do
      {:ok, ada} = Chat.create_agent(root.id, %{"name" => "ada", "provider" => "claude"})
      {:ok, message} = Chat.post(root.id, "work", kind: "agent", sender: "ada")
      Repo.insert!(%Run{agent_id: ada.id, message_id: message.id, status: "running"})

      assert {:ok, _} = MCP.call(ada, "create_room", %{"name" => "Docs"})
      assert Chat.find_room("Docs").parent_id == root.id
    end

    test "a room made without a parent stays top-level" do
      {:ok, room} = Chat.create_room(%{"name" => "Solo", "directory" => File.cwd!()})
      assert room.parent_id == nil
    end

    test "a form cannot reparent a room", %{root: root} do
      other = sub_room(root, "Child")
      {:ok, updated} = Chat.update_room(root.id, %{"parent_id" => other.id})
      assert updated.parent_id == nil
    end
  end

  describe "deleting a room with sub-rooms" do
    test "takes children, grandchildren and their participants and turns", %{root: root} do
      child = sub_room(root, "Child")
      grandchild = sub_room(child, "Grandchild")
      {:ok, outsider} = Chat.create_room(%{"name" => "Outside", "directory" => File.cwd!()})

      {:ok, deep} = Chat.create_agent(grandchild.id, %{"name" => "deep", "provider" => "codex"})
      {:ok, _} = Chat.create_agent(outsider.id, %{"name" => "kept", "provider" => "codex"})
      running_turn(deep)

      assert {:ok, %Room{id: id}} = Coordinator.remove_room(root.id)
      assert id == root.id

      for room <- [root, child, grandchild], do: refute(Repo.get(Room, room.id))
      assert Enum.map(Repo.all(Agent), & &1.name) == ["kept"]
      assert Repo.aggregate(Run, :count) == 0
      assert Repo.all(Message) |> Enum.all?(&(&1.room_id == outsider.id))
      assert Repo.get(Room, outsider.id)
    end

    test "deleting a sub-room leaves its parent", %{root: root} do
      child = sub_room(root, "Child")
      assert {:ok, _} = Chat.delete_room(child.id)
      assert Repo.get(Room, root.id)
    end

    test "is refused while a descendant has unpushed task work", %{root: root} do
      child = sub_room(root, "Child")
      grandchild = root |> sub_room("Other") |> sub_room("Deep task") |> open_task()
      {:ok, ada} = Chat.create_agent(child.id, %{"name" => "ada", "provider" => "claude"})
      run = running_turn(ada)

      assert {:error, changeset} = Coordinator.remove_room(root.id)

      assert [directory: {"finish the tasks in Deep task before deleting this room", []}] =
               changeset.errors

      assert Repo.aggregate(Room, :count) == 4
      assert Repo.get(Agent, ada.id)
      assert Repo.get!(Run, run.id).status == "running"
      assert Repo.get(Room, grandchild.id)
    end

    test "names the room itself as well when it is a task too", %{root: root} do
      root |> sub_room("Child task") |> open_task()
      open_task(root)

      assert {:error, changeset} = Chat.delete_room(root.id)

      assert [
               directory:
                 {"finish this task and the tasks in Child task before deleting this room", []}
             ] =
               changeset.errors
    end

    test "goes ahead once the task is finished", %{root: root} do
      task = root |> sub_room("Task") |> open_task()
      task |> Ecto.Changeset.change(checkout_finished: true) |> Repo.update!()

      assert {:ok, _} = Chat.delete_room(root.id)
      assert Repo.aggregate(Room, :count) == 0
    end
  end

  describe "linking the task rooms made before sub-rooms" do
    # Migrations are not compiled with the app, so the module is only known
    # once its file is loaded, and the compiler must not be asked about it.
    defp backfill! do
      migration = Module.concat(Roundtable.Repo.Migrations, "GiveRoomsAParent")

      Code.ensure_loaded?(migration) ||
        Code.require_file("priv/repo/migrations/20261015200000_give_rooms_a_parent.exs")

      Repo.query!(migration.backfill())
    end

    # The migration has already run by the time the suite starts, so the test
    # runs its statement again over rooms seeded the way the old code made them.
    test "a task room joins its supervisor's room", %{root: root} do
      {:ok, driver} = Chat.create_agent(root.id, %{"name" => "driver", "provider" => "claude"})

      {:ok, task} =
        Chat.create_room(%{"name" => "Task", "directory" => File.cwd!()},
          supervisor_id: driver.id
        )

      {:ok, own} =
        Chat.create_room(%{"name" => "Own", "directory" => File.cwd!()}, supervisor_id: driver.id)

      Repo.update_all(Room, set: [parent_id: nil])
      Repo.update_all(from(r in Room, where: r.id == ^own.id), set: [checkout_supervisor_id: nil])
      {:ok, solo} = Chat.create_room(%{"name" => "Solo", "directory" => File.cwd!()})

      backfill!()

      assert Repo.get!(Room, task.id).parent_id == root.id
      assert Repo.get!(Room, own.id).parent_id == nil
      assert Repo.get!(Room, solo.id).parent_id == nil
      assert Repo.get!(Room, root.id).parent_id == nil
    end

    test "a supervisor's own room is not made its own parent", %{root: root} do
      {:ok, driver} = Chat.create_agent(root.id, %{"name" => "driver", "provider" => "claude"})
      root |> Ecto.Changeset.change(checkout_supervisor_id: driver.id) |> Repo.update!()

      backfill!()

      assert Repo.get!(Room, root.id).parent_id == nil
    end
  end

  describe "the room list" do
    test "nests sub-rooms under their parent and links back", %{conn: conn, root: root} do
      child = sub_room(root, "Child")
      grandchild = sub_room(child, "Grandchild")

      {:ok, view, _} = live(conn, "/rooms/#{grandchild.id}")

      assert has_element?(
               view,
               "nav[aria-label='Rooms'] > ul > li > ul.sub-rooms > li > ul.sub-rooms a[href='/rooms/#{grandchild.id}']",
               "Grandchild"
             )

      assert has_element?(view, "#sub-room-of a[href='/rooms/#{child.id}']", "Child")

      {:ok, top, _} = live(conn, "/rooms/#{root.id}")
      refute has_element?(top, "#sub-room-of")

      assert top |> element("#remove-room-button") |> render() =~
               "Delete Engineering and its 2 sub-rooms?"

      {:ok, middle, _} = live(conn, "/rooms/#{child.id}")

      assert middle |> element("#remove-room-button") |> render() =~
               "Delete Child and its sub-room?"

      {:ok, leaf, _} = live(conn, "/rooms/#{grandchild.id}")
      assert leaf |> element("#remove-room-button") |> render() =~ "Delete Grandchild?"
    end

    test "a refused delete says which rooms to finish", %{conn: conn, root: root} do
      root |> sub_room("Open task") |> open_task()
      {:ok, view, _} = live(conn, "/rooms/#{root.id}")

      view |> element("#remove-room-button") |> render_click()

      assert render(view) =~
               "Engineering was not deleted: finish the tasks in Open task before deleting this room."
    end
  end
end
