defmodule Roundtable.UsageTest do
  use Roundtable.DataCase, async: false

  alias Roundtable.Agents.{Claude, Codex, OpenCode}
  alias Roundtable.{Chat, Usage}
  alias Roundtable.Chat.Run

  defp state do
    %{
      run: %{id: -1},
      session: "test",
      output: "existing",
      flush: nil,
      finished: false,
      final_output: nil
    }
  end

  test "Claude final usage replaces message snapshots without double counting" do
    event = %{
      "type" => "assistant",
      "message" => %{
        "id" => "msg-1",
        "content" => [],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 2, "cache_read_input_tokens" => 8}
      }
    }

    state = Claude.handle_event(event, state())
    state = Claude.handle_event(event, state)
    assert state.usage_tokens == %{"input" => 10, "output" => 2, "cached" => 8}

    state =
      Claude.handle_event(
        %{
          "type" => "result",
          "usage" => %{
            "input_tokens" => 20,
            "output_tokens" => 5,
            "cache_read_input_tokens" => 12,
            "cache_creation_input_tokens" => 3
          }
        },
        state
      )

    assert state.finished == {"completed", nil}

    assert state.usage_tokens == %{
             "input" => 20,
             "output" => 5,
             "cached" => 12,
             "cache_write" => 3
           }
  end

  test "missing or malformed token counts are unknown, while reported zero is retained" do
    result =
      Claude.handle_event(
        %{
          "type" => "result",
          "usage" => %{
            "input_tokens" => -1,
            "output_tokens" => 0,
            "cache_read_input_tokens" => nil
          }
        },
        state()
      )

    assert result.usage_tokens == %{"output" => 0}
    result = Claude.handle_event(%{"type" => "result"}, state())
    refute Map.has_key?(result, :usage_tokens)
    assert Usage.token_label(%{}) == "not reported"
  end

  test "Codex sums model responses, ignores replay and previous turns, and retains counts at completion" do
    state =
      Codex.handle_event(
        %{"method" => "turn/started", "params" => %{"turn" => %{"id" => "new"}}},
        state()
      )

    old = codex_usage("old", 1000, 100)
    assert Codex.handle_event(old, state) == state
    event = codex_usage("new", 1100, 100)
    state = Codex.handle_event(event, state)
    assert state.usage_tokens["input"] == 100
    state = Codex.handle_event(event, state)
    assert state.usage_tokens["input"] == 100
    state = Codex.handle_event(codex_usage("new", 1300, 200), state)
    assert state.usage_tokens["input"] == 300

    state =
      Codex.handle_event(
        %{"method" => "turn/completed", "params" => %{"turn" => %{"status" => "completed"}}},
        state
      )

    assert state.finished == {"completed", nil}
    assert state.usage_tokens["input"] == 300
    refute Map.has_key?(state.usage_tokens, "output")
  end

  test "Codex handles partial notifications and ignores usage replayed before turn start" do
    event = codex_usage("new", 100, 100)
    assert Codex.handle_event(event, state()) == state()
    state = Codex.handle_event(%{"id" => 3, "result" => %{"turn" => %{"id" => "new"}}}, state())

    state =
      Codex.handle_event(
        %{
          "method" => "thread/tokenUsage/updated",
          "params" => %{
            "turnId" => "new",
            "tokenUsage" => %{"total" => %{"outputTokens" => 5}, "last" => %{"outputTokens" => 5}}
          }
        },
        state
      )

    assert state.usage_tokens == %{"output" => 5}

    assert Codex.handle_event(%{"method" => "thread/tokenUsage/updated", "params" => %{}}, state) ==
             state
  end

  test "OpenCode only counts step usage that is actually present, deduplicated by part id" do
    event = %{"sessionID" => "test", "type" => "step_finish", "part" => %{"id" => "part-1"}}
    missing = OpenCode.handle_event(event, state())
    refute Map.has_key?(missing, :usage_tokens)

    event =
      put_in(event, ["part", "tokens"], %{
        "input" => 100,
        "output" => 10,
        "cache" => %{"read" => 90, "write" => 0}
      })

    state = OpenCode.handle_event(event, state())
    state = OpenCode.handle_event(event, state)

    assert state.usage_tokens == %{
             "input" => 100,
             "output" => 10,
             "cached" => 90,
             "cache_write" => 0
           }
  end

  test "quota snapshots retain reported percentages or statuses without estimates" do
    for {native, label} <- [
          {"allowed", "OK"},
          {"allowed_warning", "near limit"},
          {"rejected", "limited"}
        ] do
      assert Usage.label(Usage.claude_limit(%{"status" => native})) == label
    end

    assert Usage.label(Usage.claude_limit(%{"status" => "allowed", "utilization" => 0.42})) ==
             "42.0%"

    assert Usage.label(Usage.claude_limit(%{})) == "not reported"
    assert Usage.label(Usage.codex_limit(%{"primary" => nil})) == "not reported"

    assert Usage.codex_limit(%{
             "primary" => %{"usedPercent" => 20},
             "secondary" => %{"usedPercent" => 70, "resetsAt" => 123}
           }) ==
             %{"percent" => 70, "resets_at" => 123, "window" => "secondary"}
  end

  test "persisted run snapshots are idempotent and retries add separate attempts" do
    {:ok, room} = Chat.create_room(%{name: "Usage", directory: File.cwd!()})
    {:ok, agent} = Chat.create_agent(room.id, %{name: "ada", provider: "codex"})
    Chat.post(room.id, "@ada work")
    [run] = Chat.runs(room.id)
    run = Chat.record_tokens(run, "attempt-1", %{"input" => 100, "output" => 10})
    run = Chat.record_tokens(run, "attempt-1", %{"input" => 100})
    run = Chat.record_tokens(run, "attempt-2", %{"input" => 20, "cached" => 5})
    assert Repo.get!(Run, run.id).token_usage == run.token_usage

    assert Chat.participant_tokens(room.id)[agent.id] == %{
             "input" => 120,
             "output" => 10,
             "cached" => 5
           }

    Chat.record_provider_usage("codex", %{"percent" => 25})
    Chat.record_provider_usage("codex", %{"percent" => 30})
    assert Chat.provider_usage()["codex"].data == %{"percent" => 30}
    assert Chat.provider_usage()["codex"].recorded_at
    {prompt, _} = Chat.prompt(agent, run)
    assert prompt =~ "usage=30.0%"
    {:ok, _} = Chat.create_agent(room.id, %{name: "bob", provider: "opencode"})
    {prompt, _} = Chat.prompt(agent, run)
    assert prompt =~ "usage=not reported"
  end

  defp codex_usage(turn, total, last) do
    %{
      "method" => "thread/tokenUsage/updated",
      "params" => %{
        "turnId" => turn,
        "tokenUsage" => %{
          "total" => %{"inputTokens" => total},
          "last" => %{"inputTokens" => last}
        }
      }
    }
  end

  describe "the reading a slot keeps" do
    test "a fresher reading of the same window replaces even a better one" do
      five = %{"percent" => 90.0, "status" => "near limit", "window" => "five_hours"}

      # After a reset the old warning must go; a slot is not a maximum.
      assert Usage.keep(five, %{five | "percent" => 10.0, "status" => "OK"}) ==
               %{five | "percent" => 10.0, "status" => "OK"}
    end

    test "between windows, the one closer to its limit is kept" do
      five = %{"percent" => 85.0, "status" => "near limit", "window" => "five_hours"}
      week = %{"percent" => 30.0, "status" => "OK", "window" => "seven_day"}

      assert Usage.keep(five, week) == five

      # A stricter status beats a lower percentage.
      assert Usage.keep(
               %{five | "percent" => 99.9, "status" => "OK"},
               %{"status" => "limited", "window" => "seven_day"}
             )["status"] == "limited"

      # Between calm windows, the higher percentage is the one shown.
      calm_high = %{"percent" => 70.0, "status" => "OK", "window" => "five_hours"}
      calm_low = %{"percent" => 20.0, "status" => "OK", "window" => "seven_day"}

      assert Usage.keep(calm_low, calm_high) == calm_high
      assert Usage.keep(calm_high, calm_low) == calm_high
    end

    test "the first reading is kept whole" do
      reading = %{"percent" => 42.0, "window" => "five_hours"}
      assert Usage.keep(nil, reading) == reading
    end
  end

  describe "how loud a reading is" do
    test "warn at 80% or more, near limit or limited; quiet otherwise" do
      assert Usage.level(%{"percent" => 79.9}) == "ok"
      assert Usage.level(%{"percent" => 80}) == "warn"
      assert Usage.level(%{"status" => "near limit"}) == "warn"
      assert Usage.level(%{"status" => "limited"}) == "warn"
      assert Usage.level(%{"status" => "OK"}) == "ok"
      assert Usage.level(nil) == "ok"
    end
  end
end
