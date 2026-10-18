defmodule Roundtable.LeanDelegationTest do
  use Roundtable.DataCase, async: false

  alias Roundtable.{Chat, Coordinator, MCP}
  alias Roundtable.Chat.{CrossRoomRequest, Run}

  setup do
    {:ok, parent} = Chat.build_team(%{name: "Head", directory: File.cwd!(), provider: "codex", context: "Ship changes"})
    [head] = Chat.agents(parent.id)
    [run] = Chat.runs(parent.id)
    Chat.change(run, status: "running")
    {:ok, child} = Chat.create_room(%{name: "Task", directory: File.cwd!()}, parent_id: parent.id, supervisor_id: head.id)
    {:ok, owner} = Chat.create_agent(child.id, %{name: "owner", provider: "codex"})
    %{parent: parent, head: head, child: child, owner: owner, run: run}
  end

  test "new setup keeps one head and requests concise on-demand delegation", ctx do
    assert [head] = Chat.agents(ctx.parent.id)
    assert head.head
    assert head.role =~ "one delegating head by default"
    assert head.role =~ "explicitly requests a multi-agent team"
    {prompt, _} = Chat.prompt(head, ctx.run)
    assert prompt =~ "normally at most 120 words"
    assert prompt =~ "correctness requires it"
    assert prompt =~ "send_room_request with kind delegate"
    assert [owner] = Chat.agents(ctx.child.id)
    assert owner.head
  end

  test "typed task completes durably once without a head turn or transcript injection", ctx do
    assert {:ok, _} = MCP.call(ctx.head, "send_room_request", %{"room" => "Task", "participant" => "owner", "kind" => "delegate", "body" => "Implement TASK-9"})
    [request] = Repo.all(CrossRoomRequest)
    assert request.kind == "delegate"
    assert [%Run{agent_id: id}] = Chat.runs(ctx.child.id)
    assert id == ctx.owner.id
    detail = "full private evidence @team-builder " <> String.duplicate("x", 5000)
    assert :ok = Chat.deliver_answer(request.to_message_id, detail)
    assert :ok = Chat.deliver_answer(request.to_message_id, detail)
    assert Repo.get!(CrossRoomRequest, request.id).answer == detail
    assert Repo.get!(CrossRoomRequest, request.id).status == "answered"
    assert length(Chat.runs(ctx.parent.id)) == 1
    results = Enum.filter(Chat.messages(ctx.parent.id), &(&1.metadata["cross_room"] == "result"))
    assert [result] = results
    assert String.length(result.body) < 200
    refute result.body =~ detail
    Chat.clear_team_head(ctx.parent.id)
    {prompt, _} = Chat.prompt(ctx.head, ctx.run)
    refute prompt =~ "Task result available"
    refute prompt =~ "full private evidence"
  end

  test "explicit blocker wakes its recipient and its answer resolves once", ctx do
    [run] = Chat.runs(ctx.parent.id)
    Chat.change(run, status: "completed")
    {:ok, message} = Chat.post(ctx.child.id, "Start task")
    child_run = Repo.get_by!(Run, message_id: message.id)
    Chat.change(child_run, status: "running")
    assert {:ok, _} = MCP.call(ctx.owner, "send_room_request", %{"room" => "Head", "participant" => "team-builder", "kind" => "ask", "body" => "Blocked: choose the schema"})
    [request] = Repo.all(CrossRoomRequest)
    assert request.kind == "ask"
    assert length(Chat.runs(ctx.parent.id)) == 2
    Chat.deliver_answer(request.to_message_id, "Use the existing schema")
    Chat.deliver_answer(request.to_message_id, "Use the existing schema")
    assert length(Chat.runs(ctx.child.id)) == 2
    assert Repo.get!(CrossRoomRequest, request.id).status == "answered"
  end

  test "child detail is bounded, paginated and scoped to its supervisor", ctx do
    for n <- 1..12 do
      Chat.post(ctx.child.id, "Evidence #{n}: " <> String.duplicate("e", 2100), kind: "agent", sender: "owner")
    end
    assert {:ok, text} = MCP.call(ctx.head, "read_task_detail", %{"room" => "Task"})
    detail = Jason.decode!(text)
    assert length(detail["messages"]) == 10
    assert Enum.all?(detail["messages"], &(String.length(&1["body"]) == 2000 and &1["truncated"]))
    first = hd(detail["messages"])["id"]
    assert {:ok, older} = MCP.call(ctx.head, "read_task_detail", %{"room" => "Task", "before_id" => first})
    assert length(Jason.decode!(older)["messages"]) == 2
    assert {:error, _} = MCP.call(ctx.owner, "read_task_detail", %{"room" => "Head"})
    {:ok, other} = Chat.create_agent(ctx.parent.id, %{name: "other", provider: "codex"})
    assert {:error, _} = MCP.call(other, "read_task_detail", %{"room" => "Task"})
    assert {:error, _} = MCP.call(ctx.head, "read_task_detail", %{"room" => "Task", "before_id" => -1})
    Chat.change(ctx.child, checkout_finished: true)
    assert {:ok, _} = MCP.call(ctx.head, "read_task_detail", %{"room" => "Task"})
  end

  test "fake worker completion never starts the head", ctx do
    Application.put_env(:roundtable, :agent_worker, Roundtable.TestWorker)
    Application.put_env(:roundtable, :test_observer, self())
    Application.put_env(:roundtable, :start_agents, true)
    on_exit(fn ->
      Application.put_env(:roundtable, :start_agents, false)
      Application.delete_env(:roundtable, :agent_worker)
      Application.delete_env(:roundtable, :test_observer)
    end)
    assert {:ok, _} = Coordinator.send_room_request(ctx.head, ctx.owner, "delegate", "Implement the task")
    assert_receive {:agent_started, _, owner, run, _}, 1000
    assert owner.id == ctx.owner.id
    Coordinator.event(run.id, {:output, "Done. Full evidence remains here."})
    Coordinator.event(run.id, {:done, "completed", nil})
    _ = :sys.get_state(Coordinator)
    assert length(Chat.runs(ctx.parent.id)) == 1
    refute_receive {:agent_started, _, _, _, _}
    assert [%{status: "answered"}] = Repo.all(CrossRoomRequest)
  end
end
