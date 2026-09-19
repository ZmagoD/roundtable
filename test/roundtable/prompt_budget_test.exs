defmodule Roundtable.PromptBudgetTest do
  use Roundtable.DataCase, async: false
  alias Roundtable.Chat
  alias Roundtable.Chat.Run

  setup do
    {:ok, room} = Chat.create_room(%{"name" => "Long room", "directory" => File.cwd!()})

    {:ok, agent} =
      Chat.create_agent(room.id, %{
        "name" => "ada",
        "provider" => "codex",
        "directory" => File.cwd!()
      })

    %{room: room, agent: agent}
  end

  defp prompt_for(room, agent, body) do
    {:ok, message} = Chat.post(room.id, body)
    run = Repo.one!(from r in Run, where: r.message_id == ^message.id)
    Chat.prompt(Chat.agent!(agent.id), run)
  end

  test "a room shorter than the budget carries all of it", ctx do
    for n <- 1..5, do: Chat.post(ctx.room.id, "message number #{n}")

    {prompt, _until} = prompt_for(ctx.room, ctx.agent, "@ada have a look")

    assert prompt =~ "message number 1"
    assert prompt =~ "message number 5"
    refute prompt =~ "oldest unread messages are left out"
  end

  test "a room longer than one turn can carry keeps the newest and says so", ctx do
    filler = String.duplicate("x", 4_000)

    for n <- 1..40, do: Chat.post(ctx.room.id, "message number #{n} #{filler}")

    {prompt, _until} = prompt_for(ctx.room, ctx.agent, "@ada have a look")

    assert prompt =~ "oldest unread messages are left out"
    assert prompt =~ "message number 40"
    refute prompt =~ "message number 1 "
  end

  test "the assigned message is carried whatever the history costs", ctx do
    filler = String.duplicate("x", 4_000)

    for n <- 1..40, do: Chat.post(ctx.room.id, "message number #{n} #{filler}")

    {prompt, _until} = prompt_for(ctx.room, ctx.agent, "@ada the thing I actually asked for")

    assert prompt =~ "the thing I actually asked for"
  end
end
