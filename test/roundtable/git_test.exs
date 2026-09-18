defmodule Roundtable.GitTest do
  use ExUnit.Case, async: true
  alias Roundtable.Git

  setup do
    dir = Path.join(System.tmp_dir!(), "roundtable-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    git = fn args -> System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true) end
    git.(["init", "-q", "-b", "work"])
    git.(["config", "user.email", "test@example.com"])
    git.(["config", "user.name", "test"])
    File.write!(Path.join(dir, "kept.txt"), "one\ntwo\nthree\n")
    git.(["add", "-A"])
    git.(["commit", "-qm", "first"])

    %{dir: dir, git: git}
  end

  test "a clean tree reports its branch and nothing else", %{dir: dir} do
    assert {:ok, status} = Git.status(dir)
    assert status.branch == "work"
    assert status.entries == []
    assert status.added == 0 and status.removed == 0
  end

  test "counts staged and unstaged edits together", %{dir: dir, git: git} do
    File.write!(Path.join(dir, "kept.txt"), "one\ntwo\nthree\nfour\n")
    File.write!(Path.join(dir, "staged.txt"), "a\nb\n")
    git.(["add", "staged.txt"])

    assert {:ok, status} = Git.status(dir)
    by_path = Map.new(status.entries, &{&1.path, &1})

    assert by_path["kept.txt"].added == 1
    assert by_path["kept.txt"].removed == 0
    assert by_path["staged.txt"].added == 2
    assert status.added == 3
  end

  test "lists untracked files without counts", %{dir: dir} do
    File.write!(Path.join(dir, "new.txt"), "hello\n")

    assert {:ok, status} = Git.status(dir)
    assert [%{status: "??", path: "new.txt", added: 0, removed: 0}] = status.entries
  end

  test "reports a deletion", %{dir: dir} do
    File.rm!(Path.join(dir, "kept.txt"))

    assert {:ok, status} = Git.status(dir)
    assert [%{status: "D", path: "kept.txt", removed: 3}] = status.entries
    assert status.removed == 3
  end

  test "a rename reports under its new path", %{dir: dir, git: git} do
    git.(["mv", "kept.txt", "moved.txt"])

    assert {:ok, status} = Git.status(dir)
    assert [%{path: "moved.txt"}] = status.entries
  end

  test "binary files do not break the counts", %{dir: dir} do
    File.write!(Path.join(dir, "blob.bin"), <<0, 1, 2, 3, 0>>)

    assert {:ok, status} = Git.status(dir)
    assert Enum.all?(status.entries, &is_integer(&1.added))
  end

  test "a directory that is not a repository is an error, not a crash" do
    assert {:error, reason} = Git.status(System.tmp_dir!())
    assert reason =~ "not a git repository"
  end

  test "a directory that does not exist is an error" do
    assert {:error, _} = Git.status("/nonexistent-roundtable-path")
  end
end
