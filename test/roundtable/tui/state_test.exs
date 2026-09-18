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
    assert state.status =~ "/new-room"
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

    {_, effects} = state() |> type("/agent bob codex") |> State.handle_key(:enter)

    assert [{:create_agent, %{"name" => "bob", "provider" => "codex", "directory" => nil}}] =
             effects

    {_, effects} = state() |> type("/agent bob codex /srv/x") |> State.handle_key(:enter)
    assert [{:create_agent, %{"directory" => "/srv/x"}}] = effects

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

  test "unknown commands explain themselves" do
    {state, []} = state() |> type("/frobnicate") |> State.handle_key(:enter)
    assert state.status =~ "Unknown command /frobnicate"
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

  test "/changes follows a room, an agent, or nothing" do
    {state, []} = state() |> type("/changes off") |> State.handle_key(:enter)
    refute state.changes_visible

    {state, []} = state() |> type("/changes ada") |> State.handle_key(:enter)
    assert state.changes_visible
    assert state.changes_target == "ada"

    {state, []} = state |> type("/changes room") |> State.handle_key(:enter)
    assert state.changes_target == nil

    {state, []} = state() |> type("/changes ghost") |> State.handle_key(:enter)
    assert state.status =~ "No agent called ghost"
  end

  test "the watched directory follows the target agent" do
    agents = [
      %Agent{id: 7, name: "ada", directory: "/worktrees/ada"},
      %Agent{id: 8, name: "tester", directory: nil}
    ]

    state = state(agents: agents)
    assert State.watched_directory(state) == "/tmp"
    assert State.watched_directory(%{state | changes_target: "ada"}) == "/worktrees/ada"
    # An agent without its own directory falls back to the room's.
    assert State.watched_directory(%{state | changes_target: "tester"}) == "/tmp"
    assert State.watched_directory(%{state | room: nil}) == nil
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
