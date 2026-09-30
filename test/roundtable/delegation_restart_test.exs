defmodule Roundtable.DelegationRestartTest do
  use Roundtable.DataCase, async: false

  alias Roundtable.Chat
  alias Roundtable.Chat.{Message, Run}

  setup do
    {:ok, room} = Chat.create_room(%{"name" => "Delegation", "directory" => File.cwd!()})

    [head, dev, qa] =
      for name <- ~w(lead dev qa) do
        {:ok, agent} =
          Chat.create_agent(room.id, %{
            "name" => name,
            "provider" => "codex",
            "directory" => File.cwd!()
          })

        agent
      end

    Chat.set_team_head(head.id)
    {:ok, root} = Chat.post(room.id, "Please fix this")
    %{room: room, head: head, dev: dev, qa: qa, root: root}
  end

  test "three head restarts allow review rounds, then stop, with a fresh human allowance", ctx do
    last =
      Enum.reduce(1..3, ctx.root, fn round, source ->
        delegated = reply(source, ctx.head, ctx.dev)
        assert recipient_ids(delegated) == [ctx.dev.id]
        assert delegated.metadata["local_depth"] == 0
        assert delegated.depth == (round - 1) * 3 + 1
        reviewed = reply(delegated, ctx.dev, ctx.qa)
        assert recipient_ids(reviewed) == [ctx.qa.id]
        returned = reply(reviewed, ctx.qa, ctx.head)
        assert recipient_ids(returned) == [ctx.head.id]
        returned
      end)

    stopped = reply(last, ctx.head, ctx.dev)
    assert recipient_ids(stopped) == []
    assert Repo.get!(Message, stopped.id).body == "@dev continue"
    assert Repo.get!(Message, ctx.root.id).metadata["head_restarts"] == 3

    {:ok, fresh} = Chat.post(ctx.room.id, "Try a new approach")
    assert recipient_ids(reply(fresh, ctx.head, ctx.dev)) == [ctx.dev.id]
  end

  test "branches share the persisted allowance even when callers retain stale messages", ctx do
    for _ <- 1..3, do: assert(recipient_ids(reply(ctx.root, ctx.head, ctx.dev)) == [ctx.dev.id])
    assert recipient_ids(reply(ctx.root, ctx.head, ctx.qa)) == []
    assert Repo.get!(Message, ctx.root.id).metadata["head_restarts"] == 3
  end

  test "non-head replies cannot reset a four-hop chain", ctx do
    source = reply(ctx.root, ctx.dev, ctx.qa)
    source = reply(source, ctx.qa, ctx.dev)
    source = reply(source, ctx.dev, ctx.qa)
    assert recipient_ids(source) == [ctx.qa.id]
    assert recipient_ids(reply(source, ctx.qa, ctx.dev)) == []
    refute Map.has_key?(Repo.get!(Message, ctx.root.id).metadata, "head_restarts")
  end

  test "without a head the original four-hop cap applies", ctx do
    Chat.clear_team_head(ctx.room.id)
    source = reply(ctx.root, ctx.head, ctx.dev)
    source = reply(source, ctx.dev, ctx.qa)
    source = reply(source, ctx.qa, ctx.head)
    assert recipient_ids(source) == [ctx.head.id]
    assert recipient_ids(reply(source, ctx.head, ctx.dev)) == []
  end

  test "reporting without local recipients does not spend a restart", ctx do
    {:ok, _} =
      Chat.post(ctx.room.id, "Work completed",
        kind: "agent",
        sender: ctx.head.name,
        agent_id: ctx.head.id,
        reply_to: ctx.root.id,
        depth: 1
      )

    refute Map.has_key?(Repo.get!(Message, ctx.root.id).metadata, "head_restarts")
  end

  test "local restarts do not relax cross-room request depth", ctx do
    {:ok, other} = Chat.create_room(%{"name" => "Other", "directory" => File.cwd!()})

    {:ok, remote} =
      Chat.create_agent(other.id, %{
        "name" => "remote",
        "provider" => "codex",
        "directory" => File.cwd!()
      })

    source = reply(ctx.root, ctx.head, ctx.dev)
    source = reply(source, ctx.dev, ctx.qa)
    source = reply(source, ctx.qa, ctx.head)
    restarted = reply(source, ctx.head, ctx.dev)
    assert restarted.depth == 4
    assert recipient_ids(restarted) == [ctx.dev.id]
    assert {:error, reason} = Chat.request("ask", restarted, other, remote, "Review this")
    assert reason =~ "Too many hops"
    assert Chat.runs(other.id) == []
  end

  defp reply(source, sender, recipient) do
    {:ok, message} =
      Chat.post(source.room_id, "@#{recipient.name} continue",
        kind: "agent",
        sender: sender.name,
        agent_id: sender.id,
        reply_to: source.id,
        depth: source.depth + 1
      )

    message
  end

  defp recipient_ids(message) do
    Repo.all(from r in Run, where: r.message_id == ^message.id, select: r.agent_id)
  end
end
