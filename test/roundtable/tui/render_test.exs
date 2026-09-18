defmodule Roundtable.TUI.RenderTest do
  use ExUnit.Case, async: true
  alias Roundtable.Chat.{Agent, Message, Room, Run}
  alias Roundtable.TUI.{Render, State}

  defp screen(state) do
    state
    |> Render.render()
    |> IO.iodata_to_binary()
    |> String.replace(~r/\e\[[0-9;?]*[a-zA-Z]/, "")
    |> String.split("\n")
  end

  defp state(attrs \\ []) do
    defaults = [
      size: {24, 80},
      target: "roundtable@box",
      rooms: [%Room{id: 1, name: "Checkout", directory: "/srv/checkout"}],
      room: %Room{id: 1, name: "Checkout", directory: "/srv/checkout"},
      agents: [%Agent{id: 7, name: "ada"}],
      messages: [message(1, "you", "Check the tests")]
    ]

    State.new(Keyword.merge(defaults, attrs))
  end

  defp message(id, sender, body, kind \\ "human") do
    %Message{
      id: id,
      sender: sender,
      body: body,
      kind: kind,
      inserted_at: ~U[2026-09-18 09:12:00Z]
    }
  end

  test "the frame is exactly the size of the terminal" do
    for size <- [{24, 80}, {40, 120}, {8, 40}, {31, 97}] do
      {rows, cols} = size
      lines = screen(state(size: size))

      assert length(lines) == rows, "expected #{rows} rows at #{inspect(size)}"

      for {line, index} <- Enum.with_index(lines) do
        assert String.length(line) == cols,
               "row #{index} was #{String.length(line)} columns, expected #{cols}"
      end
    end
  end

  test "draws the room, the roster, and the transcript" do
    screen = state() |> screen() |> Enum.join("\n")

    assert screen =~ "Checkout"
    assert screen =~ "/srv/checkout"
    assert screen =~ "ada"
    assert screen =~ "09:12"
    assert screen =~ "Check the tests"
  end

  test "long values are cut rather than breaking the frame" do
    state =
      state(
        room: %Room{
          id: 1,
          name: String.duplicate("long ", 40),
          directory: "/" <> String.duplicate("d", 200)
        },
        messages: [message(1, "averyverylongsendername", String.duplicate("word ", 200))]
      )

    for line <- screen(state), do: assert(String.length(line) == 80)
  end

  test "wraps a message across lines instead of truncating it" do
    body = String.duplicate("abcde ", 30)
    screen = state(messages: [message(1, "ada", body, "agent")]) |> screen() |> Enum.join("\n")

    assert screen =~ "abcde"
    refute screen =~ "…", "a wrapped body should not need an ellipsis"
  end

  test "pending approvals are shown with the command that answers them" do
    approvals = [
      %{run_id: 1, request_id: "r1", agent: "ada", room_id: 1, params: %{"cmd" => "ls"}}
    ]

    screen = state(approvals: approvals) |> screen() |> Enum.join("\n")

    assert screen =~ "ada wants to use a tool"
    assert screen =~ "/approve accept 1"
  end

  test "failed runs surface their error" do
    runs = [
      %Run{
        id: 4,
        agent_id: 7,
        status: "failed",
        error: "Codex exited (1).",
        agent: %Agent{name: "ada"}
      }
    ]

    screen = state(runs: runs) |> screen() |> Enum.join("\n")

    assert screen =~ "run 4 ada"
    assert screen =~ "Codex exited"
  end

  test "shows the attached node, and disconnection when it drops" do
    assert state() |> screen() |> Enum.join("\n") =~ "roundtable@box"
    assert state(connected: false) |> screen() |> Enum.join("\n") =~ "disconnected"
  end

  test "a terminal too small says so instead of drawing a broken frame" do
    output = state(size: {5, 20}) |> Render.render() |> IO.iodata_to_binary()
    assert output =~ "too small"
  end

  test "counts transcript lines for scroll clamping" do
    assert Render.total_lines(state(messages: [])) == 0
    assert Render.total_lines(state()) == 1

    assert Render.total_lines(state(messages: [message(1, "ada", String.duplicate("x", 200))])) >
             1
  end
end
