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
    %{room: room, ada: ada, run: turn(ada)}
  end

  # A token is only good while its turn is in progress, so a participant under
  # test needs one — exactly as it has one in production, where the token is
  # minted after the run is already running.
  defp turn(agent) do
    {:ok, message} = Chat.post(agent.room_id, "something to do")
    Repo.insert!(%Run{agent_id: agent.id, message_id: message.id, status: "running"})
  end

  # `Protocol.env/1` carries the scrubbing as well as the token, so the token is
  # picked out by name rather than by being the only thing in the list.
  defp token_in(env), do: Enum.find(env, &match?({~c"ROUNDTABLE_MCP_TOKEN", _}, &1))

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

    test "and saying it never starts a turn", %{ada: ada, run: run} do
      # A room named after a participant would otherwise read as a mention.
      {:ok, _} = MCP.call(ada, "create_room", %{"name" => "@ada"})

      # Only the turn ada is already taking; saying what it did started nothing.
      assert Repo.all(Run) |> Enum.map(& &1.id) == [run.id]
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

    # The CLI outlives the turn that started it, and the token sits in its
    # environment and in the environment of every command it ran. A copy taken
    # from there used to keep working; it must not.
    test "a token stops working when its turn ends", %{ada: ada, run: run} do
      token = MCP.token(ada)
      assert {:ok, _} = MCP.participant(token)

      Chat.change(run, status: "finished")

      assert {:error, :expired} = MCP.participant(token)
    end

    test "and cannot still be used to manage rooms", %{ada: ada, run: run} do
      token = MCP.token(ada)
      Chat.change(run, status: "finished")

      assert {:error, :expired} = MCP.participant(token)
      refute Chat.find_room("made-after-the-turn-ended")
    end

    # A turn that stopped for a human is still a turn in progress: the CLI is
    # alive and waiting, and refusing its tools mid-approval would break it.
    test "a turn waiting on an approval still has its tools", %{ada: ada, run: run} do
      token = MCP.token(ada)
      Chat.change(run, status: "approval")

      assert {:ok, found} = MCP.participant(token)
      assert found.id == ada.id
    end

    # A later turn must not revive an old turn's token: the run is named in the
    # signature, so a new run is a different token.
    test "a new turn does not revive the old turn's token", %{ada: ada, run: run} do
      token = MCP.token(ada)
      Chat.change(run, status: "finished")
      turn(ada)

      assert {:error, :expired} = MCP.participant(token)
    end
  end

  describe "what a participant may not change" do
    test "it cannot let a new participant approve its own tools", %{room: room, ada: ada} do
      assert {:error, message} =
               MCP.call(ada, "add_participant", %{
                 "name" => "linus",
                 "provider" => "claude",
                 "auto_approve" => true
               })

      assert message =~ "human"
      assert Chat.agents(room.id) |> Enum.map(& &1.name) == ["ada"]
    end

    test "nor give itself the same", %{ada: ada} do
      assert {:error, _} =
               MCP.call(ada, "update_participant", %{
                 "participant" => "ada",
                 "auto_approve" => true
               })

      refute Chat.agent!(ada.id).auto_approve
    end

    test "nor save a profile that carries it in", %{ada: ada} do
      assert {:error, _} =
               MCP.call(ada, "create_profile", %{
                 "name" => "runner",
                 "provider" => "claude",
                 "auto_approve" => true
               })

      assert {:error, _} =
               MCP.call(ada, "update_profile", %{"profile" => "runner", "auto_approve" => true})

      assert Chat.agent_profiles() == []
    end

    test "and the tools never offer it in the first place" do
      for tool <- MCP.tools() do
        refute Map.has_key?(tool.inputSchema.properties, "auto_approve")
      end
    end
  end

  describe "standing instructions" do
    test "a participant can be put on a schedule", %{room: room, ada: ada} do
      assert {:ok, text} =
               MCP.call(ada, "create_schedule", %{
                 "participant" => "ada",
                 "prompt" => "sweep the bug board",
                 "at" => "9,17:30",
                 "days" => "1,2,3,4,5"
               })

      assert text =~ "09:00, 17:30 on weekdays"
      assert [schedule] = Chat.schedules(room.id)
      assert schedule.agent_id == ada.id
      assert schedule.at == "09:00,17:30"
      assert schedule.enabled
    end

    test "but only somebody who is in the room", %{room: room, ada: ada} do
      {:ok, _} = MCP.call(ada, "create_room", %{"name" => "Docs"})

      assert {:error, message} =
               MCP.call(ada, "create_schedule", %{
                 "room" => "docs",
                 "participant" => "ada",
                 "prompt" => "sweep",
                 "at" => "09:00"
               })

      assert message =~ "ada"
      assert Chat.schedules(room.id) == []
    end

    test "a time that is not a time is refused", %{ada: ada} do
      assert {:error, message} =
               MCP.call(ada, "create_schedule", %{
                 "participant" => "ada",
                 "prompt" => "sweep",
                 "at" => "whenever"
               })

      assert message =~ "time of day"
    end

    test "switching one off is how it stops", %{room: room, ada: ada} do
      {:ok, _} =
        MCP.call(ada, "create_schedule", %{
          "participant" => "ada",
          "prompt" => "sweep",
          "at" => "09:00"
        })

      [schedule] = Chat.schedules(room.id)

      assert {:ok, text} =
               MCP.call(ada, "update_schedule", %{
                 "schedule" => to_string(schedule.id),
                 "enabled" => false
               })

      assert text =~ "switched off"
      refute Chat.schedule!(schedule.id).enabled
    end

    test "they come back readable", %{ada: ada} do
      {:ok, _} =
        MCP.call(ada, "create_schedule", %{
          "participant" => "ada",
          "prompt" => "sweep the bug board",
          "at" => "09:00"
        })

      assert {:ok, json} = MCP.call(ada, "list_schedules", %{})
      assert [listed] = Jason.decode!(json)

      assert listed["participant"] == "ada"
      assert listed["when"] == "09:00 every day"
      assert listed["last_run_at"] == nil
    end
  end

  describe "wiring into a provider" do
    alias Roundtable.Agents.Protocol

    test "claude is given the server on the command line, and the token is not", %{ada: ada} do
      {"claude", args} = Protocol.command(ada)
      pairs = Enum.chunk_every(args, 2, 1)

      assert [_flag, config] = Enum.find(pairs, &match?(["--mcp-config", _], &1))
      server = Jason.decode!(config)["mcpServers"]["roundtable"]

      assert server["url"] == "http://127.0.0.1:4002/mcp"
      # Named, not written: an argument list is world-readable through /proc.
      assert server["headers"]["Authorization"] == "Bearer ${ROUNDTABLE_MCP_TOKEN}"

      assert {~c"ROUNDTABLE_MCP_TOKEN", token} = token_in(Protocol.env(ada))
      assert {:ok, %{id: id}} = token |> to_string() |> MCP.participant()
      assert id == ada.id
    end

    test "and no provider is given it any other way", %{room: room, ada: ada} do
      {:ok, codex} = Chat.create_agent(room.id, %{"name" => "linus", "provider" => "codex"})

      for agent <- [ada, codex] do
        {_executable, args} = Protocol.command(agent)
        {_variable, token} = token_in(Protocol.env(agent))

        refute Enum.any?(args, &String.contains?(&1, to_string(token)))
      end
    end

    test "codex takes its overrides before the subcommand, and its token from the environment",
         %{room: room} do
      {:ok, codex} = Chat.create_agent(room.id, %{"name" => "linus", "provider" => "codex"})
      turn(codex)
      {"codex", args} = Protocol.command(codex)

      assert List.last(args) == "app-server"
      assert Enum.any?(args, &(&1 =~ "mcp_servers.roundtable.url="))
      assert Enum.any?(args, &(&1 =~ "bearer_token_env_var=\"ROUNDTABLE_MCP_TOKEN\""))
      refute Enum.any?(args, &(&1 =~ "Bearer"))

      assert {~c"ROUNDTABLE_MCP_TOKEN", token} = token_in(Protocol.env(codex))
      assert {:ok, _} = token |> to_string() |> MCP.participant()
      refute Enum.any?(args, &String.contains?(&1, to_string(token)))
    end

    test "a provider with no way to say no is given nothing", %{room: room} do
      {:ok, opencode} = Chat.create_agent(room.id, %{"name" => "otto", "provider" => "opencode"})

      refute MCP.offered?(opencode)
      assert {"opencode", ["run", "--format", "json"]} = Protocol.command(opencode)
      assert token_in(Protocol.env(opencode)) == nil
    end

    # It is given no token, but it is still scrubbed: a provider the rooms are
    # closed to is no more entitled to this node's cookie than one they are
    # open to. This is the branch the scrub used to sit inside and skip.
    test "a provider with no tools is scrubbed all the same", %{room: room} do
      {:ok, opencode} = Chat.create_agent(room.id, %{"name" => "otto", "provider" => "opencode"})

      System.put_env("RELEASE_COOKIE", "a-real-cookie")
      on_exit(fn -> System.delete_env("RELEASE_COOKIE") end)

      assert {~c"RELEASE_COOKIE", false} in Protocol.env(opencode)
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
