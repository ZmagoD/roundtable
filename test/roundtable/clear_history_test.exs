defmodule Roundtable.ClearHistoryTest do
  use Roundtable.DataCase, async: false
  alias Roundtable.{Chat, Coordinator}
  alias Roundtable.Chat.CrossRoomRequest

  test "clearing removes transcript and requests but preserves the room's setup" do
    {:ok, room} =
      Chat.create_room(%{name: "Clear me", directory: File.cwd!(), context: "Keep brief"})

    {:ok, agent} = Chat.create_agent(room.id, %{name: "lead", provider: "codex"})
    Chat.set_team_head(agent.id)
    Chat.update_work_document(room.id, "Keep plan", 0)
    {:ok, note} = Chat.create_room_note(room.id, %{body: "Keep note", kind: "decision"})

    {:ok, schedule} =
      Chat.create_schedule(room.id, %{agent_id: agent.id, prompt: "Later", at: "09:00"})

    Chat.change(agent,
      session_id: "old",
      session_role: "old role",
      session_model: "old model",
      session_directory: File.cwd!(),
      last_seen_id: 99
    )

    {:ok, other} = Chat.create_room(%{name: "Other", directory: File.cwd!()})
    {:ok, _} = Chat.create_agent(other.id, %{name: "helper", provider: "claude"})
    Chat.post(room.id, "@lead old work")
    Chat.request_from_room("ask", room.id, "other/helper", "outgoing")
    Chat.request_from_room("ask", other.id, "clear-me/lead", "incoming")
    other_messages = Chat.messages(other.id)
    other_runs = Chat.runs(other.id)
    Chat.subscribe(room.id)

    assert {:ok, :ok} = Coordinator.clear_history(room.id)
    assert_receive {:history_cleared, id}
    assert id == room.id
    assert Chat.messages(room.id) == []
    assert Chat.runs(room.id) == []
    assert Repo.aggregate(CrossRoomRequest, :count) == 0
    assert Chat.messages(other.id) == other_messages
    assert Chat.runs(other.id) == other_runs
    assert Chat.room!(room.id).context == "Keep brief"
    assert Chat.work_document(room.id).body == "Keep plan"
    assert [^note] = Chat.room_notes(room.id)
    assert [^schedule] = Chat.schedules(room.id)
    fresh = Chat.agent!(agent.id)
    assert fresh.head
    assert fresh.session_id == nil
    assert fresh.session_model == nil
    assert fresh.session_role == nil
    assert fresh.session_directory == nil
    assert fresh.last_seen_id == 0
    assert {:ok, :ok} = Coordinator.clear_history(room.id)
    assert {:ok, _} = Chat.post(room.id, "New work")
    assert length(Chat.runs(room.id)) == 1
  end
end
