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

  test "a reply is rendered as markdown, not shown as markup" do
    body = "## Heading\n\n- a bullet\n\n```elixir\ncode()\n```\n\ntail"

    drawn =
      state(messages: [message(1, "ada", body, "agent")], size: {30, 110})
      |> screen()
      |> Enum.join("\n")

    assert drawn =~ "Heading"
    refute drawn =~ "## Heading"

    assert drawn =~ "• a bullet"
    refute drawn =~ "- a bullet"

    assert drawn =~ "code()"
    refute drawn =~ "```"
  end

  test "a message never breaks a word in half" do
    body = "the rounding is fine but the test does not cover the boundary case"
    lines = state(messages: [message(1, "ada", body, "agent")], size: {30, 90}) |> screen()

    text = lines |> Enum.map(&String.trim/1) |> Enum.join("\n")
    refute text =~ ~r/\bbounda\n/
    assert text =~ "boundary"
  end

  test "wraps a message across lines instead of truncating it" do
    body = String.duplicate("abcde ", 30)

    transcript =
      state(messages: [message(1, "ada", body, "agent")])
      |> screen()
      |> Enum.drop(-4)
      |> Enum.join("\n")

    assert transcript =~ "abcde"
    refute transcript =~ "…", "a wrapped body should not need an ellipsis"
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

  defp changes(entries, extra \\ []) do
    Enum.into(extra, %{
      directory: "/srv/checkout",
      branch: "main",
      entries: entries,
      added: Enum.sum(Enum.map(entries, & &1.added)),
      removed: Enum.sum(Enum.map(entries, & &1.removed))
    })
  end

  defp entry(status, path, added \\ 0, removed \\ 0),
    do: %{status: status, path: path, added: added, removed: removed}

  test "the changes pane keeps the frame exactly the size of the terminal" do
    state =
      state(
        changes:
          changes([
            entry("M", "lib/parser.ex", 42, 7),
            entry("A", "test/parser_test.exs", 88),
            entry("??", "scratch.md")
          ])
      )

    for size <- [{24, 80}, {40, 120}, {8, 40}] do
      {rows, cols} = size
      lines = screen(%{state | size: size})
      assert length(lines) == rows

      for {line, index} <- Enum.with_index(lines) do
        assert String.length(line) == cols, "row #{index} at #{inspect(size)}"
      end
    end
  end

  test "shows the branch, each change and a summary" do
    screen =
      state(changes: changes([entry("M", "lib/parser.ex", 42, 7), entry("??", "scratch.md")]))
      |> screen()
      |> Enum.join("\n")

    assert screen =~ "changes · main"
    assert screen =~ "M lib/parser.ex"
    assert screen =~ "+42 -7"
    assert screen =~ "?? scratch.md"
    assert screen =~ "2 files, +42 -7"
  end

  test "says so when the tree is clean" do
    screen = state(changes: changes([])) |> screen() |> Enum.join("\n")
    assert screen =~ "working tree clean"
  end

  test "surfaces a git error in place of the pane" do
    screen = state(changes: {:error, "not a git repository"}) |> screen() |> Enum.join("\n")
    assert screen =~ "not a git repository"
  end

  test "hidden when toggled off, and before the first poll" do
    refute state(changes: changes([entry("M", "a.ex", 1, 1)]), changes_visible: false)
           |> screen()
           |> Enum.join("\n") =~ "changes · main"

    refute state(changes: nil) |> screen() |> Enum.join("\n") =~ "changes · main"
  end

  test "long paths are cut from the left, keeping the file name" do
    long = "lib/" <> String.duplicate("deeply/nested/", 12) <> "target.ex"
    screen = state(changes: changes([entry("M", long, 1, 1)])) |> screen() |> Enum.join("\n")

    assert screen =~ "target.ex"
    refute screen =~ "lib/deeply/nested/deeply"
  end

  test "caps the pane and counts what it could not show" do
    entries = for n <- 1..40, do: entry("M", "file#{n}.ex", n, 1)
    lines = state(changes: changes(entries)) |> screen()

    assert Enum.join(lines, "\n") =~ ~r/and \d+ more/
    assert length(lines) == 24
  end

  test "the roster shows every participant and keeps the frame intact" do
    agents = [
      %Agent{
        id: 7,
        name: "ada",
        provider: "codex",
        model: "gpt-5-codex",
        cost_tier: "economy",
        role: "implement only"
      },
      %Agent{
        id: 8,
        name: "linus",
        provider: "claude",
        model: nil,
        cost_tier: "premium",
        role: nil
      }
    ]

    state = state(agents: agents, roster_visible: true)

    for size <- [{24, 80}, {40, 120}, {8, 40}] do
      {rows, cols} = size
      lines = screen(%{state | size: size})
      assert length(lines) == rows
      for line <- lines, do: assert(String.length(line) == cols)
    end

    screen = state |> screen() |> Enum.join("\n")
    assert screen =~ "participants · 2"
    assert screen =~ "@ada"
    assert screen =~ "gpt-5-codex"
    assert screen =~ "economy"
    assert screen =~ "implement only"
    assert screen =~ "@linus"
    assert screen =~ "provider default"
    assert screen =~ "no role set"
  end

  test "the roster replaces the transcript while it is open" do
    state = state(messages: [message(1, "you", "a message in the transcript")])

    assert screen(state) |> Enum.join("\n") =~ "a message in the transcript"

    refute screen(%{state | roster_visible: true}) |> Enum.join("\n") =~
             "a message in the transcript"
  end

  test "an empty roster says how to add someone" do
    screen = state(agents: [], roster_visible: true) |> screen() |> Enum.join("\n")
    assert screen =~ "No participants yet"
  end

  test "the palette is drawn above the input, and the frame survives it" do
    state = state(input: "/re", mode: :command)

    for size <- [{24, 80}, {40, 120}, {10, 44}] do
      {rows, cols} = size
      lines = screen(%{state | size: size})
      assert length(lines) == rows
      for line <- lines, do: assert(String.length(line) == cols)
    end

    # Wide enough that the description column is not elided.
    drawn = %{state | size: {30, 120}} |> screen() |> Enum.join("\n")
    assert drawn =~ "commands"
    assert drawn =~ "/rename <agent> <new>"
    assert drawn =~ "rename one, before its first turn"
    assert drawn =~ "▸"
  end

  test "the palette is absent for an ordinary message" do
    refute state(input: "hello there") |> screen() |> Enum.join("\n") =~ "─ commands"
  end

  test "help lists every command and keeps the frame intact" do
    state = state(help_visible: true)

    for size <- [{24, 80}, {40, 120}, {8, 40}] do
      {rows, cols} = size
      lines = screen(%{state | size: size})
      assert length(lines) == rows
      for line <- lines, do: assert(String.length(line) == cols)
    end

    # Tall enough to hold every entry at once; scrolling is its own test.
    screen = %{state | size: {60, 100}} |> screen() |> Enum.join("\n")

    assert screen =~ "how to use Roundtable"

    for command <- ~w(/who /agent /role /model /rename /remove /remove-room /providers /models
                      /stop /reset /retry /approve /rooms /room /new-room /ask /delegate
                      /changes /lazygit /quit) do
      assert screen =~ command, "help does not mention #{command}"
    end

    for key <- ["Tab", "^P", "^T", "^G", "^L", "Esc", "^C"] do
      assert screen =~ key, "help does not mention #{key}"
    end
  end

  test "help scrolls when it does not fit, and says so" do
    short = state(help_visible: true, size: {24, 80})
    assert screen(short) |> Enum.join("\n") =~ "↑↓ for more"

    scrolled = screen(%{short | scroll: 10}) |> Enum.join("\n")
    refute scrolled =~ "Talking", "scrolling did not move the help"
  end

  test "help replaces the transcript and takes precedence over the roster" do
    state = state(messages: [message(1, "you", "a message in the transcript")])

    refute screen(%{state | help_visible: true}) |> Enum.join("\n") =~
             "a message in the transcript"

    both = %{state | help_visible: true, roster_visible: true}
    assert screen(both) |> Enum.join("\n") =~ "how to use Roundtable"
  end

  test "counts the pane that is actually showing, for scroll clamping" do
    assert Render.total_lines(state(help_visible: true)) > 20
  end

  test "counts transcript lines for scroll clamping" do
    assert Render.total_lines(state(messages: [])) == 0
    assert Render.total_lines(state()) == 1

    assert Render.total_lines(state(messages: [message(1, "ada", String.duplicate("x", 200))])) >
             1
  end
end
