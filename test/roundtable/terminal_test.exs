defmodule Roundtable.TerminalTest do
  @moduledoc """
  A real shell on a real pty, driven from a test.

  The pty is the whole point: a shell without one has no job control, no
  curses and no line editing. These check that it is genuinely a terminal and
  that it cannot outlive the page showing it.
  """
  use ExUnit.Case, async: false

  alias Roundtable.Terminal

  @moduletag timeout: 30_000

  setup do
    directory = Path.join(System.tmp_dir!(), "rt-term-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  defp type(terminal, text), do: Terminal.input(terminal, Base.encode64(text))

  # Terminal output arrives in whatever chunks the pty feels like, and an
  # interactive shell echoes what it was sent — so the pattern has to be
  # something only the command's own output can produce.
  defp await_output(matching, acc \\ "") do
    receive do
      {:terminal_output, data} ->
        acc = acc <> Base.decode64!(data)
        if acc =~ matching, do: acc, else: await_output(matching, acc)
    after
      10_000 -> flunk("never saw #{inspect(matching)}; got: #{inspect(acc)}")
    end
  end

  test "runs a shell in the directory it was given", %{directory: directory} do
    {:ok, terminal} = Terminal.start_link(owner: self(), directory: directory)

    type(terminal, "pwd\n")
    output = await_output(~r/rt-term-/)

    assert output =~ Path.basename(directory)
  end

  test "commands see the directory's contents", %{directory: directory} do
    File.write!(Path.join(directory, "hello.txt"), "hi")
    {:ok, terminal} = Terminal.start_link(owner: self(), directory: directory)

    type(terminal, "ls\n")
    assert await_output(~r/hello\.txt/) =~ "hello.txt"
  end

  test "it is a terminal, not a pipe", %{directory: directory} do
    {:ok, terminal} = Terminal.start_link(owner: self(), directory: directory)

    # A shell on a pipe reports "not a tty" here.
    type(terminal, "tty\n")
    output = await_output(~r"(/dev/|not a tty)")

    refute output =~ "not a tty"
    assert output =~ "/dev/"
  end

  test "the pty is told how big the window is", %{directory: directory} do
    {:ok, terminal} = Terminal.start_link(owner: self(), directory: directory)
    Terminal.resize(terminal, 30, 100)

    type(terminal, "stty size\n")
    assert await_output(~r/30 100/) =~ "30 100"
  end

  test "a nonsense size is ignored rather than crashing the pty", %{directory: directory} do
    {:ok, terminal} = Terminal.start_link(owner: self(), directory: directory)

    Terminal.resize(terminal, 0, 0)
    Terminal.resize(terminal, -5, 10)

    type(terminal, "echo still here\n")
    assert await_output(~r/still here/) =~ "still here"
    assert Process.alive?(terminal)
  end

  test "exiting the shell tells the owner", %{directory: directory} do
    {:ok, terminal} = Terminal.start_link(owner: self(), directory: directory)

    type(terminal, "exit 3\n")
    assert_receive {:terminal_exit, _status}, 10_000

    # It stops rather than lingering with a dead shell behind it.
    Process.sleep(100)
    refute Process.alive?(terminal)
  end

  test "it dies with the page that opened it", %{directory: directory} do
    test = self()

    owner =
      spawn(fn ->
        {:ok, terminal} = Terminal.start_link(owner: self(), directory: directory)
        send(test, {:terminal, terminal})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:terminal, terminal}
    ref = Process.monitor(terminal)

    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^terminal, _}, 5_000
  end

  test "the shell process goes with it", %{directory: directory} do
    {:ok, terminal} = Terminal.start_link(owner: self(), directory: directory)

    type(terminal, "echo pid=$$\n")
    output = await_output(~r/pid=\d+\r/)
    [_, shell_pid] = Regex.run(~r/pid=(\d+)\r/, output)

    GenServer.stop(terminal, :normal)
    Process.sleep(300)

    # No process left holding the pty open.
    assert {_, 1} = System.cmd("kill", ["-0", shell_pid], stderr_to_stdout: true)
  end

  test "a directory that does not exist is refused" do
    # start_link links, so a refusing init sends this process an exit signal.
    Process.flag(:trap_exit, true)

    assert {:error, :no_terminal} =
             Terminal.start_link(owner: self(), directory: "/nowhere-at-all")
  end
end
