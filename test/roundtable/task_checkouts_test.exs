defmodule Roundtable.TaskCheckoutsTest do
  use RoundtableWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Roundtable.{Chat, CompletionFixture, MCP, TaskCheckouts}

  setup do
    base = Path.join(System.tmp_dir!(), "roundtable-task-#{Ecto.UUID.generate()}")
    source = Path.join(base, "source")
    remote = Path.join(base, "remote.git")
    File.mkdir_p!(source)
    git(base, ["init", "--bare", "-b", "main", remote])
    git(source, ["init", "-b", "main"])
    git(source, ["config", "user.email", "test@example.com"])
    git(source, ["config", "user.name", "Test"])
    File.write!(Path.join(source, "hello.txt"), "original\n")
    git(source, ["add", "."])
    git(source, ["commit", "-m", "Initial"])
    git(source, ["remote", "add", "origin", CompletionFixture.url()])
    git(source, ["push", remote, "main"])
    restore = CompletionFixture.install(remote)
    root = Path.join(base, "copies")
    previous = Application.get_env(:roundtable, :task_checkout_root)
    Application.put_env(:roundtable, :task_checkout_root, root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:roundtable, :task_checkout_root, previous),
        else: Application.delete_env(:roundtable, :task_checkout_root)

      restore.()
      File.rm_rf!(base)
    end)

    %{source: source, root: root, remote: remote, base: base}
  end

  test "independent task rooms keep the original branch and files intact", %{source: source} do
    original = git(source, ["rev-parse", "HEAD"])
    File.write!(Path.join(source, "hello.txt"), "local edits\n")
    {:ok, one} = Chat.create_room(%{name: "Task one", directory: source, isolated: true})
    {:ok, two} = Chat.create_room(%{name: "Task two", directory: source, isolated: true})
    assert one.directory != two.directory
    assert one.checkout_branch != two.checkout_branch
    assert File.read!(Path.join(one.directory, "hello.txt")) == "original\n"
    assert File.read!(Path.join(source, "hello.txt")) == "local edits\n"
    assert git(source, ["rev-parse", "HEAD"]) == original
    assert File.dir?(Path.join(one.directory, ".git"))
    assert {:error, _} = Chat.update_room(one.id, %{directory: source})
    assert {:error, _} = Chat.delete_room(one.id)

    {:ok, agent} = Chat.create_agent(one.id, %{name: "builder", provider: "codex"})
    assert agent.directory == one.directory
    assert {:error, _} = Chat.finish_task(one.id)
    assert File.dir?(one.directory)
    assert File.dir?(source)
    assert File.dir?(two.directory)
  end

  test "cleanup refuses dirty, unpushed, switched or replaced checkouts", %{
    source: source,
    remote: remote
  } do
    {:ok, copy} = TaskCheckouts.create(source)
    git(copy.path, ["config", "url.#{remote}.insteadOf", CompletionFixture.url()])
    assert {:error, _} = TaskCheckouts.finish(copy.id, source)
    git(copy.path, ["push", "origin", copy.branch])
    File.write!(Path.join(copy.path, "new.txt"), "unfinished")
    assert {:error, _} = TaskCheckouts.finish(copy.id, copy.path)
    File.rm!(Path.join(copy.path, "new.txt"))
    git(copy.path, ["checkout", "-b", "other"])
    assert {:error, _} = TaskCheckouts.finish(copy.id, copy.path)
    File.rename!(copy.path, copy.path <> "-saved")
    File.ln_s!(source, copy.path)
    assert {:error, _} = TaskCheckouts.finish(copy.id, copy.path)
    assert File.read!(Path.join(source, "hello.txt")) == "original\n"
  end

  test "retained checkouts consume slots and finished tasks free them", %{
    source: source,
    remote: remote
  } do
    previous = Application.get_env(:roundtable, :task_checkout_limit)
    Application.put_env(:roundtable, :task_checkout_limit, 1)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:roundtable, :task_checkout_limit, previous),
        else: Application.delete_env(:roundtable, :task_checkout_limit)
    end)

    {:ok, copy} = TaskCheckouts.create(source)
    git(copy.path, ["config", "url.#{remote}.insteadOf", CompletionFixture.url()])
    assert {:error, message} = TaskCheckouts.create(source)
    assert message =~ "slots"
    git(copy.path, ["push", "origin", copy.branch])
    assert :ok = TaskCheckouts.finish(copy.id, copy.path)
    assert {:ok, _} = TaskCheckouts.create(source)
  end

  test "agents create task rooms and finish them from the parent room", %{
    source: source,
    remote: remote
  } do
    {:ok, parent} = Chat.create_room(%{name: "Parent", directory: source})
    {:ok, agent} = Chat.create_agent(parent.id, %{name: "manager", provider: "codex"})
    assert {:ok, _} = MCP.call(agent, "create_room", %{"name" => "Isolated", "isolated" => true})
    task = Enum.find(Chat.rooms(), &(&1.name == "Isolated"))
    assert task.checkout_id
    {:ok, builder} = Chat.create_agent(task.id, %{name: "builder", provider: "codex"})
    File.write!(Path.join(task.directory, "work.txt"), "done\n")
    git(task.directory, ["add", "."])
    git(task.directory, ["commit", "-m", "Work"])
    head = CompletionFixture.merge(task, remote)
    assert {:error, _} = MCP.call(agent, "finish_task", %{"room" => to_string(task.id)})

    evidence = CompletionFixture.evidence(head)

    assert {:ok, _} =
             MCP.call(agent, "accept_task", Map.put(evidence, "room", to_string(task.id)))

    {:ok, _} = Chat.post(task.id, "@builder work")
    assert {:error, _} = MCP.call(agent, "check_task", %{"room" => to_string(task.id)})
    Chat.delete_agent(builder.id)
    assert {:ok, _} = MCP.call(agent, "check_task", %{"room" => to_string(task.id)})
    assert {:ok, _} = MCP.call(agent, "finish_task", %{"room" => to_string(task.id)})
    refute File.dir?(task.directory)
    assert File.dir?(source)
  end

  test "task prompts route questions to the captain and replies keep the thread", %{
    source: source
  } do
    {:ok, parent} = Chat.create_room(%{name: "Captain room", directory: source})
    {:ok, captain} = Chat.create_agent(parent.id, %{name: "captain", provider: "codex"})
    {:ok, _} = MCP.call(captain, "create_room", %{"name" => "Subtask", "isolated" => true})
    task = Chat.find_room("Subtask")
    assert task.checkout_supervisor_id == captain.id
    {:ok, worker} = Chat.create_agent(task.id, %{name: "worker", provider: "codex"})

    {:ok, _} =
      Chat.post(parent.id, "@subtask/worker Implement the task",
        sender: captain.name,
        agent_id: captain.id,
        kind: "agent"
      )

    [run] = Chat.runs(task.id)
    {prompt, _} = Chat.prompt(worker, run)
    assert prompt =~ "@captain-room/captain"
    assert prompt =~ "asks the human only when it cannot decide"
    assert :ok = Chat.deliver_answer(run.message_id, "Which format should I use?")
    report = List.last(Chat.messages(parent.id))
    assert report.body =~ "@captain"
    assert report.body =~ "Which format"
    assert Enum.any?(Chat.runs(parent.id), &(&1.agent_id == captain.id))
  end

  test "the browser offers isolated creation and explains an unfinished task", %{
    conn: conn,
    source: source
  } do
    {:ok, parent} = Chat.create_room(%{name: "Main", directory: source})
    {:ok, view, _} = live(conn, "/rooms/#{parent.id}")
    render_hook(view, "panel", %{"name" => "room"})
    assert has_element?(view, "#room-form select[name='room[isolated]']")

    view
    |> form("#room-form", room: %{name: "Browser task", directory: source, isolated: "true"})
    |> render_submit()

    task = Chat.find_room("Browser task")
    {:ok, view, _} = live(conn, "/rooms/#{task.id}")
    assert has_element?(view, "#finish-task")
    assert view |> element("#check-task") |> render_click() =~ "Not done yet"
    assert view |> element("#finish-task") |> render_click() =~ "Not closed"
    assert File.dir?(task.directory)
    assert File.dir?(source)
  end

  defp git(path, args) do
    # CI runners have no git identity, so commits made here would be refused.
    identity = ["-c", "user.name=Roundtable Test", "-c", "user.email=test@roundtable.local"]
    {output, 0} = System.cmd("git", identity ++ ["-C", path] ++ args, stderr_to_stdout: true)
    String.trim(output)
  end
end
