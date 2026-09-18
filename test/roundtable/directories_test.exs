defmodule Roundtable.DirectoriesTest do
  @moduledoc """
  Completing a project directory.

  Typing an absolute path from memory is the worst part of making a room, so
  these pin the behaviour a shell would give you: prefixes narrow, a trailing
  slash goes in, and files are never offered as a place to work.
  """
  use ExUnit.Case, async: true

  alias Roundtable.Directories

  setup do
    root = Path.join(System.tmp_dir!(), "rt-dirs-#{System.unique_integer([:positive])}")

    for path <- ~w(checkout checkout-legacy billing .hidden) do
      File.mkdir_p!(Path.join(root, path))
    end

    File.write!(Path.join(root, "notes.md"), "not a directory")
    File.mkdir_p!(Path.join([root, "checkout", ".git"]))

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "nothing typed offers what is under the starting point", %{root: root} do
    names = Directories.suggest("", root) |> Enum.map(&Path.basename/1)

    assert "checkout" in names
    assert "billing" in names
  end

  test "a prefix narrows to what it could be", %{root: root} do
    names = Directories.suggest(Path.join(root, "check")) |> Enum.map(&Path.basename/1)

    assert names == ["checkout", "checkout-legacy"]
  end

  test "a trailing slash goes inside", %{root: root} do
    assert Directories.suggest(Path.join(root, "checkout") <> "/") == []

    names = Directories.suggest(root <> "/") |> Enum.map(&Path.basename/1)
    assert "billing" in names
  end

  test "files are never offered as somewhere to work", %{root: root} do
    names = Directories.suggest(Path.join(root, "note")) |> Enum.map(&Path.basename/1)
    assert names == []
  end

  test "hidden directories stay hidden until asked for", %{root: root} do
    refute ".hidden" in (Directories.suggest(root <> "/") |> Enum.map(&Path.basename/1))

    names = Directories.suggest(Path.join(root, ".hid")) |> Enum.map(&Path.basename/1)
    assert names == [".hidden"]
  end

  test "a path that does not exist suggests nothing rather than failing" do
    assert Directories.suggest("/nowhere-at-all/deeper/still") == []
  end

  test "git repositories are marked, because that is usually the point", %{root: root} do
    assert Directories.repository?(Path.join(root, "checkout"))
    refute Directories.repository?(Path.join(root, "billing"))
  end

  test "the starting point falls back when the workspace is not a directory" do
    assert Directories.starting_point("/nowhere-at-all") in [System.user_home(), "/"]
    assert File.dir?(Directories.starting_point(nil))
  end

  test "~ is expanded, the way it looks like it should be" do
    home = System.user_home()
    suggested = Directories.suggest("~/")

    assert Enum.all?(suggested, &String.starts_with?(&1, home))
  end
end
