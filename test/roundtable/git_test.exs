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

  # A room's .git/config is the agent's to write. Neither a filesystem monitor
  # nor an external diff tool configured there may run when the panel refreshes.
  test "programs named in the repository's own config are never run", %{dir: dir, git: git} do
    marker = Path.join(dir, "ran")
    git.(["config", "core.fsmonitor", "touch #{marker}"])
    git.(["config", "diff.external", "touch #{marker}"])
    File.write!(Path.join(dir, "kept.txt"), "changed\n")

    assert {:ok, _} = Git.status(dir)
    assert {:ok, _} = Git.diff(dir)
    refute File.exists?(marker)
  end

  # A clean filter needs no flag of its own: config names it, either
  # attributes file switches it on, and status and diff run it.
  test "a filter configured in the repository is never run", %{dir: dir, git: git} do
    marker = Path.join(dir, "filtered")
    git.(["config", "filter.evil.clean", "touch #{marker}; cat"])
    git.(["config", "filter.evil.required", "true"])
    File.write!(Path.join([dir, ".git", "info", "attributes"]), "*.txt filter=evil\n")
    File.write!(Path.join(dir, "kept.txt"), "uno\ndos\ntres\n")

    assert {:ok, _} = Git.status(dir)
    assert {:ok, _} = Git.diff(dir)
    refute File.exists?(marker)
  end

  # The command's own text and the filter's name are the agent's to choose,
  # so neither may stop the filter being found and emptied.
  test "a filter is emptied whatever its command or name contains", %{dir: dir, git: git} do
    # Committed first: the test's own plain git would otherwise run the filters.
    for file <- ~w(other.txt third.txt), do: File.write!(Path.join(dir, file), "x\n")
    git.(["add", "other.txt", "third.txt"])
    git.(["commit", "-qm", "more"])

    marker = Path.join(dir, "filtered")
    git.(["config", "filter.evil.clean", "sh -c 'touch #{marker}; cat' x.sh y"])
    git.(["config", "filter.a=b.clean", "touch #{marker}.eq; cat"])
    git.(["config", "filter.dotted.name.clean", "touch #{marker}.dot; cat"])

    File.write!(
      Path.join([dir, ".git", "info", "attributes"]),
      "kept.txt filter=evil\nother.txt filter=a=b\nthird.txt filter=dotted.name\n"
    )

    for file <- ~w(kept.txt other.txt third.txt), do: File.write!(Path.join(dir, file), "y\n")

    assert {:ok, _} = Git.status(dir)
    assert {:ok, _} = Git.diff(dir)
    refute File.exists?(marker)
    refute File.exists?(marker <> ".eq")
    refute File.exists?(marker <> ".dot")
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
