defmodule Roundtable.TUI.SessionTest do
  @moduledoc """
  The terminal client, end to end, on a real pty.

  Everything else about the client is tested without a terminal: keys decode,
  state transitions, rendering, and each effect against a live context. What
  none of that reaches is the part that only exists because there is a
  terminal — raw mode, the reader process, the redraw loop, and restoring the
  screen on the way out. A pipe will not do: the client asks the runtime's tty
  driver for raw mode, and without a terminal to own, it refuses to start.

  Tagged `:pty` and excluded from the default run because it boots a second
  VM and takes a few seconds. CI runs it as its own step.
  """
  use ExUnit.Case, async: false

  @moduletag :pty
  @moduletag timeout: 180_000

  @driver Path.expand("../../support/pty_drive.py", __DIR__)

  setup do
    directory = Path.join(System.tmp_dir!(), "rt-session-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    database = Path.join(directory, "session.db")

    {_, 0} =
      System.cmd("mix", ["ecto.migrate"],
        env: [{"DATABASE_PATH", database}, {"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory, database: database}
  end

  defp drive(script, database, opts \\ []) do
    {output, _status} =
      System.cmd(
        "python3",
        [@driver, "elixir", "--erl", "+Bc", "-S", "mix", "tui", "--local"],
        env: [
          {"DRIVE_SCRIPT", script},
          {"DRIVE_TIMEOUT", to_string(Keyword.get(opts, :timeout, 60))},
          {"DATABASE_PATH", database},
          {"MIX_ENV", "test"},
          # The runtime's tty driver will not enter raw mode for a terminal it
          # cannot identify, and CI runners leave TERM unset.
          {"TERM", "xterm-256color"}
        ],
        stderr_to_stdout: true
      )

    output
  end

  defp frames(output) do
    output
    |> String.split("\e[H\e[2J")
    |> tl()
    |> Enum.map(&String.replace(&1, ~r/\e\[[0-9;?]*[a-zA-Z]/, ""))
  end

  test "a whole session: build a room, a participant, send a message, read it back",
       %{directory: directory, database: database} do
    script =
      [
        "12:/new-room Session Room #{directory}\\r",
        "18:/agent grace opencode --role Answer questions.\\r",
        "24:hello from the pty\\r",
        "30:\\x10",
        "36:/quit\\r"
      ]
      |> Enum.join("|")

    output = drive(script, database)
    frames = frames(output)

    assert frames != [], "the client drew nothing; output was: #{String.slice(output, 0, 500)}"

    drawn = Enum.join(frames, "\n")
    assert drawn =~ "Session Room", "the room it created is not in the frame"
    assert drawn =~ "grace", "the participant it added is not in the roster"
    assert drawn =~ "hello from the pty", "the message it sent is not in the transcript"

    # ^P opened the roster, which only the real key path can produce.
    assert drawn =~ "participants · 1"
    assert drawn =~ "Answer questions."

    # The client owns the alternate screen and must give it back.
    assert String.contains?(output, "\e[?1049h"), "never entered the alternate screen"
    assert String.contains?(output, "\e[?1049l"), "left the terminal in the alternate screen"
    assert String.ends_with?(String.trim_trailing(output), "\e[?25h\e[0m")
  end

  test "^C restores the terminal as cleanly as /quit does", %{database: database} do
    output = drive("12:\\x03", database, timeout: 40)

    assert String.contains?(output, "\e[?1049h"),
           "the client never took the screen; it printed: #{String.slice(output, 0, 400)}"

    assert String.contains?(output, "\e[?1049l"), "^C left the terminal in the alternate screen"
  end

  test "the changes pane reports the repository it is pointed at", %{database: database} do
    # The checkout this suite runs from is a git repository, so the pane has
    # something real to say about it.
    script = "12:/new-room Repo #{File.cwd!()}\\r|22:/quit\\r"
    drawn = drive(script, database) |> frames() |> Enum.join("\n")

    assert drawn =~ "changes ·",
           "the changes pane never appeared; the client printed: #{String.slice(drawn, 0, 400)}"
  end

  test "it refuses to start when there is no terminal, rather than corrupting one",
       %{database: database} do
    # Its own database: --local starts the app, and a child pointed at the
    # suite's database would write outside the sandbox and corrupt other tests.
    {output, status} =
      System.cmd("elixir", ["-S", "mix", "tui", "--local"],
        env: [{"MIX_ENV", "test"}, {"DATABASE_PATH", database}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "needs a terminal"
  end
end
