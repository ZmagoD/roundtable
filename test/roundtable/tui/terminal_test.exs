defmodule Roundtable.TUI.TerminalTest do
  @moduledoc """
  The suite runs without a controlling terminal, which is exactly the situation
  these paths exist for: a client that is piped, redirected, or run from CI has
  to say so rather than corrupt the caller's terminal settings.
  """
  use ExUnit.Case, async: false

  alias Roundtable.TUI.Terminal

  test "raw mode reports failure when there is no terminal to put into it" do
    assert {:error, _reason} = Terminal.raw_mode()
  end

  test "restoring is safe even when raw mode was never entered" do
    assert Terminal.restore() == :ok
    assert Terminal.restore() == :ok
  end

  test "size falls back to a usable default rather than crashing" do
    assert {rows, cols} = Terminal.size()
    assert is_integer(rows) and rows > 0
    assert is_integer(cols) and cols > 0
  end

  test "screen control writes the sequences a terminal expects" do
    assert capture_io(fn -> Terminal.enter_screen() end) =~ "\e[?1049h"
    assert capture_io(fn -> Terminal.enter_screen() end) =~ "\e[?25l"

    left = capture_io(fn -> Terminal.leave_screen() end)
    assert left =~ "\e[?1049l"
    assert left =~ "\e[?25h"
    assert left =~ "\e[0m"
  end

  test "write puts exactly what it is given on the device" do
    assert capture_io(fn -> Terminal.write("plain") end) == "plain"
    assert capture_io(fn -> Terminal.write(["io", "data"]) end) == "iodata"
  end

  # configure_io/0 is deliberately not tested: it calls :io.setopts on the VM's
  # real standard_io, and doing that mid-suite breaks ExUnit's own IO capture
  # for every test that runs afterwards. It is exercised against a real pty.

  test "reading returns one byte at a time, then :eof" do
    {:ok, device} = StringIO.open("ab")

    assert Terminal.read_byte(device) == "a"
    assert Terminal.read_byte(device) == "b"
    assert Terminal.read_byte(device) == :eof
  end

  test "a multi-byte character arrives one byte at a time, as the decoder expects" do
    {:ok, device} = StringIO.open("é")

    bytes = for _ <- 1..byte_size("é"), do: Terminal.read_byte(device)

    assert IO.iodata_to_binary(bytes) == "é"
    assert Terminal.read_byte(device) == :eof
  end

  defp capture_io(fun), do: ExUnit.CaptureIO.capture_io(fun)
end
