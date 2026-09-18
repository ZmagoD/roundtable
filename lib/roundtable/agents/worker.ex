defmodule Roundtable.Agents.Worker do
  @moduledoc """
  One agent turn: a CLI process, its event stream, and the run it belongs to.

  Owns the port for a single turn and translates the adapter's decisions into
  coordinator events. Every worker is temporary — a turn that dies stays dead
  until a human retries it, rather than restarting and repeating side effects
  the agent has already performed.
  """
  use GenServer, restart: :temporary
  alias Roundtable.Coordinator

  def start_link(args), do: GenServer.start_link(__MODULE__, args)
  @impl true
  def init({agent, run, prompt}) do
    Process.flag(:trap_exit, true)

    state = %{
      adapter: Roundtable.Agents.fetch!(agent.provider),
      agent: agent,
      run: run,
      prompt: prompt,
      port: nil,
      os_pid: nil,
      buffer: "",
      output: "",
      diagnostics: "",
      items: %{},
      item_order: [],
      final_output: nil,
      pending: %{},
      finished: false,
      session: agent.session_id,
      flush: nil
    }

    {:ok, state, {:continue, :launch}}
  end

  @impl true
  def handle_continue(:launch, state) do
    {exe, args} = state.adapter.command(state.agent, state.prompt)

    with executable when not is_nil(executable) <- System.find_executable(exe),
         python when not is_nil(python) <- System.find_executable("python3") do
      runner = Application.app_dir(:roundtable, "priv/agent_exec.py")

      port =
        Port.open({:spawn_executable, python}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: [runner],
          cd: state.agent.directory
        ])

      {:os_pid, pid} = Port.info(port, :os_pid)
      Process.send_after(self(), :timeout, 30 * 60 * 1000)
      state = %{state | port: port, os_pid: pid}
      Port.command(port, Jason.encode!(%{argv: [executable | args]}) <> "\n")
      state.adapter.start(state)
      {:noreply, state}
    else
      _ ->
        finish(
          state,
          "failed",
          "#{exe} or python3 is not installed on PATH. Log in to the CLI in a terminal first."
        )
    end
  rescue
    error -> finish(state, "failed", Exception.message(error))
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    parts = String.split(state.buffer <> data, "\n")
    {lines, [buffer]} = Enum.split(parts, -1)

    state =
      Enum.reduce(lines, %{state | buffer: buffer}, fn line, acc ->
        case Jason.decode(line) do
          {:ok, event} when is_map(event) -> acc.adapter.handle_event(event, acc)
          _ -> %{acc | diagnostics: String.slice(acc.diagnostics <> line <> "\n", -8000, 8000)}
        end
      end)

    cond do
      state.finished ->
        finish(state, elem(state.finished, 0), elem(state.finished, 1))

      byte_size(state.buffer) > 2_000_000 ->
        finish(state, "failed", "Agent emitted an oversized event.")

      true ->
        {:noreply, state}
    end
  end

  def handle_info(:flush, state) do
    Coordinator.event(state.run.id, {:output, state.output})
    {:noreply, %{state | flush: nil}}
  end

  def handle_info({:approval, request_id, decision}, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _} ->
        {:noreply, state}

      {request, remaining} ->
        state.adapter.approve(state, request_id, decision, request)
        {:noreply, %{state | pending: remaining}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {result, error} = state.adapter.exit_status(status, state)
    finish(state, result, error)
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state),
    do: finish(state, "failed", "Agent connection closed: #{inspect(reason)}")

  def handle_info(:timeout, state),
    do: finish(state, "failed", "Turn exceeded 30 minutes. Retry to continue.")

  def handle_info(_, state), do: {:noreply, state}

  def approval(state, id, params) do
    Coordinator.event(state.run.id, {:approval, id, params})
    %{state | pending: Map.put(state.pending, id, params)}
  end

  def joined(state), do: Enum.map_join(state.item_order, "\n\n", &Map.fetch!(state.items, &1))

  def put_output(state, output) do
    timer = state.flush || Process.send_after(self(), :flush, 150)
    %{state | output: String.slice(output, 0, 256_000), flush: timer}
  end

  def write(state, message), do: write_raw(state, Jason.encode!(message) <> "\n")
  def write_raw(state, data), do: Port.command(state.port, Jason.encode!(%{write: data}) <> "\n")

  def close_stdin(state),
    do: Port.command(state.port, Jason.encode!(%{close_stdin: true}) <> "\n")

  defp finish(state, status, error) do
    Coordinator.event(state.run.id, {:output, state.output})
    Coordinator.event(state.run.id, {:done, status, error})
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_, state) do
    if state.os_pid do
      # The wrapper's PID is its process group ID. Never invoke a shell.
      System.cmd("kill", ["-TERM", "--", "-#{state.os_pid}"], stderr_to_stdout: true)
      System.cmd("kill", ["-KILL", "--", "-#{state.os_pid}"], stderr_to_stdout: true)
    end

    if state.port && Port.info(state.port), do: Port.close(state.port)
    :ok
  end
end
