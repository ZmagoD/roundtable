defmodule Roundtable.AgentRuntime do
  @moduledoc """
  Supervises the agent workers, the coordinator and the clock together.

  They restart as a unit: a coordinator that outlives its workers would hold
  references to processes that no longer exist, workers that outlive their
  coordinator would have nowhere to report, and the scheduler posts through the
  coordinator, so it has nothing to do without one.
  """
  use Supervisor
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_) do
    Supervisor.init(
      [
        {DynamicSupervisor, name: Roundtable.AgentSupervisor, strategy: :one_for_one},
        Roundtable.Coordinator,
        Roundtable.Scheduler
      ],
      strategy: :one_for_all
    )
  end
end
