defmodule Roundtable.AgentRuntime do
  @moduledoc """
  Supervises the agent workers and the coordinator together.

  They restart as a unit: a coordinator that outlives its workers would hold
  references to processes that no longer exist, and workers that outlive their
  coordinator would have nowhere to report.
  """
  use Supervisor
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_) do
    Supervisor.init(
      [
        {DynamicSupervisor, name: Roundtable.AgentSupervisor, strategy: :one_for_one},
        Roundtable.Coordinator
      ],
      strategy: :one_for_all
    )
  end
end
