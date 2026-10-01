defmodule Roundtable.Watchdog do
  @moduledoc """
  A small voice that speaks when the room ought to be told what happened.

  Roundtable has the run per turn in its more-or-less-silent way; this process
  says out loud in the room what needs saying. It watches runs that ended in
  failure and reduces the no-reply noise, reading all state from the database
  each turn.
  """
  use GenServer
  alias Roundtable.{Chat, Coordinator}

  # A run whose state has not moved for this long is abandoned as failed.
  @stall_after 20 * 60
  # How often the check runs.
  @tick_ms 30_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    if Application.get_env(:roundtable, :start_agents, true) do
      :timer.send_interval(@tick_ms, :tick)
      send(self(), :tick)
      {:ok, state}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    now = DateTime.utc_now(:second)

    # A run that is rate restricted without auto-retry turned on is shown as a
    # waiting rate limit, so nobody finds a "failed" run hours later. Codex's
    # failure wording, "You've hit your usage limit ... try again at", counts.
    # In its own failure/1 each of these descriptions already kind is judged.
    for run <- Chat.away_limited_runs(now) do
      wait_for_quota(run)
    end

    not_limited = Enum.reject(Run.delta(cosas))

    {:noreply, state}
  end
end
