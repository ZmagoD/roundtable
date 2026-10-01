defmodule Roundtable.QuotaTest do
  use ExUnit.Case, async: true
  alias Roundtable.{Agents, Quota}

  test "quota errors are distinct from permanent errors and context exhaustion" do
    for error <- [
          "You've hit your usage limit",
          "Rate limit exceeded",
          "Too many requests",
          %{"codexErrorInfo" => "usageLimitExceeded", "message" => "Try later"},
          %{"type" => "rate_limit_error", "message" => "Try later"},
          %{"data" => %{"statusCode" => 429, "message" => "Try later"}}
        ] do
      assert {"rate_limited", %{message: message}} = Quota.failure(error)
      assert is_binary(message)
    end

    for error <- [
          "Context window exceeded",
          "Turn exceeded 30 minutes",
          "Authentication failed",
          "Credit balance too low",
          "insufficient_quota: rate limit",
          %{"codexErrorInfo" => "sessionBudgetExceeded", "message" => "Usage limit"}
        ] do
      assert {"failed", _} = Quota.failure(error)
    end
  end

  test "reset timestamps win, otherwise retries back off to a six-hour ceiling" do
    now = ~U[2026-09-30 12:00:00Z]
    reset = DateTime.add(now, 7 * 86_400)
    assert Quota.retry_at(DateTime.to_unix(reset), 0, now) == DateTime.add(reset, 15)
    assert Quota.retry_at(nil, 0, now) == DateTime.add(now, 900)
    assert Quota.retry_at(nil, 1, now) == DateTime.add(now, 1800)
    assert Quota.retry_at(nil, 999, now) == DateTime.add(now, 21_600)
    assert Quota.retry_at("tomorrow", 0, now) == DateTime.add(now, 900)
    assert Quota.retry_at(-1, 0, now) == DateTime.add(now, 900)
  end

  test "Claude reports a rejected quota separately from an allowed warning" do
    state = %{finished: false, run: %{id: -1}}

    event = %{
      "type" => "rate_limit_event",
      "rate_limit_info" => %{"status" => "rejected", "resetsAt" => 1_800_000_000}
    }

    assert %{finished: {"rate_limited", %{resets_at: 1_800_000_000}}} =
             Agents.Claude.handle_event(event, state)

    warning = put_in(event, ["rate_limit_info", "status"], "allowed_warning")
    assert Agents.Claude.handle_event(warning, state) == state

    assistant = %{
      "type" => "assistant",
      "error" => "rate_limit",
      "message" => %{"content" => [%{"type" => "text", "text" => "Try later"}]}
    }

    assert %{finished: {"rate_limited", _}} = Agents.Claude.handle_event(assistant, state)
  end

  test "Codex uses exhausted windows only after a quota failure" do
    state = %{finished: false, final_output: nil, run: %{id: -1}}

    event = %{
      "method" => "account/rateLimits/updated",
      "params" => %{
        "rateLimits" => %{
          "primary" => %{"usedPercent" => 100, "resetsAt" => 1_800_000_000},
          "secondary" => %{"usedPercent" => 100, "resetsAt" => 1_900_000_000}
        }
      }
    }

    state = Agents.Codex.handle_event(event, state)
    refute state.finished

    error = %{
      "method" => "turn/completed",
      "params" => %{
        "turn" => %{
          "status" => "failed",
          "error" => %{"codexErrorInfo" => "usageLimitExceeded", "message" => "Wait"}
        }
      }
    }

    assert %{finished: {"rate_limited", %{resets_at: 1_900_000_000}}} =
             Agents.Codex.handle_event(error, state)

    context_error =
      put_in(error, ["params", "turn", "error", "codexErrorInfo"], "contextWindowExceeded")

    assert %{finished: {"failed", "Wait"}} = Agents.Codex.handle_event(context_error, state)
  end
end
