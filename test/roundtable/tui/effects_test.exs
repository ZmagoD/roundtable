defmodule Roundtable.TUI.EffectsTest do
  @moduledoc """
  The client's effects: everything a keystroke asks the service to do.

  These run against a real in-process client, so the effect, the context and
  the database all behave as they do in a live session. Only drawing is absent,
  which is the one part that needs a terminal.
  """
  use Roundtable.DataCase, async: false

  alias Roundtable.{Chat, Client, Repo, TUI}
  alias Roundtable.Chat.Run
  alias Roundtable.TUI.State

  setup do
    {:ok, room} = Chat.create_room(%{"name" => "Effects", "directory" => File.cwd!()})

    {:ok, agent} =
      Chat.create_agent(room.id, %{
        "name" => "ada",
        "provider" => "codex",
        "directory" => File.cwd!()
      })

    context = %{
      client: Client.local(),
      state: State.new(room: room, agents: [agent], target: "in-process"),
      relay: nil,
      room_id: room.id,
      buffer: "",
      polling: false,
      ticks: 0
    }

    %{room: room, agent: agent, context: context}
  end

  test "posting a message reaches the room", %{context: context, room: room} do
    context = TUI.perform({:post, "@ada look at this"}, context)

    assert [%{body: "@ada look at this"}] = Chat.messages(room.id)
    assert [%{status: "queued"}] = Chat.runs(room.id)
    assert Enum.any?(context.state.messages, &(&1.body =~ "look at this"))
  end

  test "posting without a room says so instead of crashing", %{context: context} do
    context = %{context | state: %{context.state | room: nil}}
    context = TUI.perform({:post, "nobody is listening"}, context)

    assert context.state.status =~ "Create a room first"
  end

  test "an invalid post surfaces the reason", %{context: context} do
    context = TUI.perform({:post, "   "}, context)
    assert context.state.status =~ "Write a message"
  end

  test "creating a room switches to it", %{context: context} do
    directory = Path.join(System.tmp_dir!(), "rt-effects-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    context = TUI.perform({:create_room, "Second", directory}, context)

    assert context.state.room.name == "Second"
    assert context.state.status =~ "Second"
  end

  test "a relative directory resolves against the client's own shell", %{context: context} do
    # "." is where the person started the client, not where the service lives.
    context = TUI.perform({:create_room, "Here", "."}, context)

    assert context.state.room.directory == File.cwd!()
  end

  test "an agent's directory is resolved the same way", %{context: context} do
    attrs = %{"name" => "grace", "provider" => "opencode", "directory" => "."}
    context = TUI.perform({:create_agent, attrs}, context)

    assert context.state.status =~ "@grace joined"
    grace = Chat.agents(context.state.room.id) |> Enum.find(&(&1.name == "grace"))
    assert grace.directory == File.cwd!()
  end

  test "a room on a directory that does not exist reports the changeset", %{context: context} do
    context = TUI.perform({:create_room, "Nowhere", "/does/not/exist"}, context)

    assert context.state.status =~ "directory"
    assert length(Chat.rooms()) == 1
  end

  test "creating an agent defaults its directory to the room's", %{context: context, room: room} do
    context =
      TUI.perform({:create_agent, %{"name" => "grace", "provider" => "opencode"}}, context)

    assert context.state.status =~ "@grace joined"
    grace = Chat.agents(room.id) |> Enum.find(&(&1.name == "grace"))
    assert grace.directory == room.directory
  end

  test "creating an agent without a room says so", %{context: context} do
    context = %{context | state: %{context.state | room: nil}}

    context =
      TUI.perform({:create_agent, %{"name" => "grace", "provider" => "opencode"}}, context)

    assert context.state.status =~ "Create a room first"
  end

  test "a duplicate agent name is reported against the name", %{context: context} do
    context = TUI.perform({:create_agent, %{"name" => "ada", "provider" => "codex"}}, context)
    assert context.state.status =~ "name: is already used in this room"
  end

  test "updating an agent's role and model", %{context: context, agent: agent} do
    context = TUI.perform({:update_agent, agent.id, %{"role" => "plan only"}}, context)
    assert context.state.status =~ "@ada updated"
    assert Chat.agent!(agent.id).role == "plan only"

    TUI.perform({:update_agent, agent.id, %{"model" => "o3"}}, context)
    assert Chat.agent!(agent.id).model == "o3"
  end

  test "renaming a participant, and refusing a name already in use", %{
    context: context,
    agent: agent,
    room: room
  } do
    context = TUI.perform({:update_agent, agent.id, %{"name" => "ada-2"}}, context)
    assert context.state.status =~ "@ada-2 updated"
    assert Chat.agent!(agent.id).name == "ada-2"

    {:ok, other} =
      Chat.create_agent(room.id, %{
        "name" => "grace",
        "provider" => "opencode",
        "directory" => File.cwd!()
      })

    context = TUI.perform({:update_agent, other.id, %{"name" => "ada-2"}}, context)
    assert context.state.status =~ "already used in this room"
    assert Chat.agent!(other.id).name == "grace"
  end

  test "an invalid name is refused", %{context: context, agent: agent} do
    context = TUI.perform({:update_agent, agent.id, %{"name" => "Not Valid"}}, context)

    assert context.state.status =~ "name"
    assert Chat.agent!(agent.id).name == "ada"
  end

  test "stop, reset and retry reach the coordinator", %{
    context: context,
    room: room,
    agent: agent
  } do
    {:ok, message} = Chat.post(room.id, "@ada work")
    run = Repo.get_by!(Run, message_id: message.id)

    context = TUI.perform({:stop, agent.id}, context)
    assert context.state.status =~ "stop sent"
    assert Repo.get!(Run, run.id).status == "stopped"

    context = TUI.perform({:retry, run.id}, context)
    assert context.state.status =~ "retry sent"
    assert Repo.get!(Run, run.id).status in ["queued", "running"]

    context = TUI.perform({:reset, agent.id}, context)
    assert context.state.status =~ "reset sent"
    assert Chat.agent!(agent.id).session_id == nil
  end

  test "an approval that is no longer pending is reported", %{context: context} do
    context = TUI.perform({:approve, -1, "missing", "accept"}, context)
    assert context.state.status =~ "no longer pending"
  end

  test "switching rooms changes what is refreshed", %{context: context, room: room} do
    {:ok, other} = Chat.create_room(%{"name" => "Other", "directory" => File.cwd!()})
    {:ok, _} = Chat.post(other.id, "only in the other room")

    context = TUI.perform({:switch_room, other.id}, context)

    assert context.room_id == other.id
    assert context.state.room.id == other.id
    assert Enum.any?(context.state.messages, &(&1.body == "only in the other room"))
    refute context.state.room.id == room.id
  end

  test "a cross-room request is sent and reported", %{context: context, room: room} do
    {:ok, design} = Chat.create_room(%{"name" => "Design Team", "directory" => File.cwd!()})

    {:ok, _} =
      Chat.create_agent(design.id, %{
        "name" => "grace",
        "provider" => "opencode",
        "directory" => File.cwd!()
      })

    context = TUI.perform({:cross_room, "ask", "design-team/grace", "what spacing?"}, context)

    assert context.state.status =~ "Sent to design-team/grace"
    assert Enum.any?(Chat.messages(room.id), &(&1.body =~ "Asked @design-team/grace"))
    assert Enum.any?(Chat.messages(design.id), &(&1.body =~ "what spacing?"))
  end

  test "an unresolvable cross-room target is reported, not sent", %{context: context} do
    context = TUI.perform({:cross_room, "ask", "ghost/grace", "hello"}, context)
    assert context.state.status =~ "No room called ghost"
  end

  test "a cross-room request without a room says so", %{context: context} do
    context = %{context | state: %{context.state | room: nil}}
    context = TUI.perform({:cross_room, "ask", "design-team/grace", "hi"}, context)

    assert context.state.status =~ "Open a room first"
  end

  test "asking for the git UI without the launcher explains how to get it", %{context: context} do
    System.delete_env("ROUNDTABLE_TUI_HANDOFF")
    context = TUI.perform(:git_ui, context)

    assert context.state.status =~ "bin/roundtable tui"
    assert context.state.handoff == nil
  end

  test "with the launcher present, the git UI request becomes a handoff", %{context: context} do
    System.put_env("ROUNDTABLE_TUI_HANDOFF", "/tmp/rt-handoff-test")
    System.put_env("ROUNDTABLE_GIT_UI", "tig")
    on_exit(fn -> System.delete_env("ROUNDTABLE_TUI_HANDOFF") end)
    on_exit(fn -> System.delete_env("ROUNDTABLE_GIT_UI") end)

    context = TUI.perform(:git_ui, context)

    assert context.state.quit
    assert context.state.handoff.command == "tig"
    assert context.state.handoff.path == "/tmp/rt-handoff-test"
    assert context.state.handoff.directory == context.state.room.directory
  end

  test "quit and refresh are handled", %{context: context} do
    assert TUI.perform(:quit, context) == context
    assert TUI.perform(:refresh, context).state.room.id == context.state.room.id
  end

  test "an unknown effect is ignored rather than crashing", %{context: context} do
    assert TUI.perform(:something_new, context) == context
  end

  test "run refuses to start without a terminal" do
    assert TUI.run(Client.local()) == {:error, :no_terminal}
  end
end
