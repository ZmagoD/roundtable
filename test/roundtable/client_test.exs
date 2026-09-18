defmodule Roundtable.ClientTest do
  use Roundtable.DataCase
  alias Roundtable.{Chat, Client}

  setup do
    {:ok, room} = Chat.create_room(%{"name" => "Checkout", "directory" => File.cwd!()})

    {:ok, agent} =
      Chat.create_agent(room.id, %{
        "name" => "ada",
        "provider" => "codex",
        "directory" => File.cwd!()
      })

    %{room: room, agent: agent, client: Client.local()}
  end

  test "a local client reads through the same context the web UI uses", %{client: c, room: room} do
    assert [%{name: "Checkout"}] = Client.rooms(c)
    assert [%{name: "ada"}] = Client.agents(c, room.id)
    assert Client.messages(c, room.id) == []
    assert Client.runs(c, room.id) == []
    assert Client.approvals(c, room.id) == []
  end

  test "posting goes through the coordinator and schedules the mentioned agent", %{
    client: c,
    room: room
  } do
    assert {:ok, message} = Client.post(c, room.id, "@ada check the tests")
    assert message.body == "@ada check the tests"

    assert [%{body: "@ada check the tests"}] = Client.messages(c, room.id)
    assert [%{status: "queued"}] = Client.runs(c, room.id)
  end

  test "an invalid post is reported, not raised", %{client: c, room: room} do
    assert {:error, _} = Client.post(c, room.id, "   ")
  end

  test "creating a room and an agent", %{client: c} do
    assert {:ok, room} = Client.create_room(c, %{"name" => "Infra", "directory" => File.cwd!()})

    assert {:ok, agent} =
             Client.create_agent(c, room.id, %{
               "name" => "bob",
               "provider" => "claude",
               "directory" => File.cwd!()
             })

    assert agent.name == "bob"

    assert {:error, %Ecto.Changeset{}} =
             Client.create_room(c, %{"name" => "Bad", "directory" => "/nope"})
  end

  test "a local watch delivers room broadcasts to the caller", %{client: c, room: room} do
    assert {:ok, :local} = Client.watch(c, self(), room.id)
    assert_received :watch_ready

    Chat.broadcast(room.id)
    assert_receive :room_updated
  end

  test "describe names where the client is pointed", %{client: c} do
    assert Client.describe(c) == "in-process"
    assert Client.describe(%Client{node: :roundtable@box}) == "roundtable@box"
  end
end
