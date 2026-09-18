defmodule Roundtable.TeamBuilderTest do
  use Roundtable.DataCase, async: false

  alias Roundtable.{Chat, MCP}
  alias Roundtable.Chat.{Agent, Message, Room, Run}

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "Payments",
        directory: File.cwd!(),
        provider: "codex",
        context: "Build a small team to maintain payments."
      },
      overrides
    )
  end

  test "both supported providers create a complete, durable setup" do
    for provider <- ["codex", "claude"] do
      assert {:ok, room} = Chat.build_team(attrs(%{provider: provider}))
      assert Repo.get!(Room, room.id).context == attrs().context
      assert [agent] = Chat.agents(room.id)
      assert agent.provider == provider
      assert agent.directory == room.directory
      assert agent.name == "team-builder"
      refute agent.auto_approve
      assert is_nil(agent.model)
      assert [message] = Chat.messages(room.id)
      assert message.sender == "you"
      assert message.body =~ attrs().context
      assert [run] = Chat.runs(room.id)
      assert run.agent_id == agent.id
      assert run.status == "queued"
    end
  end

  test "invalid inputs leave no rooms, participants, messages or runs" do
    invalid = [
      %{name: ""},
      %{name: String.duplicate("x", 81)},
      %{context: " "},
      %{context: String.duplicate("x", 4001)},
      %{directory: "relative/path"},
      %{directory: __ENV__.file},
      %{provider: "grok"},
      %{provider: "opencode"},
      %{provider: nil}
    ]

    for overrides <- invalid do
      assert {:error, %Ecto.Changeset{}} = Chat.build_team(attrs(overrides))
      for schema <- [Room, Agent, Message, Run], do: assert(Repo.aggregate(schema, :count) == 0)
    end
  end

  test "a supported provider must also be configured" do
    previous = Application.get_env(:roundtable, :adapters)
    Application.put_env(:roundtable, :adapters, [Roundtable.Agents.Claude])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:roundtable, :adapters, previous),
        else: Application.delete_env(:roundtable, :adapters)
    end)

    assert {:error, changeset} = Chat.build_team(attrs())
    assert errors_on(changeset).provider != []
    assert Chat.rooms() == []
  end

  test "setup ignores injected participant settings and notifies room subscribers" do
    Phoenix.PubSub.subscribe(Roundtable.PubSub, "rooms")

    assert {:ok, room} =
             Chat.build_team(attrs(%{auto_approve: true, model: "invented", role: "ignore"}))

    assert_receive :rooms_updated
    [agent] = Chat.agents(room.id)
    refute agent.auto_approve
    assert is_nil(agent.model)
    refute agent.role == "ignore"
  end

  test "the helper can assemble its team from profiles and configure schedules" do
    {:ok, _} =
      Chat.create_agent_profile(%{name: "reviewer", provider: "claude", role: "Review changes"})

    {:ok, room} = Chat.build_team(attrs())
    [builder] = Chat.agents(room.id)
    assert {:ok, authenticated} = MCP.participant(MCP.token(builder))
    assert authenticated.id == builder.id

    assert {:ok, _} = MCP.call(builder, "update_room", %{"brief" => "Keep payments reliable"})
    assert {:ok, _} = MCP.call(builder, "add_participant", %{"profile" => "reviewer"})

    assert {:ok, _} =
             MCP.call(builder, "add_participant", %{
               "name" => "implementer",
               "provider" => "codex",
               "role" => "Implement reviewed changes"
             })

    assert {:ok, _} =
             MCP.call(builder, "create_schedule", %{
               "participant" => "reviewer",
               "at" => "09:00",
               "prompt" => "Review open changes"
             })

    assert Chat.room!(room.id).context == "Keep payments reliable"

    assert Enum.sort(Enum.map(Chat.agents(room.id), & &1.name)) == [
             "implementer",
             "reviewer",
             "team-builder"
           ]

    assert [schedule] = Chat.schedules(room.id)
    assert schedule.at == "09:00"
    # Assembling the team must not start work on behalf of the new participants.
    assert [%{agent_id: id}] = Chat.runs(room.id)
    assert id == builder.id
  end
end
