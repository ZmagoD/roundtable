defmodule Roundtable.AdapterTest do
  use Roundtable.DataCase, async: false
  alias Roundtable.{Agents, Chat, Coordinator}

  test "an independently registered adapter streams through the real process bridge" do
    original = Agents.adapters()
    Application.put_env(:roundtable, :adapters, original ++ [Roundtable.FixtureAdapter])
    Application.put_env(:roundtable, :start_agents, true)

    on_exit(fn ->
      Application.put_env(:roundtable, :start_agents, false)
      Application.put_env(:roundtable, :adapters, original)
    end)

    assert Enum.any?(Agents.providers(), &(&1.id == "fixture" && &1.installed))
    {:ok, room} = Chat.create_room(%{"name" => "External adapter", "directory" => File.cwd!()})

    {:ok, agent} =
      Chat.create_agent(room.id, %{
        "name" => "custom",
        "provider" => "fixture",
        "directory" => File.cwd!()
      })

    Chat.subscribe(room.id)
    Coordinator.post(room.id, "@custom hello")
    wait_for(fn -> map_size(Coordinator.approvals()) == 1 end)
    [approval] = Map.values(Coordinator.approvals())
    assert Chat.agent!(agent.id).session_id == "fixture-session"
    Coordinator.approve(approval.run_id, "fixture-request", "decline")
    wait_for(fn -> Enum.any?(Chat.messages(room.id), &(&1.body == "Declined")) end)
    assert [%{status: "completed", output: "Declined"}] = Chat.runs(room.id)
  end

  test "Codex output uses event order and publishes the final answer without commentary" do
    state = %{
      run: %{id: -1},
      items: %{},
      item_order: [],
      output: "",
      final_output: nil,
      flush: nil,
      finished: false
    }

    state =
      Agents.Codex.handle_event(
        %{
          "method" => "item/agentMessage/delta",
          "params" => %{"itemId" => "z", "delta" => "Investigating"}
        },
        state
      )

    state =
      Agents.Codex.handle_event(
        %{
          "method" => "item/agentMessage/delta",
          "params" => %{"itemId" => "a", "delta" => "Done"}
        },
        state
      )

    assert state.output == "Investigating\n\nDone"

    state =
      Agents.Codex.handle_event(
        %{
          "method" => "item/completed",
          "params" => %{
            "item" => %{
              "type" => "agentMessage",
              "id" => "a",
              "text" => "Done",
              "phase" => "final_answer"
            }
          }
        },
        state
      )

    state =
      Agents.Codex.handle_event(
        %{"method" => "turn/completed", "params" => %{"turn" => %{"status" => "completed"}}},
        state
      )

    assert state.output == "Done"
    assert state.finished == {"completed", nil}
    Process.cancel_timer(state.flush)
  end

  defp wait_for(condition) do
    if not condition.() do
      receive do
        :room_updated -> wait_for(condition)
      after
        3000 -> flunk("Timed out waiting for the adapter")
      end
    end
  end
end
