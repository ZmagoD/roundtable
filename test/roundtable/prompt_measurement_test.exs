defmodule Roundtable.PromptMeasurementTest do
  use Roundtable.DataCase, async: false
  alias Roundtable.Chat
  alias Roundtable.Chat.Run

  test "five-agent prompt characters" do
    {:ok, room} =
      Chat.create_room(%{
        "name" => "Measurement",
        "directory" => File.cwd!(),
        "context" =>
          "Build a local-first Phoenix application. Ship tests and documentation together."
      })

    agents =
      for {name, role} <- [
            {"lead",
             "Lead the team and consolidate results. Delegate bounded tasks, keep the shared work document current, and report verified outcomes to the human."},
            {"developer",
             "Implement Elixir and OTP changes with tests. Only Chat writes to the database; keep durable state out of Coordinator. Commit your own files and never push."},
            {"reviewer",
             "Review completed changes against acceptance criteria. Run mix precommit in a clean worktree, inspect unhappy paths, and report concrete failures."},
            {"planner",
             "Turn requests into small tasks with acceptance criteria. Prioritize by value and dependencies; do not write production code."},
            {"designer",
             "Improve the browser experience and accessibility. Use existing CSS tokens, verify responsive layouts, and keep the README current."}
          ] do
        {:ok, agent} =
          Chat.create_agent(room.id, %{
            "name" => name,
            "provider" => "codex",
            "directory" => File.cwd!(),
            "role" => role
          })

        agent
      end

    agent = Enum.at(agents, 1)
    {:ok, _} = Chat.post(room.id, "Participant setup complete.", sender: "system", kind: "system")

    {:ok, _} =
      Chat.post(room.id, "Previous implementation checked.",
        sender: agent.name,
        kind: "agent",
        agent_id: agent.id
      )

    {:ok, task} = Chat.post(room.id, "@developer implement the next bounded task with tests.")
    run = Repo.get_by!(Run, message_id: task.id, agent_id: agent.id)

    resumed = %{
      agent
      | session_id: "measurement",
        instruction_turns: 0,
        session_model: run.model,
        session_directory: agent.directory,
        session_role: agent.role
    }

    {fresh, _} = Chat.prompt(agent, run)
    {continued, _} = Chat.prompt(resumed, run)
    assert String.length(continued) < String.length(fresh) * 0.6

    if System.get_env("ROUNDTABLE_MEASURE_PROMPTS") == "1" do
      for {label, participant} <- [{"fresh", agent}, {"resumed", resumed}] do
        {prompt, _} = Chat.prompt(participant, run)
        IO.puts("PROMPT #{label}: #{String.length(prompt)} characters")
      end
    end
  end
end
