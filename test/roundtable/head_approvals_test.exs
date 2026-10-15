defmodule Roundtable.HeadApprovalsTest do
  @moduledoc """
  A team head answering its teammates' tool approvals.

  The human hands this over per room, in the browser, and nowhere else. What
  matters is the boundary: the head answers only for its own team and the task
  rooms that team opened, never for itself, only while the permission stands,
  and every answer is said out loud in the room it affected.
  """
  use Roundtable.DataCase, async: false

  alias Roundtable.{Chat, Coordinator, MCP}

  setup do
    Application.put_env(:roundtable, :agent_worker, Roundtable.TestWorker)
    Application.put_env(:roundtable, :test_observer, self())
    Application.put_env(:roundtable, :start_agents, true)

    on_exit(fn ->
      Application.put_env(:roundtable, :start_agents, false)
      Application.delete_env(:roundtable, :agent_worker)
      Application.delete_env(:roundtable, :test_observer)
    end)

    {:ok, team} = Chat.create_room(%{"name" => "Engineering", "directory" => File.cwd!()})

    {:ok, lead} =
      Chat.create_agent(team.id, %{
        "name" => "lead",
        "provider" => "claude",
        "directory" => File.cwd!()
      })

    {:ok, ada} =
      Chat.create_agent(team.id, %{
        "name" => "ada",
        "provider" => "codex",
        "directory" => File.cwd!()
      })

    {:ok, _} = Chat.set_team_head(lead.id)

    {:ok, task} =
      Chat.create_room(%{"name" => "Task one", "directory" => File.cwd!()},
        supervisor_id: lead.id
      )

    {:ok, bob} =
      Chat.create_agent(task.id, %{
        "name" => "bob",
        "provider" => "codex",
        "directory" => File.cwd!()
      })

    # Ids come back after each test's rollback, so a worker an earlier test left
    # running would otherwise hold these participants' queues.
    Enum.each([lead, ada, bob], &Coordinator.stop(&1.id))
    %{team: team, task: task, lead: Chat.agent!(lead.id), ada: ada, bob: bob}
  end

  defp allow_head(room),
    do: {:ok, _} = Chat.update_room(room.id, %{"head_answers_approvals" => true})

  # A turn for the participant, then a request for a tool inside it.
  defp request(agent, request_id, params \\ %{"display_name" => "Bash", "command" => "mix test"}) do
    Coordinator.post(agent.room_id, "@#{agent.name} work")
    assert_receive {:agent_started, _pid, %{id: id}, run, _} when id == agent.id, 1000
    Coordinator.event(run.id, {:approval, request_id, params})
    _ = :sys.get_state(Coordinator)
    run
  end

  defp wakes(room),
    do: Enum.filter(Chat.messages(room.id), &(&1.metadata["approval_wake"] == true))

  test "with the permission off, only the human answers", %{team: team, lead: lead, bob: bob} do
    run = request(bob, "req-1")

    assert Chat.approval_delegate(bob) == nil
    assert wakes(team) == []
    assert {:ok, "[]"} = MCP.call(lead, "list_approvals", %{})

    assert {:error, "Only the human can answer this approval."} =
             MCP.call(lead, "answer_approval", %{
               "run_id" => run.id,
               "request_id" => "req-1",
               "decision" => "accept",
               "reason" => "tests only"
             })

    refute_received {:decision, "req-1", _}
    assert map_size(Coordinator.approvals()) == 1
  end

  test "a task room's request wakes the head, which answers it with a reason the room can read",
       %{team: team, task: task, lead: lead, ada: ada, bob: bob} do
    allow_head(team)
    run = request(bob, 7, %{"display_name" => "Bash", "command" => "SECRET=x mix test"})

    assert [wake] = wakes(team)
    assert wake.body =~ "@lead bob in Task one is waiting for approval to use Bash"
    refute wake.body =~ "SECRET"
    assert_receive {:agent_started, _pid, %{id: id}, _run, _} when id == lead.id, 1000

    assert {:ok, listed} = MCP.call(lead, "list_approvals", %{})

    assert [%{"run_id" => run_id, "request_id" => "7", "participant" => "bob"}] =
             Jason.decode!(listed)

    assert run_id == run.id
    assert {:ok, "[]"} = MCP.call(ada, "list_approvals", %{})

    assert {:ok, _} =
             MCP.call(lead, "answer_approval", %{
               "run_id" => run.id,
               "request_id" => "7",
               "decision" => "accept",
               "reason" => "Runs the test suite in the task checkout."
             })

    assert_receive {:decision, 7, "accept"}
    assert Coordinator.approvals() == %{}

    note = List.last(Chat.messages(task.id))

    assert note.body ==
             "lead (team head) allowed bob to use Bash: Runs the test suite in the task checkout."

    assert note.sender == "system"
    # Saying so never starts another turn in the task room.
    assert Enum.count(Chat.runs(task.id)) == 1
  end

  test "the head answers for its own room too, but never for itself", %{
    team: team,
    lead: lead,
    ada: ada
  } do
    allow_head(team)

    assert Chat.approval_delegate(ada).id == lead.id
    assert Chat.approval_delegate(lead) == nil

    request(lead, "own")
    assert wakes(team) == []
    assert {:ok, "[]"} = MCP.call(lead, "list_approvals", %{})
  end

  test "a declined request is refused once and explained", %{
    team: team,
    task: task,
    lead: lead,
    bob: bob
  } do
    allow_head(team)
    run = request(bob, "req-2")

    assert {:ok, _} =
             MCP.call(lead, "answer_approval", %{
               "run_id" => run.id,
               "request_id" => "req-2",
               "decision" => "decline",
               "reason" => "Deletes files outside the task."
             })

    assert_receive {:decision, "req-2", "decline"}
    assert List.last(Chat.messages(task.id)).body =~ "lead (team head) declined bob"
  end

  test "a permission withdrawn after the request arrived is honoured", %{
    team: team,
    lead: lead,
    bob: bob
  } do
    allow_head(team)
    run = request(bob, "req-3")
    {:ok, _} = Chat.update_room(team.id, %{"head_answers_approvals" => false})

    assert {:error, "Only the human can answer this approval."} =
             MCP.call(lead, "answer_approval", %{
               "run_id" => run.id,
               "request_id" => "req-3",
               "decision" => "accept",
               "reason" => "fine"
             })

    refute_received {:decision, "req-3", _}
  end

  test "an answer needs a reason", %{team: team, lead: lead, bob: bob} do
    allow_head(team)
    run = request(bob, "req-4")

    assert {:error, "Give a reason" <> _} =
             MCP.call(lead, "answer_approval", %{
               "run_id" => run.id,
               "request_id" => "req-4",
               "decision" => "accept",
               "reason" => "  "
             })

    assert {:error, "Give run_id" <> _} = MCP.call(lead, "answer_approval", %{"run_id" => run.id})
  end

  test "only the browser can hand the head this permission", %{team: team, lead: lead} do
    assert {:ok, _} =
             MCP.call(lead, "update_room", %{"head_answers_approvals" => true, "name" => "Eng"})

    refute Chat.room!(team.id).head_answers_approvals
  end

  test "one waiting wake-up covers every request until it starts", %{lead: lead, team: team} do
    {:ok, message} =
      Chat.post(team.id, "@lead check approvals",
        sender: "system",
        kind: "agent",
        metadata: %{"approval_wake" => true}
      )

    assert Enum.any?(Chat.runs(team.id), &(&1.message_id == message.id and &1.status == "queued"))
    assert Chat.approval_wake_queued?(lead.id)
  end
end
