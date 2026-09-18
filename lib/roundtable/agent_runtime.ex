defmodule Roundtable.AgentRuntime do
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
