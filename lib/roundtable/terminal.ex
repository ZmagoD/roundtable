defmodule Roundtable.Terminal do
  @moduledoc """
  A shell running in a room's directory, on a real pty.

  The BEAM cannot allocate a pty and starts every process it spawns in a new
  session, so a shell it launched directly would have no controlling terminal:
  no job control, no curses, no line editing. `priv/terminal_bridge.py`
  allocates one and relays bytes; this process owns that bridge and forwards
  what it prints to whoever asked for the terminal.

  It monitors its owner and exits with it. A shell that outlived the page
  showing it would be a process nobody can see and nobody can stop.
  """
  use GenServer, restart: :temporary

  require Logger

  @doc """
  Starts a shell in `directory`, sending output to `owner`.

  The owner receives `{:terminal_output, base64}` and `{:terminal_exit, status}`.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Map.new(opts))
  end

  @doc "Sends keystrokes, already base64 encoded by the browser."
  def input(terminal, data), do: GenServer.cast(terminal, {:input, data})

  @doc "Tells the pty how big the browser's window is now."
  def resize(terminal, rows, columns) when rows > 0 and columns > 0,
    do: GenServer.cast(terminal, {:resize, rows, columns})

  def resize(_terminal, _rows, _columns), do: :ok

  @impl true
  def init(%{owner: owner, directory: directory}) do
    Process.flag(:trap_exit, true)
    Process.monitor(owner)

    with python when not is_nil(python) <- System.find_executable("python3"),
         true <- File.dir?(directory) do
      bridge = Application.app_dir(:roundtable, "priv/terminal_bridge.py")

      port =
        Port.open({:spawn_executable, python}, [
          :binary,
          :exit_status,
          :use_stdio,
          args: [bridge],
          cd: directory,
          env: [{~c"TERM", ~c"xterm-256color"}]
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      {:ok, %{owner: owner, port: port, os_pid: os_pid, buffer: ""}}
    else
      _ -> {:stop, :no_terminal}
    end
  end

  @impl true
  def handle_cast({:input, data}, state) do
    Port.command(state.port, Jason.encode!(%{data: data}) <> "\n")
    {:noreply, state}
  end

  def handle_cast({:resize, rows, columns}, state) do
    Port.command(state.port, Jason.encode!(%{resize: [rows, columns]}) <> "\n")
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    parts = String.split(state.buffer <> chunk, "\n")
    {lines, [buffer]} = Enum.split(parts, -1)

    Enum.each(lines, fn line ->
      case Jason.decode(line) do
        {:ok, %{"data" => data}} -> send(state.owner, {:terminal_output, data})
        {:ok, %{"exit" => status}} -> send(state.owner, {:terminal_exit, status})
        _ -> Logger.debug("terminal bridge said something unexpected: #{inspect(line)}")
      end
    end)

    {:noreply, %{state | buffer: buffer}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    send(state.owner, {:terminal_exit, status})
    {:stop, :normal, state}
  end

  # The page went away. Nothing can see this shell any more.
  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state),
    do: {:stop, :normal, state}

  def handle_info({:EXIT, port, _reason}, %{port: port} = state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state[:os_pid] do
      # The bridge is its own session leader, so its pid is its process group.
      System.cmd("kill", ["-TERM", "--", "-#{state.os_pid}"], stderr_to_stdout: true)
    end

    close_port(state[:port])
    :ok
  end

  # Checking first and closing after is a race the port can win: the process on
  # the other end exits on its own, and closing a port that has gone raises.
  defp close_port(nil), do: :ok

  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
