defmodule Roundtable.ProposalsTest do
  @moduledoc """
  What a participant asked the human to do, and what the human's answer does.

  Accepting has to do what the browser's own controls do, and nothing the card
  did not show: approval stays off, the participant asked for is the one added.
  An answer is final, and one that cannot be carried out is said rather than
  half-done.
  """
  use Roundtable.DataCase, async: false

  alias Roundtable.{Chat, Proposals}

  setup do
    {:ok, room} = Chat.create_room(%{"name" => "Checkout", "directory" => File.cwd!()})
    {:ok, ada} = Chat.create_agent(room.id, %{"name" => "ada", "provider" => "claude"})
    Chat.subscribe(room.id)
    %{room: room, ada: ada}
  end

  defp propose(room, action, params) do
    {:ok, message} = Chat.propose(room.id, "ada", action, Map.put(params, "room_id", room.id))
    message
  end

  test "accepting adds the participant with approval off, from scratch or a profile", %{
    room: room
  } do
    scratch =
      propose(room, "add_participant", %{
        "attrs" => %{"name" => "otto", "provider" => "opencode", "role" => "tests"}
      })

    {:ok, profile} =
      Chat.create_agent_profile(%{
        "name" => "vee",
        "provider" => "vibe",
        "auto_approve" => true
      })

    from_profile =
      propose(room, "add_participant", %{"profile_id" => profile.id, "name" => "vee-two"})

    assert {:ok, accepted} = Proposals.accept(scratch.id)
    assert accepted.metadata["status"] == "accepted"
    assert accepted.metadata["note"] =~ "otto joined"
    assert_receive {:message_updated, %{id: id}} when id == scratch.id

    assert {:ok, _} = Proposals.accept(from_profile.id)

    added = Map.new(Chat.agents(room.id), &{&1.name, &1})
    assert added["otto"].provider == "opencode"
    assert added["otto"].role == "tests"
    assert added["vee-two"].provider == "vibe"
    refute added["otto"].auto_approve
    refute added["vee-two"].auto_approve
  end

  test "an answered proposal cannot be answered again", %{room: room} do
    message =
      propose(room, "add_participant", %{"attrs" => %{"name" => "otto", "provider" => "opencode"}})

    assert {:ok, dismissed} = Proposals.dismiss(message.id)
    assert dismissed.metadata["status"] == "dismissed"
    assert {:error, _} = Proposals.accept(message.id)
    assert {:error, _} = Proposals.dismiss(message.id)
    assert Enum.map(Chat.agents(room.id), & &1.name) == ["ada"]
  end

  test "one that can no longer be carried out stays pending and says why", %{room: room} do
    message =
      propose(room, "add_participant", %{"attrs" => %{"name" => "otto", "provider" => "opencode"}})

    {:ok, _} = Chat.create_agent(room.id, %{"name" => "otto", "provider" => "claude"})

    assert {:error, reason} = Proposals.accept(message.id)
    assert reason =~ "already used"
    assert Chat.proposal!(message.id).metadata["status"] == "pending"
  end

  test "the team head and removals happen only when accepted", %{room: room, ada: ada} do
    {:ok, bea} = Chat.create_agent(room.id, %{"name" => "bea", "provider" => "codex"})
    head = propose(room, "set_team_head", %{"agent_id" => bea.id})
    removal = propose(room, "remove_participant", %{"agent_id" => ada.id})
    again = propose(room, "remove_participant", %{"agent_id" => ada.id})

    assert Chat.team_head(room.id).id == ada.id
    assert {:ok, _} = Proposals.accept(head.id)
    assert Chat.team_head(room.id).id == bea.id

    assert {:ok, _} = Proposals.accept(removal.id)
    assert Enum.map(Chat.agents(room.id), & &1.name) == ["bea"]

    assert {:error, reason} = Proposals.accept(again.id)
    assert reason =~ "no longer"
  end
end
