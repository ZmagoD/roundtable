defmodule Roundtable.CrossRoomTest do
  use Roundtable.DataCase, async: false
  alias Roundtable.{Chat, Repo}
  alias Roundtable.Chat.{CrossRoomRequest, Message, Run}

  setup do
    {:ok, platform} = Chat.create_room(%{"name" => "Platform", "directory" => File.cwd!()})
    {:ok, design} = Chat.create_room(%{"name" => "Design Team", "directory" => File.cwd!()})

    {:ok, captain} =
      Chat.create_agent(platform.id, %{
        "name" => "captain",
        "provider" => "claude",
        "directory" => File.cwd!()
      })

    {:ok, grace} =
      Chat.create_agent(design.id, %{
        "name" => "grace",
        "provider" => "opencode",
        "directory" => File.cwd!()
      })

    %{platform: platform, design: design, captain: captain, grace: grace}
  end

  defp answer(request_message_id, text) do
    Chat.deliver_answer(request_message_id, text)
  end

  test "a room name becomes an address" do
    assert Chat.room_slug("Design Team") == "design-team"
    assert Chat.room_slug("Platform") == "platform"
    assert Chat.room_slug("  Odd   name!  ") == "odd-name"
  end

  test "finds a room by slug, name or id", %{design: design} do
    assert Chat.find_room("design-team").id == design.id
    assert Chat.find_room("Design Team").id == design.id
    assert Chat.find_room(to_string(design.id)).id == design.id
    assert Chat.find_room("nope") == nil
  end

  test "parses cross-room mentions without swallowing local ones" do
    assert Chat.cross_room_mentions("@design-team/grace how?") == [{"design-team", "grace"}]
    assert Chat.cross_room_mentions("no mentions here") == []

    # A local mention must not match the room half of a cross-room one.
    agents = [%Roundtable.Chat.Agent{id: 1, name: "design"}]
    assert Chat.recipients("@design-team/grace", agents) == []
    assert Chat.recipients("@design please", agents) == [hd(agents)]
  end

  test "a human ask reaches the other room and comes back", ctx do
    assert {:ok, request} =
             Chat.request_from_room(
               "ask",
               ctx.platform.id,
               "design-team/grace",
               "how should pagination look?"
             )

    assert request.kind == "ask"
    assert request.status == "delivered"

    # It landed in Design as a turn for grace, and nowhere else.
    delivered = Repo.get!(Message, request.to_message_id)
    assert delivered.room_id == ctx.design.id
    assert delivered.body =~ "@grace"
    assert delivered.body =~ "how should pagination look?"
    assert [%Run{agent_id: agent_id}] = Chat.runs(ctx.design.id)
    assert agent_id == ctx.grace.id

    # Platform's transcript records the question before any answer arrives.
    assert Enum.any?(Chat.messages(ctx.platform.id), &(&1.body =~ "Asked @design-team/grace"))

    answer(request.to_message_id, "two pages, cursor based")

    assert Repo.get!(CrossRoomRequest, request.id).status == "answered"
    reply = Chat.messages(ctx.platform.id) |> List.last()
    assert reply.body =~ "two pages, cursor based"
    assert reply.sender == "design-team/grace"
    assert reply.metadata["cross_room"] == "answer"
  end

  test "an agent's mention asks the other room, and the answer wakes the asker", ctx do
    {:ok, message} =
      Chat.post(ctx.platform.id, "@design-team/grace what spacing?",
        sender: "captain",
        agent_id: ctx.captain.id,
        kind: "agent"
      )

    assert [request] = Repo.all(CrossRoomRequest)
    assert request.from_agent_id == ctx.captain.id
    assert request.from_message_id == message.id

    answer(request.to_message_id, "8px")

    # The answer mentions the asking agent, so it gets a turn to use it.
    reply = Chat.messages(ctx.platform.id) |> List.last()
    assert reply.body =~ "@captain"
    assert Enum.any?(Chat.runs(ctx.platform.id), &(&1.agent_id == ctx.captain.id))
  end

  test "a human ask does not schedule anyone in the asking room", ctx do
    {:ok, request} = Chat.request_from_room("ask", ctx.platform.id, "design-team/grace", "ping")
    answer(request.to_message_id, "pong")

    assert Chat.runs(ctx.platform.id) == []
  end

  test "delivering a request never asks the same question again", ctx do
    {:ok, _} =
      Chat.request_from_room(
        "ask",
        ctx.platform.id,
        "design-team/grace",
        "@design-team/grace recurse?"
      )

    # The delivered message quotes the mention; scanning it would loop forever.
    assert length(Repo.all(CrossRoomRequest)) == 1
  end

  test "an answer quoting a mention does not bounce back", ctx do
    {:ok, request} = Chat.request_from_room("ask", ctx.platform.id, "design-team/grace", "how?")
    answer(request.to_message_id, "ask @design-team/grace again")

    assert length(Repo.all(CrossRoomRequest)) == 1
  end

  test "the hop cap spans rooms", ctx do
    {:ok, deep} =
      Chat.post(ctx.platform.id, "deep in a chain", sender: "captain", kind: "agent", depth: 4)

    assert {:error, reason} =
             Chat.request("ask", deep, ctx.design, ctx.grace, "one more?")

    assert reason =~ "Too many hops"
  end

  test "rejects a request to an agent in the same room", ctx do
    {:ok, message} = Chat.post(ctx.platform.id, "hello")

    assert {:error, reason} =
             Chat.request("ask", message, ctx.platform, ctx.captain, "why?")

    assert reason =~ "already in this room"
  end

  test "a failed turn reports back without waking the asker", ctx do
    {:ok, request} = Chat.request_from_room("ask", ctx.platform.id, "design-team/grace", "how?")
    Chat.fail_request(request.to_message_id, "OpenCode exited (1).")

    assert Repo.get!(CrossRoomRequest, request.id).status == "failed"
    reply = Chat.messages(ctx.platform.id) |> List.last()
    assert reply.body =~ "could not finish"
    refute reply.body =~ "@captain"
  end

  test "unresolvable targets explain themselves", ctx do
    assert {:error, reason} = Chat.request_from_room("ask", ctx.platform.id, "ghost/grace", "hi")
    assert reason =~ "No room called ghost"

    assert {:error, reason} =
             Chat.request_from_room("ask", ctx.platform.id, "design-team/ghost", "hi")

    assert reason =~ "It has: @grace"

    assert {:error, reason} = Chat.request_from_room("ask", ctx.platform.id, "design-team", "hi")
    assert reason =~ "room/agent"
  end

  test "each room's prompt lists the others, and only the others", ctx do
    {:ok, message} = Chat.post(ctx.platform.id, "@captain go")
    run = Repo.get_by!(Run, agent_id: ctx.captain.id, message_id: message.id)

    {prompt, _} = Chat.prompt(ctx.captain, run)
    assert prompt =~ "Other rooms you can reach:"
    assert prompt =~ "Design Team: @design-team/grace (opencode)"
    refute prompt =~ "Platform: @platform/captain"
  end
end
