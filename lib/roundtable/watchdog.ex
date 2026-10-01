defmodule Roundtable.Watchdog do
  @moduledoc """
  A supervised clock for `Roundtable.Coordinator.supervise/1`.

  Like `Roundtable.QuotaRetry`, it keeps no state: what a turn has been through
  lives on its run, so a restart of the service picks up where it left off.
  """
  use GenServer
  alias Roundtable.Coordinator

  @every 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    if Application.get_env(:roundtable, :start_agents, true) do
      :timer.send_interval(@every, :tick)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    Coordinator.supervise(DateTime.utc_now(:second))
    {:noreply, state}
  end
end
