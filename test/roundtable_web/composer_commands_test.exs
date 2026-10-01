defmodule RoundtableWeb.ComposerCommandsTest do
  use ExUnit.Case, async: true

  alias RoundtableWeb.ComposerCommands, as: Commands

  @agents [%{id: 7, name: "ada"}]

  test "all new commands parse valid input" do
    assert Commands.parse("/auto ada on", @agents) ==
             {:update_agent, 7, %{"auto_approve" => true}}

    assert Commands.parse("/auto ada off", @agents) ==
             {:update_agent, 7, %{"auto_approve" => false}}

    assert Commands.parse("/model ada custom-model", @agents) ==
             {:update_agent, 7, %{"model" => "custom-model"}}

    assert Commands.parse("/model ada default", @agents) == {:update_agent, 7, %{"model" => nil}}

    assert Commands.parse("/role ada Review code\nKeep  notes", @agents) ==
             {:update_agent, 7, %{"role" => "Review code\nKeep  notes"}}

    assert Commands.parse("/rename ada grace", @agents) ==
             {:update_agent, 7, %{"name" => "grace"}}

    assert Commands.parse("/reset ada", @agents) == {:event, "reset", %{"id" => "7"}}

    assert Commands.parse("/remove ada", @agents) ==
             {:event, "confirm-remove-agent", %{"id" => "7"}}

    assert Commands.parse("/who", @agents) == {:panel, "roster"}
  end

  test "invalid input for each new command is rejected" do
    for body <- [
          "/auto ada yes",
          "/model ada",
          "/role ada",
          "/reset",
          "/retry invalid",
          "/approve maybe",
          "/rename ada",
          "/remove",
          "/who extra"
        ] do
      assert {:error, _} = Commands.parse(body, @agents), body
    end

    for body <- [
          "/auto absent on",
          "/model absent default",
          "/role absent Review",
          "/reset absent",
          "/rename absent grace",
          "/remove absent"
        ] do
      assert {:error, "No participant" <> _} = Commands.parse(body, @agents), body
    end
  end

  test "retry defaults to newest eligible run and rejects invalid or ineligible ids" do
    runs = [
      %{id: 1, status: "failed"},
      %{id: 3, status: "completed"},
      %{id: 2, status: "waiting_quota"}
    ]

    assert Commands.parse("/retry", @agents, runs: runs) == {:event, "retry", %{"id" => "2"}}
    assert Commands.parse("/retry 1", @agents, runs: runs) == {:event, "retry", %{"id" => "1"}}

    for body <- ["/retry 3", "/retry 99", "/retry 1x", "/retry 1 2"] do
      assert {:error, _} = Commands.parse(body, @agents, runs: runs)
    end

    assert {:error, _} = Commands.parse("/retry", @agents)
  end

  test "approval numbers select exactly one pending request" do
    approvals = [%{run_id: 10, request_id: "first"}, %{run_id: 10, request_id: 42}]

    assert Commands.parse("/approve accept", @agents, approvals: approvals) ==
             {:event, "approval",
              %{"run" => "10", "request" => "\"first\"", "decision" => "accept"}}

    assert Commands.parse("/approve decline 2", @agents, approvals: approvals) ==
             {:event, "approval", %{"run" => "10", "request" => "42", "decision" => "decline"}}

    for body <- [
          "/approve accept 0",
          "/approve accept -1",
          "/approve accept 3",
          "/approve accept x",
          "/approve accept 1x",
          "/approve accept 1 2"
        ] do
      assert {:error, _} = Commands.parse(body, @agents, approvals: approvals)
    end

    assert {:error, _} = Commands.parse("/approve accept", @agents)
  end

  test "suggestion data includes new commands and live argument choices" do
    runs = [%{id: 11, status: "failed"}, %{id: 12, status: "running"}]
    commands = Commands.suggestions(@agents, runs, [%{}]) |> Map.new(&{&1.name, &1})

    for name <- ~w(auto model role reset retry approve rename remove who) do
      assert Map.has_key?(commands, name)
    end

    assert commands["auto"].choices == [["ada"], ["on", "off"]]
    assert commands["model"].choices == [["ada"], ["default"]]
    assert commands["retry"].choices == [["11"]]
    assert commands["approve"].choices == [["accept", "decline"], ["1"]]

    assert Commands.suggestions([], [], [])
           |> Enum.find(&(&1.name == "approve"))
           |> Map.fetch!(:choices) == [["accept", "decline"], []]
  end
end
