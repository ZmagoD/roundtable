defmodule Roundtable.QuotaRetry do
  @moduledoc "A supervised clock; retry deadlines live in SQLite, not in timers."
  use GenServer
  alias Roundtable.Coordinator

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    if Application.get_env(:roundtable, :start_agents, true) do
      :timer.send_interval(30_000, :tick)
      send(self(), :tick)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    Coordinator.resume_due(DateTime.utc_now(:second))
    {:noreply, state}
  end
end
