defmodule Roundtable.RemovalTest do
  @moduledoc """
  Removing a participant or a room.

  The question worth testing is not that the row goes, but what survives it:
  a room's history is a record of what happened, and removing someone who
  spoke should not rewrite it into a conversation with fewer people in it.
  """
  use Roundtable.DataCase, async: false

  alias Roundtable.{Chat, Coordinator, Repo}
  alias Roundtable.Chat.{Agent, CrossRoomRequest, Message, Room, Run}

  setup do
    {:ok, room} = Chat.create_room(%{"name" => "Checkout", "directory" => File.cwd!()})
    {:ok, ada} = Chat.create_agent(room.id, %{"name" => "ada", "provider" => "codex"})
    {:ok, linus} = Chat.create_agent(room.id, %{"name" => "linus", "provider" => "claude"})
    %{room: room, ada: ada, linus: linus}
  end

  test "removing a participant keeps what it said", %{room: room, ada: ada} do
    {:ok, _} = Chat.post(room.id, "a question from the human")

    {:ok, _} =
      Chat.post(room.id, "ada's answer, still worth reading",
        sender: "ada",
        agent_id: ada.id,
        kind: "agent"
      )

    assert {:ok, _} = Coordinator.remove_agent(ada.id)

    assert Repo.get(Agent, ada.id) == nil
    bodies = Chat.messages(room.id) |> Enum.map(& &1.body)
    assert "ada's answer, still worth reading" in bodies

    # Attribution survives as the sender name; only the link is gone.
    said = Enum.find(Chat.messages(room.id), &(&1.body =~ "ada's answer"))
    assert said.sender == "ada"
    assert said.agent_id == nil
  end

  test "its runs go with it, and nobody else's do", %{room: room, ada: ada, linus: linus} do
    {:ok, _} = Chat.post(room.id, "@ada and @linus both")
    assert length(Chat.runs(room.id)) == 2

    {:ok, _} = Coordinator.remove_agent(ada.id)

    assert [%Run{agent_id: remaining}] = Chat.runs(room.id)
    assert remaining == linus.id
  end

  test "a queued turn for the removed participant stops first", %{room: room, ada: ada} do
    {:ok, _} = Chat.post(room.id, "@ada work on this")
    assert [%Run{status: status}] = Chat.runs(room.id)
    assert status in ["queued", "running"]

    assert {:ok, _} = Coordinator.remove_agent(ada.id)
    assert Chat.runs(room.id) == []
  end

  test "the room carries on without it", %{room: room, ada: ada, linus: linus} do
    {:ok, _} = Coordinator.remove_agent(ada.id)

    assert [%Agent{id: id}] = Chat.agents(room.id)
    assert id == linus.id

    # The name is free again, and a mention reaches the newcomer.
    {:ok, replacement} = Chat.create_agent(room.id, %{"name" => "ada", "provider" => "claude"})
    {:ok, message} = Chat.post(room.id, "@ada are you the new one?")

    assert [%Run{agent_id: agent_id}] =
             Repo.all(from r in Run, where: r.message_id == ^message.id)

    assert agent_id == replacement.id
  end

  test "removing a room takes its participants and history with it", %{room: room} do
    {:ok, _} = Chat.post(room.id, "@ada something")

    assert {:ok, _} = Coordinator.remove_room(room.id)

    assert Repo.get(Room, room.id) == nil
    assert Repo.aggregate(Agent, :count) == 0
    assert Repo.aggregate(Message, :count) == 0
    assert Repo.aggregate(Run, :count) == 0
    assert Chat.rooms() == []
  end

  test "removing a room takes cross-room requests either side of it", %{room: room} do
    {:ok, design} = Chat.create_room(%{"name" => "Design", "directory" => File.cwd!()})
    {:ok, _} = Chat.create_agent(design.id, %{"name" => "grace", "provider" => "opencode"})

    {:ok, _} = Chat.request_from_room("ask", room.id, "design/grace", "how wide?")
    assert Repo.aggregate(CrossRoomRequest, :count) == 1

    {:ok, _} = Coordinator.remove_room(design.id)

    assert Repo.aggregate(CrossRoomRequest, :count) == 0
    # The asking room survives, with the record of having asked.
    assert Repo.get(Room, room.id)
    assert Enum.any?(Chat.messages(room.id), &(&1.body =~ "Asked @design/grace"))
  end

  test "other rooms are untouched", %{room: room} do
    {:ok, other} = Chat.create_room(%{"name" => "Infra", "directory" => File.cwd!()})
    {:ok, _} = Chat.create_agent(other.id, %{"name" => "grace", "provider" => "opencode"})
    {:ok, _} = Chat.post(other.id, "still here")

    {:ok, _} = Coordinator.remove_room(room.id)

    assert Repo.get(Room, other.id)
    assert length(Chat.agents(other.id)) == 1
    assert length(Chat.messages(other.id)) == 1
  end

  test "removing something that is already gone raises rather than lying", %{ada: ada} do
    {:ok, _} = Coordinator.remove_agent(ada.id)
    assert catch_exit(Coordinator.remove_agent(ada.id))
  end
end
