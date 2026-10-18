defmodule Roundtable.WaitingTest do
  use Roundtable.DataCase, async: false
  alias Roundtable.{Chat, Proposals}

  setup do
    {:ok, room} = Chat.create_room(%{"name" => "Waiting", "directory" => File.cwd!()})
    {:ok, other} = Chat.create_room(%{"name" => "Elsewhere", "directory" => File.cwd!()})
    {:ok, ada} = Chat.create_agent(room.id, %{"name" => "ada", "provider" => "claude"})
    {:ok, lead} = Chat.create_agent(room.id, %{"name" => "lead", "provider" => "claude"})
    %{room: room, other: other, ada: ada, lead: lead}
  end

  defp say(agent, body),
    do: Chat.post(agent.room_id, body, sender: agent.name, agent_id: agent.id, kind: "agent")

  defp approval(agent),
    do: %{agent: agent.name, agent_id: agent.id, room_id: agent.room_id, params: %{}}

  test "nobody is waiting in a quiet room", ctx do
    assert Chat.waiting([ctx.room.id, ctx.other.id], []) == %{}
    assert Chat.waiting([], [approval(ctx.ada)]) == %{}
  end

  test "a pending approval names who needs it, and answering clears it", ctx do
    room_id = ctx.room.id
    assert %{^room_id => [entry]} = Chat.waiting([room_id, ctx.other.id], [approval(ctx.lead)])
    assert entry == %{agent_id: ctx.lead.id, name: "lead", reasons: [:approval]}

    # Approvals are the coordinator's, so an answered one is simply not passed in.
    assert Chat.waiting([ctx.room.id], []) == %{}
    # Nor does a room outside the list report one.
    assert Chat.waiting([ctx.other.id], [approval(ctx.lead)]) == %{}
  end

  test "an open request card waits until it is answered", ctx do
    {:ok, card} =
      Chat.propose(ctx.room.id, "ada", "remove_participant", %{
        "room_id" => ctx.room.id,
        "agent_id" => ctx.lead.id
      })

    assert %{} = waiting = Chat.waiting([ctx.room.id], [])
    assert [%{agent_id: id, name: "ada", reasons: [:proposal]}] = waiting[ctx.room.id]
    assert id == ctx.ada.id

    {:ok, _} = Proposals.dismiss(card.id)
    assert Chat.waiting([ctx.room.id], []) == %{}
  end

  test "a question in the last paragraph waits until the human posts", ctx do
    say(ctx.ada, "Is this right? I checked.\n\nWhich branch should I push to?")
    assert [%{name: "ada", reasons: [:question]}] = Chat.waiting([ctx.room.id], [])[ctx.room.id]

    # Posting in another room answers nothing here.
    Chat.post(ctx.other.id, "Unrelated")
    assert Chat.waiting([ctx.room.id], [])[ctx.room.id]

    Chat.post(ctx.room.id, "Push to main.")
    assert Chat.waiting([ctx.room.id], []) == %{}
  end

  test "only the participant's latest message is read for a question", ctx do
    say(ctx.ada, "Shall I start?")
    say(ctx.ada, "Started, nothing needed from you.")
    assert Chat.waiting([ctx.room.id], []) == %{}

    say(ctx.ada, "Should I keep going?\n\nI paused here.")
    assert Chat.waiting([ctx.room.id], []) == %{}

    say(ctx.ada, "Ready to merge **now?**")
    assert Chat.waiting([ctx.room.id], [])[ctx.room.id]
  end

  test "system notes and cross-room answers are not questions from a participant", ctx do
    Chat.post(ctx.room.id, "Is anyone there?", sender: "system", kind: "agent")
    Chat.post(ctx.room.id, "Which room?", sender: "elsewhere/bob", kind: "agent")
    Chat.supervisor_notice(ctx.room.id, "Commit or park it?", "notice")
    assert Chat.waiting([ctx.room.id], []) == %{}
  end

  test "one participant waiting for two reasons is counted once", ctx do
    say(ctx.lead, "May I run the migration?")
    say(ctx.ada, "Done.")

    assert [%{name: "lead", reasons: [:approval, :question]}] =
             Chat.waiting([ctx.room.id], [approval(ctx.lead)])[ctx.room.id]
  end

  test "changes that can move the marker are announced on the rooms topic", ctx do
    Phoenix.PubSub.subscribe(Roundtable.PubSub, "rooms")
    room_id = ctx.room.id

    say(ctx.ada, "Ready?")
    assert_receive {:waiting_changed, ^room_id}

    {:ok, card} =
      Chat.propose(room_id, "ada", "set_team_head", %{
        "room_id" => room_id,
        "agent_id" => ctx.ada.id
      })

    assert_receive {:waiting_changed, ^room_id}

    {:ok, _} = Proposals.dismiss(card.id)
    assert_receive {:waiting_changed, ^room_id}
  end
end
