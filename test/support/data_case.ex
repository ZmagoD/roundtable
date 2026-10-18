defmodule Roundtable.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Roundtable.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Roundtable.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Roundtable.DataCase
    end
  end

  setup tags do
    Roundtable.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Roundtable.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    # Registered last so it runs first, while the sandbox owner is still alive.
    on_exit(&stop_workers/0)
  end

  # The Coordinator outlives every test and rolled-back rows hand their ids to
  # the next test's agents, so a worker left running by one test counts as
  # "busy" for an unrelated agent with the same id, or holds one of the
  # service's worker slots, and the next test's turn never starts.
  defp stop_workers do
    pids =
      Roundtable.AgentSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.map(fn {_, pid, _, _} -> pid end)

    for pid <- pids do
      ref = Process.monitor(pid)
      DynamicSupervisor.terminate_child(Roundtable.AgentSupervisor, pid)

      receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      end
    end

    # Its :DOWN messages are handled in order, so this returns once it has
    # forgotten every worker.
    _ = :sys.get_state(Roundtable.Coordinator)
    :ok
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
