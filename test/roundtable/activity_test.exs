defmodule Roundtable.ActivityTest do
  use Roundtable.DataCase, async: false
  alias Roundtable.Agents.{Activity, Claude, Codex}
  alias Roundtable.{Chat, Coordinator}

  setup do
    Application.put_env(:roundtable, :agent_worker, Roundtable.TestWorker)
    Application.put_env(:roundtable, :test_observer, self())
    Application.put_env(:roundtable, :start_agents, true)

    on_exit(fn ->
      Application.put_env(:roundtable, :start_agents, false)
      Application.delete_env(:roundtable, :agent_worker)
      Application.delete_env(:roundtable, :test_observer)
    end)

    {:ok, room} = Chat.create_room(%{name: "Activity", directory: File.cwd!()})
    {:ok, _agent} = Chat.create_agent(room.id, %{name: "ada", provider: "claude"})
    Coordinator.post(room.id, "@ada task")
    assert_receive {:agent_started, _, _, run, _}, 1000
    %{run: run, state: %{run: run, output: "Earlier text", flush: nil, finished: false}}
  end

  defp step(run) do
    _ = :sys.get_state(Coordinator)
    get_in(Coordinator.activity(), [run.id, :step, :label])
  end

  test "a turn that has not reached a tool reports its start and no step", %{run: run} do
    assert %{started_at: %DateTime{}, step: nil} = Coordinator.activity()[run.id]
  end

  test "Claude's tool calls name the step, and a tool result means it is thinking", %{
    run: run,
    state: state
  } do
    state =
      Claude.handle_event(
        %{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{"type" => "text", "text" => "Running the suite."},
              %{
                "type" => "tool_use",
                "name" => "Bash",
                "input" => %{"command" => "mix test", "description" => "Run the test suite"}
              }
            ]
          }
        },
        state
      )

    assert step(run) == "Running a shell command: Run the test suite"
    # The text already streamed is left alone.
    assert state.output == "Earlier text"

    Claude.handle_event(
      %{
        "type" => "user",
        "message" => %{"content" => [%{"type" => "tool_result", "content" => "ok"}]}
      },
      state
    )

    assert step(run) == "Thinking"
  end

  test "Codex items name the step and their completion means it is thinking", %{
    run: run,
    state: state
  } do
    state =
      Codex.handle_event(
        %{
          "method" => "item/started",
          "params" => %{"item" => %{"type" => "commandExecution", "command" => "mix test"}}
        },
        state
      )

    assert step(run) == "Running a shell command"

    # An agent message finishing is text, not the end of a step.
    state =
      Codex.handle_event(
        %{
          "method" => "item/completed",
          "params" => %{"item" => %{"type" => "userMessage", "id" => "u"}}
        },
        Map.merge(state, %{items: %{}, item_order: [], final_output: nil})
      )

    assert step(run) == "Running a shell command"

    Codex.handle_event(
      %{
        "method" => "item/completed",
        "params" => %{"item" => %{"type" => "commandExecution", "command" => "mix test"}}
      },
      state
    )

    assert step(run) == "Thinking"
  end

  # The service reloads code under running turns; one started before has no
  # start time, and asking about it must not take the Coordinator down.
  test "a worker recorded without a start time is reported without one", %{run: run} do
    :sys.replace_state(Coordinator, fn state ->
      update_in(state.workers[run.id], &Map.delete(&1, :started_at))
    end)

    assert %{started_at: nil, step: nil} = Coordinator.activity()[run.id]
  end

  test "a finished turn no longer reports activity", %{run: run} do
    Coordinator.event(run.id, {:activity, "Thinking"})
    Coordinator.event(run.id, {:done, "completed", nil})
    _ = :sys.get_state(Coordinator)
    refute Map.has_key?(Coordinator.activity(), run.id)
  end

  test "tool names read as steps a person recognises" do
    assert Activity.tool("Read", %{"file_path" => "/repo/lib/chat.ex"}) == "Reading: chat.ex"
    assert Activity.tool("Edit", %{"file_path" => "/repo/lib/chat.ex"}) == "Editing: chat.ex"
    assert Activity.tool("Grep", %{"pattern" => "x"}) == "Searching the code"
    assert Activity.tool("mcp__roundtable__post", %{}) == "Using the room tools"
    assert Activity.tool("Bash", nil) == "Running a shell command"
    assert Activity.tool("Mystery", %{}) == "Using Mystery"

    assert Activity.codex(%{"type" => "fileChange", "changes" => [%{"path" => "/a/b.ex"}]}) ==
             "Editing: b.ex"

    assert Activity.codex(%{"type" => "mcpToolCall", "server" => "roundtable", "tool" => "post"}) ==
             "Using the room tools"

    assert Activity.codex(%{"type" => "agentMessage"}) == nil
  end
end
