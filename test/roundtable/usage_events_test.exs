defmodule Roundtable.UsageEventsTest do
  use Roundtable.DataCase, async: false
  alias Roundtable.Agents.{Claude, Codex}
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
    end)

    {:ok, room} = Chat.create_room(%{name: "Usage events", directory: File.cwd!()})
    %{room: room}
  end

  test "Claude final result persists tokens before completion and all quota statuses update", %{
    room: room
  } do
    {:ok, agent} = Chat.create_agent(room.id, %{name: "ada", provider: "claude"})
    Coordinator.post(room.id, "@ada task")
    assert_receive {:agent_started, _, _, run, _}, 1000
    state = %{run: run, output: "", flush: nil, finished: false}

    for status <- ~w(allowed allowed_warning rejected) do
      Claude.handle_event(
        %{"type" => "rate_limit_event", "rate_limit_info" => %{"status" => status}},
        state
      )

      _ = :sys.get_state(Coordinator)

      assert Chat.provider_usage()["claude"].data["status"] ==
               %{"allowed" => "OK", "allowed_warning" => "near limit", "rejected" => "limited"}[
                 status
               ]
    end

    Chat.update_agent(agent.id, %{provider: "opencode"})

    Claude.handle_event(
      %{
        "type" => "rate_limit_event",
        "rate_limit_info" => %{"status" => "allowed", "utilization" => 0.6}
      },
      state
    )

    state =
      Claude.handle_event(
        %{"type" => "result", "usage" => %{"input_tokens" => 25, "output_tokens" => 5}},
        state
      )

    {status, error} = state.finished
    Coordinator.event(run.id, {:done, status, error})
    _ = :sys.get_state(Coordinator)
    assert Repo.get!(Run, run.id).status == "completed"
    assert Chat.participant_tokens(room.id)[agent.id] == %{"input" => 25, "output" => 5}
    assert Chat.provider_usage()["claude"].data["percent"] == 60.0
    refute Map.has_key?(Chat.provider_usage(), "opencode")
  end

  test "Claude keeps the window closer to its limit", %{room: room} do
    {:ok, _agent} = Chat.create_agent(room.id, %{name: "ada", provider: "claude"})
    Coordinator.post(room.id, "@ada task")
    assert_receive {:agent_started, _, _, run, _}, 1000
    state = %{run: run, output: "", flush: nil, finished: false}

    # Two events, one per window; only one slot per provider.
    for window <- [
          %{
            "rateLimitType" => "five_hours",
            "status" => "allowed_warning",
            "utilization" => 0.85
          },
          %{"rateLimitType" => "seven_day", "status" => "allowed", "utilization" => 0.3}
        ] do
      Claude.handle_event(%{"type" => "rate_limit_event", "rate_limit_info" => window}, state)
      _ = :sys.get_state(Coordinator)
    end

    assert Chat.provider_usage()["claude"].data["percent"] == 85.0

    # A fresher reading of the same window replaces it even when it is calmer.
    Claude.handle_event(
      %{
        "type" => "rate_limit_event",
        "rate_limit_info" => %{
          "rateLimitType" => "five_hours",
          "status" => "allowed",
          "utilization" => 0.05
        }
      },
      state
    )

    _ = :sys.get_state(Coordinator)
    assert Chat.provider_usage()["claude"].data["percent"] == 5.0

    Coordinator.event(run.id, {:done, "completed", nil})
    _ = :sys.get_state(Coordinator)
    assert Repo.get!(Run, run.id).status == "completed"
  end

  test "Codex notifications persist usage even when the turn fails", %{room: room} do
    {:ok, agent} = Chat.create_agent(room.id, %{name: "ada", provider: "codex"})
    Coordinator.post(room.id, "@ada task")
    assert_receive {:agent_started, _, _, run, _}, 1000
    state = %{run: run, output: "", flush: nil, finished: false, final_output: nil}

    state =
      Codex.handle_event(
        %{"method" => "turn/started", "params" => %{"turn" => %{"id" => "turn"}}},
        state
      )

    state =
      Codex.handle_event(
        %{
          "method" => "thread/tokenUsage/updated",
          "params" => %{
            "turnId" => "turn",
            "tokenUsage" => %{
              "total" => %{"inputTokens" => 125, "outputTokens" => 15, "cachedInputTokens" => 100},
              "last" => %{"inputTokens" => 25, "outputTokens" => 5, "cachedInputTokens" => 20}
            }
          }
        },
        state
      )

    Codex.handle_event(
      %{
        "method" => "account/rateLimits/updated",
        "params" => %{"rateLimits" => %{"primary" => %{"usedPercent" => 30}}}
      },
      state
    )

    state =
      Codex.handle_event(
        %{
          "method" => "turn/completed",
          "params" => %{"turn" => %{"status" => "failed", "error" => %{"message" => "failed"}}}
        },
        state
      )

    {status, error} = state.finished
    Coordinator.event(run.id, {:done, status, error})
    _ = :sys.get_state(Coordinator)
    assert Repo.get!(Run, run.id).status == "failed"

    assert Chat.participant_tokens(room.id)[agent.id] == %{
             "input" => 25,
             "output" => 5,
             "cached" => 20
           }

    assert Chat.provider_usage()["codex"].data["percent"] == 30
  end
end
