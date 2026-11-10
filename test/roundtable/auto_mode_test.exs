defmodule Roundtable.AutoModeTest do
  use Roundtable.DataCase, async: false
  alias Roundtable.{Chat, Coordinator, Repo}
  alias Roundtable.Chat.Agent

  setup do
    Application.put_env(:roundtable, :agent_worker, Roundtable.TestWorker)
    Application.put_env(:roundtable, :test_observer, self())
    Application.put_env(:roundtable, :start_agents, true)

    {:ok, room} = Chat.create_room(%{name: "Automatic", directory: File.cwd!()})

    {:ok, head} = Chat.create_agent(room.id, %{name: "ada", provider: "codex"})
    {:ok, _helper} = Chat.create_agent(room.id, %{name: "lee", provider: "claude"})

    on_exit(fn ->
      Application.put_env(:roundtable, :start_agents, false)
      Application.delete_env(:roundtable, :agent_worker)
      Application.delete_env(:roundtable, :test_observer)
    end)

    %{room: room, head: head}
  end

  defp stop_all(room_id) do
    Enum.each(Chat.agents(room_id), &Coordinator.stop(&1.id))
  end

  test "the room toggle follows every participant, including those who join later", ctx do
    assert Chat.set_auto_mode(ctx.room.id, true).auto_mode

    assert Repo.all(
             from a in Agent,
               where: a.room_id == ^ctx.room.id,
               order_by: a.id,
               select: a.auto_approve
           ) ==
             [true, true]

    {:ok, newcomer} = Chat.create_agent(ctx.room.id, %{name: "new", provider: "codex"})
    assert Repo.get!(Agent, newcomer.id).auto_approve

    assert Chat.set_auto_mode(ctx.room.id, false).auto_mode == false

    assert Repo.all(
             from a in Agent,
               where: a.room_id == ^ctx.room.id,
               order_by: a.id,
               select: a.auto_approve
           ) ==
             [false, false, false]
  end

  test "open tasks are the document's unfinished list lines" do
    document = """
    Goal: Add password reset

    Tasks:
    - T1 | builder | implementing | Endpoint and form
    - T2 | reviewer | waiting on T1 | Verify expiry and token reuse
    - T3 | builder | done | Login page wired
    - T4 | builder | blocked | Needs vendor reply

    Blockers: none
    """

    open = Chat.open_tasks(document)
    assert length(open) == 2
    assert hd(open) =~ "T1"

    assert Chat.open_tasks("No tasks here at all.") == []
    assert Chat.open_tasks("") == []
  end

  test "auto mode wakes the head while tasks remain and the document moves", ctx do
    Chat.set_auto_mode(ctx.room.id, true)
    {:ok, _message} = Coordinator.post(ctx.room.id, "Start the work")
    assert_receive {:agent_started, pid, agent, run, prompt}, 1000
    assert agent.id == ctx.head.id
    assert prompt =~ "AUTO MODE"
    assert run.work_revision == 0

    # The head's pass recorded progress in the document, so the loop continues.
    {:ok, _} =
      Chat.update_work_document(
        ctx.room.id,
        "Tasks:\n- T1 | ada | implementing | Endpoint\n",
        0
      )

    ref = Process.monitor(pid)
    GenServer.cast(pid, {:finish, "Endpoint drafted"})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000

    # The wake mentions the head, which starts a new run for the next pass.
    assert_receive {:agent_started, pid2, _, run2, prompt2}, 1000
    assert run2.message_id != run.message_id
    assert prompt2 =~ "AUTO MODE"
    assert Enum.any?(Chat.messages(ctx.room.id), &(&1.body =~ "auto mode: the work document"))

    # The next pass ends without touching the document, so the loop pauses.
    ref2 = Process.monitor(pid2)
    GenServer.cast(pid2, {:finish, "Still working"})
    assert_receive {:DOWN, ^ref2, :process, ^pid2, :normal}, 1000
    _ = :sys.get_state(Coordinator)

    refute_receive {:agent_started, _, _, _, _}, 200

    assert Enum.any?(
             Chat.messages(ctx.room.id),
             &(&1.body =~ "Auto mode pauses here")
           )

    stop_all(ctx.room.id)
  end

  test "auto mode does not wake the head when no task is left open", ctx do
    Chat.set_auto_mode(ctx.room.id, true)
    {:ok, _} = Coordinator.post(ctx.room.id, "Check the room")
    assert_receive {:agent_started, pid, _, _run, _}, 1000

    {:ok, _} =
      Chat.update_work_document(
        ctx.room.id,
        "Tasks:\n- T1 | ada | done | Checked\n",
        0
      )

    ref = Process.monitor(pid)
    GenServer.cast(pid, {:finish, "All checked"})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)

    refute_receive {:agent_started, _, _, _, _}, 200
    stop_all(ctx.room.id)
  end

  test "only the head drives the loop; a specialist's pass wakes nobody in auto mode", ctx do
    Chat.set_auto_mode(ctx.room.id, true)
    {:ok, _} = Coordinator.post(ctx.room.id, "@lee Bounded task")
    assert_receive {:agent_started, pid, agent, _run, _}, 1000
    assert agent.name == "lee"

    {:ok, _} =
      Chat.update_work_document(ctx.room.id, "Tasks:\n- T1 | lee | implementing | x\n", 0)

    ref = Process.monitor(pid)
    GenServer.cast(pid, {:finish, "Part done, handing to @ada"})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)

    # The mention in the reply starts the head's turn; the loop itself did not.
    assert_receive {:agent_started, _, head, _, _}, 1000
    assert head.id == ctx.head.id
    refute Enum.any?(Chat.messages(ctx.room.id), &(&1.body =~ "auto mode: the work document"))
    Coordinator.stop(head.id)
    stop_all(ctx.room.id)
  end

  test "a room without auto mode never auto-continues", ctx do
    {:ok, _} = Coordinator.post(ctx.room.id, "Start the work")
    assert_receive {:agent_started, pid, _agent, _run, prompt}, 1000
    refute prompt =~ "AUTO MODE"

    {:ok, _} =
      Chat.update_work_document(ctx.room.id, "Tasks:\n- T1 | ada | implementing | x\n", 0)

    ref = Process.monitor(pid)
    GenServer.cast(pid, {:finish, "Draft ready"})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    _ = :sys.get_state(Coordinator)

    refute_receive {:agent_started, _, _, _, _}, 200
    stop_all(ctx.room.id)
  end
end
