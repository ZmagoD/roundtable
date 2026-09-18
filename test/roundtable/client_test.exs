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

  describe "talking to a node that is not there" do
    # The terminal shows whatever comes back here, so an unreachable service has
    # to become a message rather than an exit that takes the client down.
    @absent %Client{node: :"roundtable@nowhere-that-exists"}

    test "an unreachable node is an error, not a crash" do
      assert {:error, :disconnected} = Client.rooms(@absent)
      assert {:error, :disconnected} = Client.agents(@absent, 1)
      assert {:error, :disconnected} = Client.post(@absent, 1, "hello")
      assert {:error, :disconnected} = Client.approvals(@absent, 1)
    end

    test "connecting without distribution says so" do
      refute Node.alive?()
      assert {:error, :no_distribution} = Client.connect(:roundtable@nowhere)
    end

    test "an in-process client still raises what the context raises", %{client: c} do
      # Locally there is no transport to translate the error, and a caller in
      # the same node expects the context's own behaviour.
      assert_raise Ecto.NoResultsError, fn -> Client.update_agent(c, 999_999, %{}) end
    end

    test "watching an absent node fails without leaving a relay behind" do
      assert {:error, :disconnected} = Client.watch(@absent, self(), 1)
      refute_receive :watch_ready, 100
    end

    test "rewatch on a client with no relay is harmless" do
      assert Client.rewatch(@absent, nil, 1, 2) == :ok
    end
  end
end
