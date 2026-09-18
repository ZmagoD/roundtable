defmodule Roundtable.TestWorker do
  @moduledoc false
  use GenServer, restart: :temporary
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def init({agent, run, prompt}) do
    send(
      Application.fetch_env!(:roundtable, :test_observer),
      {:agent_started, self(), agent, run, prompt}
    )

    {:ok, run}
  end

  def handle_cast({:finish, output}, run) do
    Roundtable.Coordinator.event(run.id, {:session, "session-#{run.agent_id}"})
    Roundtable.Coordinator.event(run.id, {:output, output})
    Roundtable.Coordinator.event(run.id, {:done, "completed", nil})
    {:stop, :normal, run}
  end

  def handle_cast({:fail, error}, run) do
    Roundtable.Coordinator.event(run.id, {:done, "failed", error})
    {:stop, :normal, run}
  end

  def handle_info({:approval, id, decision}, run) do
    send(Application.fetch_env!(:roundtable, :test_observer), {:decision, id, decision})
    {:noreply, run}
  end
end
