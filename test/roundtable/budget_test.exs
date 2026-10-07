defmodule Roundtable.BudgetTest do
  use Roundtable.DataCase, async: false

  alias Roundtable.{Chat, Coordinator, Repo}
  alias Roundtable.Chat.Run

  setup do
    Application.put_env(:roundtable, :agent_worker, Roundtable.TestWorker)
    Application.put_env(:roundtable, :test_observer, self())
    Application.put_env(:roundtable, :start_agents, true)

    on_exit(fn ->
      Application.put_env(:roundtable, :start_agents, false)
      Application.delete_env(:roundtable, :agent_worker)
      Application.delete_env(:roundtable, :test_observer)
      Application.delete_env(:roundtable, :daily_token_budget)
    end)

    {:ok, room} =
      Chat.create_room(%{"name" => "Budgeted", "directory" => File.cwd!(), "token_budget" => 10})

    {:ok, agent} =
      Chat.create_agent(room.id, %{
        "name" => "ada",
        "provider" => "codex",
        "directory" => File.cwd!()
      })

    Chat.clear_team_head(room.id)
    %{room: room, agent: agent}
  end

  test "a room under its budget starts turns", ctx do
    assert Chat.budget_left(ctx.room.id) == 10_000
    Coordinator.post(ctx.room.id, "@ada have a look")
    assert_receive {:agent_started, pid, _, run, _}, 1000
    GenServer.cast(pid, {:finish, "done"})
    await_completed(run.id)
  end

  test "spending the budget holds the next turn, which says so once", ctx do
    Coordinator.post(ctx.room.id, "@ada first turn")
    assert_receive {:agent_started, pid, _, run, _}, 1000
    GenServer.cast(pid, {:finish, "done"})
    await_completed(run.id)

    Chat.record_tokens(run, "attempt-1", %{"input" => 9_000, "output" => 1_500})
    assert Chat.budget_left(ctx.room.id) <= 0

    Coordinator.post(ctx.room.id, "@ada second turn")
    refute_receive {:agent_started, _, _, _, _}, 200

    assert [%{status: "queued"}] = Repo.all(from r in Run, where: r.id > ^run.id)
    [notice] = Chat.messages(ctx.room.id) |> Enum.filter(&(&1.sender == "supervisor"))
    assert notice.body =~ "daily token budget"

    # A later scheduling pass says nothing further about the same held turn.
    Coordinator.resume_due(DateTime.utc_now(:second))
    assert [_] = Chat.messages(ctx.room.id) |> Enum.filter(&(&1.sender == "supervisor"))
  end

  test "the day moving on releases the held turn", ctx do
    Coordinator.post(ctx.room.id, "@ada first turn")
    assert_receive {:agent_started, pid, _, run, _}, 1000
    GenServer.cast(pid, {:finish, "done"})
    await_completed(run.id)
    Chat.record_tokens(run, "attempt-1", %{"input" => 9_000, "output" => 1_500})

    Coordinator.post(ctx.room.id, "@ada second turn")
    refute_receive {:agent_started, _, _, _, _}, 200

    Repo.update_all(Run, set: [inserted_at: ~U[2020-01-01 00:00:00Z]])
    Coordinator.resume_due(DateTime.utc_now(:second))
    assert_receive {:agent_started, pid, _, run, _}, 1000
    GenServer.cast(pid, {:finish, "done"})
    await_completed(run.id)
  end

  test "retrying a held turn runs it anyway", ctx do
    Coordinator.post(ctx.room.id, "@ada first turn")
    assert_receive {:agent_started, pid, _, run, _}, 1000
    GenServer.cast(pid, {:finish, "done"})
    await_completed(run.id)
    Chat.record_tokens(run, "attempt-1", %{"input" => 9_000, "output" => 1_500})

    Coordinator.post(ctx.room.id, "@ada second turn")
    refute_receive {:agent_started, _, _, _, _}, 200

    assert [held] = Repo.all(from r in Run, where: r.status == "queued")
    Coordinator.retry(held.id)
    assert_receive {:agent_started, pid, _, run, _}, 1000
    GenServer.cast(pid, {:finish, "done"})
    await_completed(run.id)
  end

  test "the service-wide default applies when the room sets no budget of its own", ctx do
    {:ok, room} = Chat.update_room(ctx.room.id, %{"token_budget" => ""})
    assert is_nil(room.token_budget)
    assert Chat.budget_left(room.id) == :unlimited

    Application.put_env(:roundtable, :daily_token_budget, 1)
    assert Chat.budget_left(room.id) == 1000
  end

  # Turns finish asynchronously: the worker casts events and stops, and only
  # then does the coordinator free the participant. Poll rather than guess.
  defp await_completed(run_id, tries \\ 100) do
    if Repo.get!(Run, run_id).status == "completed" or tries == 0 do
      :ok
    else
      Process.sleep(10)
      await_completed(run_id, tries - 1)
    end
  end
end
