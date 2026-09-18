defmodule Roundtable.TUI.StateTest do
  use ExUnit.Case, async: true
  alias Roundtable.Chat.{Agent, Room, Run}
  alias Roundtable.TUI.State

  defp state(attrs \\ []) do
    defaults = [
      rooms: [%Room{id: 1, name: "Checkout", directory: "/tmp"}],
      room: %Room{id: 1, name: "Checkout", directory: "/tmp"},
      agents: [%Agent{id: 7, name: "ada"}, %Agent{id: 8, name: "tester"}]
    ]

    State.new(Keyword.merge(defaults, attrs))
  end

  defp type(state, text) do
    text
    |> String.graphemes()
    |> Enum.reduce(state, fn char, acc ->
      {acc, []} = State.handle_key(acc, {:char, char})
      acc
    end)
  end

  test "typing and editing the input line" do
    state = state() |> type("hello")
    assert state.input == "hello"
    assert state.cursor == 5

    {state, []} = State.handle_key(state, :backspace)
    assert state.input == "hell"

    {state, []} = State.handle_key(state, :home)
    {state, []} = State.handle_key(state, {:char, "s"})
    assert state.input == "shell"
    assert state.cursor == 1

    {state, []} = State.handle_key(state, :ctrl_u)
    assert state.input == "hell"
    assert state.cursor == 0
  end

  test "enter posts a message and clears the line" do
    {state, effects} = state() |> type("@ada ship it") |> State.handle_key(:enter)

    assert effects == [{:post, "@ada ship it"}]
    assert state.input == ""
    assert state.cursor == 0
  end

  test "an empty line does nothing" do
    assert {_, []} = State.handle_key(state(), :enter)
  end

  test "tab cycles the recipient and keeps what was typed" do
    {state, []} = state() |> type("ship it") |> State.handle_key(:tab)
    assert state.input == "@ada ship it"

    {state, []} = State.handle_key(state, :tab)
    assert state.input == "@tester ship it"

    {state, []} = State.handle_key(state, :tab)
    assert state.input == "@ada ship it"
  end

  test "input starting with a slash switches the prompt to command mode" do
    state = state() |> type("/help")
    assert state.mode == :command

    {state, []} = State.handle_key(state, :enter)
    assert state.mode == :message
    assert state.help_visible
  end

  test "help opens from a command, from ? on an empty line, and closes with Esc" do
    {from_command, []} = state() |> type("/help") |> State.handle_key(:enter)
    assert from_command.help_visible

    {from_key, []} = State.handle_key(state(), {:char, "?"})
    assert from_key.help_visible

    {closed, []} = State.handle_key(from_key, :escape)
    refute closed.help_visible

    {toggled, []} = State.handle_key(from_key, {:char, "?"})
    refute toggled.help_visible
  end

  test "a question mark mid-sentence is just a question mark" do
    state = state() |> type("does this work?")

    assert state.input == "does this work?"
    refute state.help_visible
  end

  test "Esc closes help before it clears the line" do
    state = state() |> type("kept")
    {state, []} = State.handle_key(%{state | help_visible: true}, :escape)

    refute state.help_visible
    assert state.input == "kept"
  end

  test "switching rooms by name, case, or id" do
    for typed <- ["Checkout", "checkout", "1"] do
      {_, effects} = state() |> type("/room #{typed}") |> State.handle_key(:enter)
      assert effects == [{:switch_room, 1}]
    end

    {state, effects} = state() |> type("/room nope") |> State.handle_key(:enter)
    assert effects == []
    assert state.status =~ "No room called nope"
  end

  test "creating rooms and agents" do
    {_, effects} = state() |> type("/new-room Infra /srv/infra") |> State.handle_key(:enter)
    assert effects == [{:create_room, "Infra", "/srv/infra"}]

    # A team's name usually has a space in it; the path is the last token.
    {_, effects} =
      state() |> type("/new-room Design Team /srv/design") |> State.handle_key(:enter)

    assert effects == [{:create_room, "Design Team", "/srv/design"}]

    # A relative path is passed through; the client resolves it against the
    # shell it is running in, which is where the person actually is.
    for path <- [".", "./web", "../sibling", "~/projects/web"] do
      {_, effects} = state() |> type("/new-room Web #{path}") |> State.handle_key(:enter)
      assert effects == [{:create_room, "Web", path}]
    end

    {state, []} = state() |> type("/new-room NoPath") |> State.handle_key(:enter)
    assert state.status =~ "Usage: /new-room"

    {_, effects} = state() |> type("/agent bob codex") |> State.handle_key(:enter)
    assert [{:create_agent, attrs}] = effects
    assert attrs == %{"name" => "bob", "provider" => "codex"}

    # A participant works in its room's directory; there is nothing to pass.
    refute Map.has_key?(attrs, "directory")

    {state, []} = state() |> type("/agent bob gpt") |> State.handle_key(:enter)
    assert state.status =~ "Unknown provider gpt"
  end

  test "stop and reset resolve an agent name to its id" do
    {_, effects} = state() |> type("/stop ada") |> State.handle_key(:enter)
    assert effects == [{:stop, 7}]

    {state, []} = state() |> type("/stop ghost") |> State.handle_key(:enter)
    assert state.status =~ "Usage: /stop"
  end

  test "retry picks the newest failed run when none is named" do
    runs = [
      %Run{id: 3, agent_id: 7, status: "failed"},
      %Run{id: 2, agent_id: 7, status: "completed"}
    ]

    {_, effects} = state(runs: runs) |> type("/retry") |> State.handle_key(:enter)
    assert effects == [{:retry, 3}]

    {_, effects} = state(runs: runs) |> type("/retry 2") |> State.handle_key(:enter)
    assert effects == [{:retry, 2}]

    {state, []} = state() |> type("/retry") |> State.handle_key(:enter)
    assert state.status =~ "No failed run"
  end

  test "approve targets the numbered pending approval" do
    approvals = [
      %{run_id: 1, request_id: "a", agent: "ada", room_id: 1, params: %{}},
      %{run_id: 2, request_id: "b", agent: "tester", room_id: 1, params: %{}}
    ]

    {_, effects} =
      state(approvals: approvals) |> type("/approve accept") |> State.handle_key(:enter)

    assert effects == [{:approve, 1, "a", "accept"}]

    {_, effects} =
      state(approvals: approvals) |> type("/approve decline 2") |> State.handle_key(:enter)

    assert effects == [{:approve, 2, "b", "decline"}]

    {state, []} =
      state(approvals: approvals) |> type("/approve accept 9") |> State.handle_key(:enter)

    assert state.status =~ "No approval #9"
  end

  test "context shows the room's brief and sets it" do
    {state, []} = state() |> type("/context") |> State.handle_key(:enter)
    assert state.status =~ "No shared brief yet"

    with_brief =
      state(room: %Room{id: 1, name: "Checkout", directory: "/tmp", context: "Ship it"})

    {shown, []} = with_brief |> type("/context") |> State.handle_key(:enter)
    assert shown.status =~ "Room brief: Ship it"

    {_, effects} = state() |> type("/context Elixir and Phoenix") |> State.handle_key(:enter)
    assert effects == [{:update_room, 1, %{"context" => "Elixir and Phoenix"}}]
  end

  test "auto switches a participant's tool approvals, and says how when it cannot" do
    {_, effects} = state() |> type("/auto ada on") |> State.handle_key(:enter)
    assert effects == [{:update_agent, 7, %{"auto_approve" => true}}]

    {_, effects} = state() |> type("/auto ada off") |> State.handle_key(:enter)
    assert effects == [{:update_agent, 7, %{"auto_approve" => false}}]

    {state, []} = state() |> type("/auto ada maybe") |> State.handle_key(:enter)
    assert state.status =~ "Usage: /auto"

    {state, []} = state() |> type("/auto nobody on") |> State.handle_key(:enter)
    assert state.status =~ "nobody"
  end

  test "the one-line command dump is gone; /help is the full screen" do
    {state, []} = state() |> type("/commands") |> State.handle_key(:enter)

    assert state.status =~ "Unknown command /commands"
    refute state.help_visible
  end

  test "unknown commands explain themselves" do
    {state, []} = state() |> type("/frobnicate") |> State.handle_key(:enter)
    assert state.status =~ "Unknown command /frobnicate"
  end

  test "/agent takes a model, a role and a tier as flags" do
    {_, effects} =
      state()
      |> type(~s(/agent builder codex --model gpt-5-codex --role implement only --tier economy))
      |> State.handle_key(:enter)

    assert [{:create_agent, attrs}] = effects
    assert attrs["name"] == "builder"
    assert attrs["model"] == "gpt-5-codex"
    assert attrs["role"] == "implement only"
    assert attrs["cost_tier"] == "economy"
  end

  test "a quoted role keeps its spaces and loses its quotes" do
    {_, effects} =
      state()
      |> type(~s(/agent critic claude --role "review diffs for correctness"))
      |> State.handle_key(:enter)

    assert [{:create_agent, %{"role" => "review diffs for correctness"}}] = effects
  end

  test "/role sets a role on an existing agent" do
    {_, effects} =
      state() |> type("/role ada plan only, never write code") |> State.handle_key(:enter)

    assert [{:update_agent, 7, %{"role" => "plan only, never write code"}}] = effects

    {state, []} = state() |> type("/role ghost anything") |> State.handle_key(:enter)
    assert state.status =~ "No agent called ghost"

    {state, []} = state() |> type("/role ada") |> State.handle_key(:enter)
    assert state.status =~ "Usage: /role"
  end

  test "/model pins a model, and default hands it back to the provider" do
    {_, effects} = state() |> type("/model ada gpt-5-codex") |> State.handle_key(:enter)
    assert [{:update_agent, 7, %{"model" => "gpt-5-codex"}}] = effects

    {_, effects} = state() |> type("/model ada default") |> State.handle_key(:enter)
    assert [{:update_agent, 7, %{"model" => nil}}] = effects
  end

  describe "the command palette" do
    test "opens on a slash and narrows as you type" do
      assert length(State.palette(state() |> type("/"))) > 10

      names = state() |> type("/rem") |> State.palette() |> Enum.map(&elem(&1, 0))
      assert "remove" in names
      assert "remove-room" in names
      refute "who" in names
    end

    test "closes once the command is complete and an argument is started" do
      assert State.palette(state() |> type("/who")) != []
      assert State.palette(state() |> type("/who ")) == []
      assert State.palette(state() |> type("/role ada plan")) == []
    end

    test "a plain message never opens it" do
      assert State.palette(state() |> type("hello")) == []
      assert State.palette(state() |> type("@ada hello")) == []
    end

    test "up and down choose, and wrap" do
      state = state() |> type("/ro")
      [first, second | _] = State.palette(state)

      assert State.selected(state) == first

      {state, []} = State.handle_key(state, :down)
      assert State.selected(state) == second

      {state, []} = State.handle_key(state, :up)
      assert State.selected(state) == first

      # Wrapping backwards from the first lands on the last.
      {state, []} = State.handle_key(state, :up)
      assert State.selected(state) == List.last(State.palette(state))
    end

    test "up and down still scroll when it is closed" do
      state = state(messages: [], size: {24, 80}) |> type("plain text")
      {state, []} = State.handle_key(state, :up)

      assert state.scroll == 0
      assert State.palette(state) == []
    end

    test "tab completes as far as the matches agree" do
      # remove and remove-room share "remove" and no more.
      {state, []} = state() |> type("/rem") |> State.handle_key(:tab)
      assert state.input == "/remove"

      # One match completes fully and adds the space.
      {state, []} = state() |> type("/who") |> State.handle_key(:tab)
      assert state.input == "/who "
      assert State.palette(state) == []
    end

    test "tab still cycles the recipient for a plain message" do
      {state, []} = state() |> type("ship it") |> State.handle_key(:tab)
      assert state.input == "@ada ship it"
    end

    test "enter takes the highlighted command, filling in what needs an argument" do
      # "/rem" is not a command; the highlighted one is, and it needs a name.
      state = state() |> type("/rem")
      assert {"remove", _, _} = State.selected(state)

      {state, effects} = State.handle_key(state, :enter)
      assert effects == []
      assert state.input == "/remove "

      # Now the name, and it runs.
      {_, effects} = state |> type("ada") |> State.handle_key(:enter)
      assert effects == [{:remove_agent, 7, "ada"}]
    end

    test "enter runs a command that needs nothing, straight away" do
      state = state() |> type("/wh")
      assert {"who", _, _} = State.selected(state)

      {state, []} = State.handle_key(state, :enter)
      assert state.roster_visible
      assert state.input == ""
    end

    test "arrowing down takes the other match" do
      state = state() |> type("/rem")
      {state, []} = State.handle_key(state, :down)

      assert {"remove-room", _, _} = State.selected(state)

      {state, []} = State.handle_key(state, :enter)
      assert state.input == "/remove-room "
    end

    test "the selection stays in range as the list shrinks" do
      state = state() |> type("/r")
      {state, []} = State.handle_key(state, :down)
      {state, []} = State.handle_key(state, :down)
      {state, []} = State.handle_key(state, :down)

      # Narrowing to one match must not leave the selection past the end.
      state = type(state, "efresh")
      assert [{"refresh", _, _}] = State.palette(state)
      assert {"refresh", _, _} = State.selected(state)
    end
  end

  test "/remove takes an exact name, because there is no undo" do
    {_, effects} = state() |> type("/remove ada") |> State.handle_key(:enter)
    assert effects == [{:remove_agent, 7, "ada"}]

    {state, []} = state() |> type("/remove ad") |> State.handle_key(:enter)
    assert state.status =~ "No agent called ad"
  end

  test "/remove-room needs the room's name spelled out" do
    {_, effects} = state() |> type("/remove-room Checkout") |> State.handle_key(:enter)
    assert effects == [{:remove_room, 1, "Checkout"}]

    # Not an id, not a prefix, not a different case: typing it is the confirmation.
    for typed <- ["1", "check", "checkout"] do
      {state, effects} = state() |> type("/remove-room #{typed}") |> State.handle_key(:enter)
      assert effects == []
      assert state.status =~ "Type the room's name exactly"
    end
  end

  test "/rename changes what a participant is called" do
    {_, effects} = state() |> type("/rename ada ada-2") |> State.handle_key(:enter)
    assert effects == [{:update_agent, 7, %{"name" => "ada-2"}}]

    {state, []} = state() |> type("/rename ada") |> State.handle_key(:enter)
    assert state.status =~ "Usage: /rename"
  end

  test "ctrl-p and /who toggle the roster, and Esc closes it" do
    {state, []} = State.handle_key(state(), :ctrl_p)
    assert state.roster_visible

    {state, []} = State.handle_key(state, :ctrl_p)
    refute state.roster_visible

    {state, []} = state |> type("/who") |> State.handle_key(:enter)
    assert state.roster_visible

    # Esc closes the roster before it clears the message line.
    {state, []} = State.handle_key(%{state | input: "kept"}, :escape)
    refute state.roster_visible
    assert state.input == "kept"
  end

  test "ctrl-t toggles the changes pane" do
    {state, []} = State.handle_key(state(), :ctrl_t)
    refute state.changes_visible

    {state, []} = State.handle_key(state, :ctrl_t)
    assert state.changes_visible
  end

  test "ctrl-g asks for the git UI" do
    assert {_, [:git_ui]} = State.handle_key(state(), :ctrl_g)
    {_, effects} = state() |> type("/lazygit") |> State.handle_key(:enter)
    assert effects == [:git_ui]
  end

  test "/changes shows or hides the pane" do
    {state, []} = state() |> type("/changes off") |> State.handle_key(:enter)
    refute state.changes_visible

    {state, []} = state |> type("/changes") |> State.handle_key(:enter)
    assert state.changes_visible
  end

  test "the watched directory is the room's" do
    assert State.watched_directory(state()) == "/tmp"
    assert State.watched_directory(%{state() | room: nil}) == nil
  end

  test "ctrl-c quits" do
    assert {%{quit: true}, [:quit]} = State.handle_key(state(), :ctrl_c)
  end

  test "scrolling never leaves the transcript" do
    {state, []} = State.handle_key(state(), :down)
    assert state.scroll == 0

    {state, []} = State.handle_key(state, :page_up)
    assert state.scroll == 0, "an empty room has nothing to scroll"
  end

  test "agent status mirrors the web UI" do
    runs = [%Run{id: 1, agent_id: 7, status: "running"}]
    assert State.agent_status(%Agent{id: 7}, runs) == "running"
    assert State.agent_status(%Agent{id: 8}, runs) == "idle"
  end
end
