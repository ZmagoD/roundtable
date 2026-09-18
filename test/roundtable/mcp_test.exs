defmodule Roundtable.MCPTest do
  @moduledoc """
  The rooms themselves, as tools a participant can use.

  What matters here is not that a row appears. It is that a participant asking
  for a room is held to the same rules as the form — the room's own directory,
  a name that can be mentioned, a provider that exists — that what it did is
  said out loud in the room where it was asked for, and that saying so never
  starts another turn.
  """
  use Roundtable.DataCase, async: false

  alias Roundtable.Chat
  alias Roundtable.Chat.{Agent, Message, Run}
  alias Roundtable.MCP

  setup do
    Application.put_env(:roundtable, :mcp_url, "http://127.0.0.1:4002/mcp")
    on_exit(fn -> Application.delete_env(:roundtable, :mcp_url) end)

    {:ok, room} =
      Chat.create_room(%{
        "name" => "Checkout",
        "directory" => File.cwd!(),
        "context" => "ship the cart"
      })

    {:ok, ada} = Chat.create_agent(room.id, %{"name" => "ada", "provider" => "claude"})
    %{room: room, ada: ada}
  end

  describe "making a room" do
    test "it starts in the working tree of the room it was asked from", %{room: room, ada: ada} do
      assert {:ok, text} = MCP.call(ada, "create_room", %{"name" => "Docs"})

      made = Chat.find_room("Docs")
      assert made.directory == room.directory
      assert made.context == ""
      assert text =~ "room #{made.id}"
      assert Chat.agents(made.id) == []
    end

    test "a brief can be given with it", %{ada: ada} do
      assert {:ok, _} =
               MCP.call(ada, "create_room", %{"name" => "Docs", "brief" => "write the manual"})

      assert Chat.find_room("Docs").context == "write the manual"
    end

    test "a directory that is not there is refused, in a sentence", %{ada: ada} do
      assert {:error, message} =
               MCP.call(ada, "create_room", %{"name" => "Docs", "directory" => "/nowhere/at/all"})

      assert message =~ "directory"
      assert Chat.find_room("Docs") == nil
    end
  end

  describe "what the room is told" do
    test "every change is said out loud where it was asked for", %{room: room, ada: ada} do
      {:ok, _} = MCP.call(ada, "create_room", %{"name" => "Docs"})

      said = room.id |> Chat.messages() |> List.last()
      assert said.sender == "system"
      assert said.body =~ "ada: created room"
      assert said.body =~ "Docs"
    end

    test "and saying it never starts a turn", %{ada: ada} do
      # A room named after a participant would otherwise read as a mention.
      {:ok, _} = MCP.call(ada, "create_room", %{"name" => "@ada"})

      assert Repo.aggregate(Run, :count) == 0
      refute Enum.any?(Repo.all(Message), &(&1.body =~ "@"))
    end

    test "a tool that refuses says nothing in the room", %{room: room, ada: ada} do
      before = length(Chat.messages(room.id))
      assert {:error, _} = MCP.call(ada, "create_room", %{"name" => ""})
      assert length(Chat.messages(room.id)) == before
    end
  end

  describe "adding participants" do
    test "from a profile, under another name", %{room: room, ada: ada} do
      {:ok, _} =
        Chat.create_agent_profile(%{
          "name" => "reviewer",
          "provider" => "codex",
          "role" => "read every diff twice"
        })

      assert {:ok, text} =
               MCP.call(ada, "add_participant", %{
                 "profile" => "reviewer",
                 "name" => "reviewer-api"
               })

      assert text =~ "reviewer-api"
      added = Enum.find(Chat.agents(room.id), &(&1.name == "reviewer-api"))
      assert added.provider == "codex"
      assert added.role == "read every diff twice"
    end

    test "from scratch, into the room's own tree", %{room: room, ada: ada} do
      assert {:ok, _} =
               MCP.call(ada, "add_participant", %{
                 "name" => "linus",
                 "provider" => "claude",
                 "role" => "write the migration",
                 "cost_tier" => "economy"
               })

      linus = Enum.find(Chat.agents(room.id), &(&1.name == "linus"))
      assert linus.directory == room.directory
      assert linus.cost_tier == "economy"
    end

    test "into another room, by name", %{ada: ada} do
      {:ok, _} = MCP.call(ada, "create_room", %{"name" => "Docs"})

      assert {:ok, _} =
               MCP.call(ada, "add_participant", %{
                 "room" => "docs",
                 "name" => "linus",
                 "provider" => "claude"
               })

      assert [%Agent{name: "linus"}] = Chat.agents(Chat.find_room("Docs").id)
    end

    test "a provider that does not exist is refused", %{room: room, ada: ada} do
      assert {:error, message} =
               MCP.call(ada, "add_participant", %{"name" => "linus", "provider" => "gpt"})

      assert message =~ "provider"
      assert Chat.agents(room.id) |> Enum.map(& &1.name) == ["ada"]
    end

    test "a room nobody has is named, not guessed at", %{ada: ada} do
      assert {:error, message} =
               MCP.call(ada, "add_participant", %{
                 "room" => "billing",
                 "name" => "linus",
                 "provider" => "claude"
               })

      assert message =~ "billing"
    end
  end

  describe "changing what is already there" do
    test "a room's brief, leaving its directory alone", %{room: room, ada: ada} do
      assert {:ok, _} = MCP.call(ada, "update_room", %{"brief" => "ship the cart, then the tax"})

      updated = Chat.room!(room.id)
      assert updated.context == "ship the cart, then the tax"
      assert updated.directory == room.directory
    end

    test "a participant's role and model", %{ada: ada} do
      assert {:ok, text} =
               MCP.call(ada, "update_participant", %{
                 "participant" => "ada",
                 "role" => "plan first",
                 "model" => "opus"
               })

      assert text =~ "model, role"
      assert Chat.agent!(ada.id).role == "plan first"
    end

    test "only the fields that were sent", %{ada: ada} do
      {:ok, _} = MCP.call(ada, "update_participant", %{"participant" => "ada", "role" => "plan"})
      {:ok, _} = MCP.call(ada, "update_participant", %{"participant" => "ada", "model" => "opus"})

      still = Chat.agent!(ada.id)
      assert still.role == "plan"
      assert still.model == "opus"
    end

    test "somebody who is not in the room", %{ada: ada} do
      assert {:error, message} =
               MCP.call(ada, "update_participant", %{"participant" => "linus", "role" => "plan"})

      assert message =~ "linus"
    end
  end

  describe "the profile library" do
    test "a profile can be saved and then changed", %{ada: ada} do
      assert {:ok, _} =
               MCP.call(ada, "create_profile", %{"name" => "reviewer", "provider" => "codex"})

      assert {:ok, _} =
               MCP.call(ada, "update_profile", %{"profile" => "reviewer", "role" => "be strict"})

      assert [%{name: "reviewer", role: "be strict"}] = Chat.agent_profiles()
    end

    test "saving one adds nobody to a room", %{room: room, ada: ada} do
      {:ok, _} = MCP.call(ada, "create_profile", %{"name" => "reviewer", "provider" => "codex"})
      assert Chat.agents(room.id) |> Enum.map(& &1.name) == ["ada"]
    end
  end

  describe "looking" do
    test "rooms come back with who is in them", %{room: room, ada: ada} do
      assert {:ok, json} = MCP.call(ada, "list_rooms", %{})
      [listed] = Jason.decode!(json)

      assert listed["id"] == room.id
      assert listed["brief"] == "ship the cart"
      assert listed["participants"] == ["ada"]
    end

    test "providers say whether they are installed", %{ada: ada} do
      assert {:ok, json} = MCP.call(ada, "list_providers", %{})
      providers = Jason.decode!(json)

      assert Enum.all?(providers, &is_boolean(&1["installed"]))
      assert "claude" in Enum.map(providers, & &1["id"])
    end

    test "a tool that does not exist says so rather than failing quietly", %{ada: ada} do
      assert {:error, message} = MCP.call(ada, "delete_everything", %{})
      assert message =~ "delete_everything"
    end

    test "every tool is described well enough to be chosen" do
      for tool <- MCP.tools() do
        assert String.length(tool.description) > 40
        assert tool.inputSchema.type == "object"
        assert is_map(tool.inputSchema.properties)
      end
    end
  end

  describe "who is calling" do
    test "a token names the participant it was minted for", %{ada: ada} do
      assert {:ok, found} = MCP.participant(MCP.token(ada))
      assert found.id == ada.id
    end

    test "anything else is nobody", %{ada: ada} do
      assert {:error, :invalid} = MCP.participant("not-a-token")
      assert {:error, :invalid} = MCP.participant(nil)

      {:ok, _} = Chat.delete_agent(ada.id)
      assert {:error, :gone} = MCP.participant(MCP.token(ada))
    end
  end

  describe "wiring into a provider" do
    alias Roundtable.Agents.Protocol

    test "claude is given the server on the command line", %{ada: ada} do
      {"claude", args} = Protocol.command(ada)
      pairs = Enum.chunk_every(args, 2, 1)

      assert [_flag, config] = Enum.find(pairs, &match?(["--mcp-config", _], &1))
      server = Jason.decode!(config)["mcpServers"]["roundtable"]

      assert server["url"] == "http://127.0.0.1:4002/mcp"
      assert "Bearer " <> token = server["headers"]["Authorization"]
      assert {:ok, %{id: id}} = MCP.participant(token)
      assert id == ada.id
    end

    test "codex takes its overrides before the subcommand, and its token from the environment",
         %{room: room} do
      {:ok, codex} = Chat.create_agent(room.id, %{"name" => "linus", "provider" => "codex"})
      {"codex", args} = Protocol.command(codex)

      assert List.last(args) == "app-server"
      assert Enum.any?(args, &(&1 =~ "mcp_servers.roundtable.url="))
      assert Enum.any?(args, &(&1 =~ "bearer_token_env_var=\"ROUNDTABLE_MCP_TOKEN\""))
      refute Enum.any?(args, &(&1 =~ "Bearer"))

      assert [{~c"ROUNDTABLE_MCP_TOKEN", token}] = Protocol.env(codex)
      assert {:ok, _} = token |> to_string() |> MCP.participant()
    end

    test "a provider with no way to say no is given nothing", %{room: room} do
      {:ok, opencode} = Chat.create_agent(room.id, %{"name" => "otto", "provider" => "opencode"})

      refute MCP.offered?(opencode)
      assert {"opencode", ["run", "--format", "json"]} = Protocol.command(opencode)
      assert Protocol.env(opencode) == []
    end

    test "and neither is anyone, when the service is not serving", %{ada: ada} do
      Application.put_env(:roundtable, :mcp_url, false)

      refute MCP.offered?(ada)
      assert {"claude", args} = Protocol.command(ada)
      refute "--mcp-config" in args
    end

    test "a participant with the tools is told it has them", %{ada: ada, room: room} do
      {:ok, message} = Chat.post(room.id, "get on with it")

      run = %Run{
        id: -1,
        message_id: message.id,
        model: nil,
        cost_tier: "unknown",
        purpose: "general"
      }

      {with_tools, _} = Chat.prompt(ada, run)
      assert with_tools =~ "THE ROOMS THEMSELVES"

      Application.put_env(:roundtable, :mcp_url, false)
      {without, _} = Chat.prompt(ada, run)
      refute without =~ "THE ROOMS THEMSELVES"
    end
  end
end
