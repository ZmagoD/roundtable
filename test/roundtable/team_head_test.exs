defmodule Roundtable.TeamHeadTest do
  use Roundtable.DataCase, async: false
  alias Roundtable.Chat
  alias Roundtable.Chat.Run

  setup do
    {:ok, room} = Chat.create_room(%{"name" => "Engineering", "directory" => File.cwd!()})

    members =
      for name <- ~w(morgan ada grace) do
        {:ok, agent} =
          Chat.create_agent(room.id, %{
            "name" => name,
            "provider" => "codex",
            "directory" => File.cwd!()
          })

        agent
      end

    [morgan, ada, grace] = members
    %{room: room, morgan: morgan, ada: ada, grace: grace}
  end

  test "a team starts with nobody designated", ctx do
    assert Chat.team_head(ctx.room.id) == nil
  end

  test "choosing a head records it", ctx do
    {:ok, head} = Chat.set_team_head(ctx.morgan.id)

    assert head.head
    assert Chat.team_head(ctx.room.id).id == ctx.morgan.id
  end

  test "choosing another head replaces the first", ctx do
    {:ok, _} = Chat.set_team_head(ctx.morgan.id)
    {:ok, _} = Chat.set_team_head(ctx.ada.id)

    assert Chat.team_head(ctx.room.id).id == ctx.ada.id
    refute Chat.agent!(ctx.morgan.id).head
  end

  test "a team can be left with nobody designated again", ctx do
    {:ok, _} = Chat.set_team_head(ctx.morgan.id)
    :ok = Chat.clear_team_head(ctx.room.id)

    assert Chat.team_head(ctx.room.id) == nil
  end

  test "each team has its own head", ctx do
    {:ok, other} = Chat.create_room(%{"name" => "Sales", "directory" => File.cwd!()})

    {:ok, priya} =
      Chat.create_agent(other.id, %{
        "name" => "priya",
        "provider" => "codex",
        "directory" => File.cwd!()
      })

    {:ok, _} = Chat.set_team_head(ctx.morgan.id)
    {:ok, _} = Chat.set_team_head(priya.id)

    assert Chat.team_head(ctx.room.id).id == ctx.morgan.id
    assert Chat.team_head(other.id).id == priya.id
  end

  test "every participant's turn says who the head is", ctx do
    {:ok, _} = Chat.set_team_head(ctx.morgan.id)

    {:ok, message} = Chat.post(ctx.room.id, "@grace have a look")
    run = Repo.one!(from r in Run, where: r.message_id == ^message.id)

    {prompt, _until} = Chat.prompt(Chat.agent!(ctx.grace.id), run)

    assert prompt =~ "@morgan:"
    assert prompt =~ "team head"
  end

  test "a team with no head says nothing about one", ctx do
    {:ok, message} = Chat.post(ctx.room.id, "@grace have a look")
    run = Repo.one!(from r in Run, where: r.message_id == ^message.id)

    {prompt, _until} = Chat.prompt(Chat.agent!(ctx.grace.id), run)

    refute prompt =~ "team head"
  end
end
