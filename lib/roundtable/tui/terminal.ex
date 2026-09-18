defmodule Roundtable.TUI.Terminal do
  @moduledoc """
  Terminal control through the runtime's own tty driver.

  Shelling out to `stty` cannot work here: the BEAM starts every spawned
  process in a new session, so a child has no controlling terminal and
  `/dev/tty` fails with ENXIO. OTP owns the terminal instead —
  `shell:start_interactive/1` switches it to raw mode, and `:io.rows/0` and
  `:io.columns/0` report the current size — all without leaving the VM.
  """

  @default_size {24, 80}

  @doc """
  Puts the terminal in raw mode, so keys arrive unbuffered and unechoed.

  Returns `{:error, reason}` when there is no terminal, which is how a piped
  or redirected invocation is detected.
  """
  def raw_mode do
    case :shell.start_interactive({:noshell, :raw}) do
      :ok -> :ok
      {:error, :already_started} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the terminal to line mode."
  def restore do
    :shell.start_interactive({:noshell, :cooked})
    :ok
  catch
    _, _ -> :ok
  end

  @doc "Current `{rows, columns}`, falling back to a sane default."
  def size do
    with {:ok, rows} when rows > 0 <- :io.rows(),
         {:ok, cols} when cols > 0 <- :io.columns() do
      {rows, cols}
    else
      _ -> @default_size
    end
  end

  def enter_screen, do: write("\e[?1049h\e[?25l")
  def leave_screen, do: write("\e[?1049l\e[?25h\e[0m")
  def write(data), do: IO.binwrite(:stdio, data)

  @doc """
  Reads one byte from the terminal, or `:eof`.

  The device is a parameter so the decoder can be driven from a string in
  tests; nothing but a test passes anything other than `:stdio`.
  """
  def read_byte(device \\ :stdio) do
    case IO.binread(device, 1) do
      byte when is_binary(byte) -> byte
      _ -> :eof
    end
  end

  @doc "Switches stdio to binary so escape sequences arrive byte by byte."
  def configure_io, do: :io.setopts(:standard_io, binary: true, encoding: :latin1)
end
