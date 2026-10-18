defmodule Roundtable.TaskCompletionTest do
  use Roundtable.DataCase, async: false
  alias Roundtable.{Chat, Coordinator}
  alias Roundtable.Chat.TaskClosure
  import Roundtable.CompletionFixture, only: [git: 2]
  alias Roundtable.CompletionFixture, as: Fixture

  setup do
    base = Path.join(System.tmp_dir!(), "roundtable-complete-#{Ecto.UUID.generate()}")
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
    git(source, ["remote", "add", "origin", Fixture.url()])
    git(source, ["push", remote, "main"])
    restore = Fixture.install(remote)
    previous = Application.get_env(:roundtable, :task_checkout_root)
    Application.put_env(:roundtable, :task_checkout_root, Path.join(base, "copies"))

    on_exit(fn ->
      restore.()

      if previous,
        do: Application.put_env(:roundtable, :task_checkout_root, previous),
        else: Application.delete_env(:roundtable, :task_checkout_root)

      File.rm_rf!(base)
    end)

    {:ok, parent} = Chat.create_room(%{name: "Parent", directory: source})
    {:ok, head} = Chat.create_agent(parent.id, %{name: "driver", provider: "codex"})

    {:ok, task} =
      Chat.create_room(%{name: "Task", directory: source, isolated: true},
        parent_id: parent.id,
        supervisor_id: head.id
      )

    File.write!(Path.join(task.directory, "work.txt"), "done\n")
    git(task.directory, ["add", "."])
    git(task.directory, ["commit", "-m", "Work"])

    %{source: source, remote: remote, parent: parent, head: head, task: task}
  end

  # A task that is merged, accepted and quiet: every test below breaks one thing.
  defp ready(%{task: task, remote: remote}, extra \\ %{}) do
    sha = Fixture.merge(task, remote)
    {:ok, _} = Fixture.accept(task, sha, extra)
    sha
  end

  test "a merged, accepted, clean task closes and keeps its result in the parent", ctx do
    sha = ready(ctx)
    assert {:ok, summary} = Chat.check_task(ctx.task.id)
    assert summary["sha"] == sha
    assert {:ok, %{"url" => url}} = Chat.finish_task(ctx.task.id)
    assert url =~ "/pull/7"

    refute File.exists?(ctx.task.directory)
    assert File.dir?(ctx.source)
    assert Chat.room!(ctx.task.id).checkout_finished

    note = List.last(Chat.messages(ctx.parent.id))
    assert note.body =~ sha
    assert note.body =~ "Cleanup complete"
    assert note.metadata["task_completion"]["checks"] != []
    assert {:ok, _} = Chat.finish_task(ctx.task.id)
    assert Repo.get_by(TaskClosure, task_room_id: ctx.task.id).status == "complete"
  end

  test "a squash merge counts when the pull request carries the final commit", ctx do
    dir = ctx.task.directory
    head = git(dir, ["rev-parse", "HEAD"])
    git(dir, ["push", ctx.remote, "#{ctx.task.checkout_branch}:#{ctx.task.checkout_branch}"])
    # A squash commit is a different object with the same tree, landed on main.
    squash = git(dir, ["commit-tree", "HEAD^{tree}", "-p", "origin/main", "-m", "Squashed"])
    git(dir, ["push", ctx.remote, "#{squash}:refs/heads/main"])
    Fixture.announce(ctx.task, head, squash)
    {:ok, _} = Fixture.accept(ctx.task, head)
    assert {:ok, %{"merge_sha" => ^squash}} = Chat.check_task(ctx.task.id)
  end

  test "an accepted task can be removed along with its room", ctx do
    ready(ctx, %{"remove_room" => true})
    assert {:ok, _} = Chat.finish_task(ctx.task.id)
    assert Chat.find_room("Task") == nil
    assert Chat.room!(ctx.parent.id)
    assert File.dir?(ctx.source)
    assert List.last(Chat.messages(ctx.parent.id)).body =~ "Cleanup complete"
    assert {:ok, _} = Chat.finish_task(ctx.task.id)
  end

  test "missing or malformed acceptance blocks, and only the right people may record it", ctx do
    sha = Fixture.merge(ctx.task, ctx.remote)
    assert {:error, reason} = Chat.check_task(ctx.task.id)
    assert reason =~ "acceptance"
    assert {:error, _} = Fixture.accept(ctx.task, "abc")
    assert {:error, _} = Fixture.accept(ctx.task, sha, %{"precommit" => " "})

    {:ok, other} = Chat.create_agent(ctx.parent.id, %{name: "other", provider: "codex"})
    assert {:error, _} = Chat.accept_task(ctx.task.id, Fixture.evidence(sha), other)
    assert {:ok, _} = Chat.accept_task(ctx.task.id, Fixture.evidence(sha), ctx.head)
  end

  test "an unmerged pull request or one for another commit blocks", ctx do
    sha = ready(ctx)
    Fixture.announce(ctx.task, sha, sha, %{"merged" => false})
    assert {:error, reason} = Chat.check_task(ctx.task.id)
    assert reason =~ "merged into main"

    Fixture.announce(ctx.task, sha, sha, %{
      "base" => %{"ref" => "dev", "repo" => %{"full_name" => "octo/roundtable"}}
    })

    assert {:error, _} = Chat.check_task(ctx.task.id)

    other = String.duplicate("a", 40)

    Fixture.announce(ctx.task, sha, sha, %{
      "head" => %{
        "ref" => ctx.task.checkout_branch,
        "sha" => other,
        "repo" => %{"full_name" => "octo/roundtable"}
      }
    })

    assert {:error, _} = Chat.check_task(ctx.task.id)
    assert File.dir?(ctx.task.directory)
  end

  test "a merge commit that never reached main blocks", ctx do
    sha = ready(ctx)
    Fixture.announce(ctx.task, sha, String.duplicate("b", 40))
    assert {:error, _} = Chat.check_task(ctx.task.id)
  end

  test "failed, pending or missing required checks block", ctx do
    ready(ctx)

    for checks <- [
          [%{"name" => "test", "bucket" => "fail"}],
          [%{"name" => "test", "bucket" => "pending"}],
          []
        ] do
      Fixture.gh("pr", checks)
      assert {:error, reason} = Chat.check_task(ctx.task.id)
      assert reason =~ "checks"
    end

    Fixture.gh("pr", {:error, "no checks"})
    assert {:error, _} = Chat.check_task(ctx.task.id)
  end

  test "unavailable GitHub evidence never means done", ctx do
    ready(ctx)
    Fixture.gh("api", {:error, "HTTP 502"})
    assert {:error, reason} = Chat.finish_task(ctx.task.id)
    assert reason =~ "unavailable" or reason =~ "failed"
    assert File.dir?(ctx.task.directory)
    refute Repo.get_by(TaskClosure, task_room_id: ctx.task.id)
  end

  test "dirty files, post-merge commits and a switched branch block", ctx do
    ready(ctx)
    File.write!(Path.join(ctx.task.directory, "stray.txt"), "unsaved")
    assert {:error, _} = Chat.check_task(ctx.task.id)
    File.rm!(Path.join(ctx.task.directory, "stray.txt"))
    assert {:ok, _} = Chat.check_task(ctx.task.id)

    File.write!(Path.join(ctx.task.directory, "late.txt"), "after the merge")
    git(ctx.task.directory, ["add", "."])
    git(ctx.task.directory, ["commit", "-m", "Late"])
    assert {:error, reason} = Chat.finish_task(ctx.task.id)
    assert reason =~ "no longer"
    assert File.exists?(Path.join(ctx.task.directory, "late.txt"))
  end

  test "queued turns, open requests and descendant rooms block", ctx do
    ready(ctx)
    {:ok, worker} = Chat.create_agent(ctx.task.id, %{name: "builder", provider: "codex"})
    {:ok, _} = Chat.post(ctx.task.id, "@builder carry on")
    assert {:error, reason} = Chat.check_task(ctx.task.id)
    assert reason =~ "turns"
    Chat.delete_agent(worker.id)
    assert {:ok, _} = Chat.check_task(ctx.task.id)

    {:ok, child} =
      Chat.create_room(%{name: "Child", directory: ctx.source}, parent_id: ctx.task.id)

    assert {:error, reason} = Chat.check_task(ctx.task.id)
    assert reason =~ "descendant"
    Chat.delete_room(child.id)
    assert {:ok, _} = Chat.check_task(ctx.task.id)
  end

  test "a failed cleanup keeps its audit, blocks new work and finishes on retry", ctx do
    ready(ctx)
    closing = ctx.task.directory <> ".closing"
    File.mkdir_p!(closing)

    assert {:error, _} = Chat.finish_task(ctx.task.id)
    audit = Repo.get_by(TaskClosure, task_room_id: ctx.task.id)
    assert audit.status == "sealed"
    assert audit.error
    assert Chat.room!(ctx.task.id).completion_sealed
    assert File.dir?(ctx.task.directory)
    assert List.last(Chat.messages(ctx.parent.id)).body =~ "Cleanup paused"

    assert {:error, _} = Chat.post(ctx.task.id, "more work")
    assert {:error, _} = Chat.create_agent(ctx.task.id, %{name: "late", provider: "codex"})

    assert {:error, _} =
             Chat.create_room(%{name: "Late child", directory: ctx.source},
               parent_id: ctx.task.id
             )

    File.rm_rf!(closing)
    assert {:ok, _} = Chat.finish_task(ctx.task.id)
    refute File.exists?(ctx.task.directory)
    assert Repo.get_by(TaskClosure, task_room_id: ctx.task.id).status == "complete"
    assert length(Enum.filter(Chat.messages(ctx.parent.id), &(&1.kind == "system"))) == 1
  end

  test "the clock closes only tasks the human opted in", ctx do
    ready(ctx)
    assert Coordinator.close_tasks() == []
    assert File.dir?(ctx.task.directory)

    {:ok, _} =
      Fixture.accept(ctx.task, git(ctx.task.directory, ["rev-parse", "HEAD"]), %{
        "automatic" => true
      })

    assert [{_, {:ok, _}}] = Coordinator.close_tasks()
    refute File.exists?(ctx.task.directory)
    assert Coordinator.close_tasks() == []
  end
end
