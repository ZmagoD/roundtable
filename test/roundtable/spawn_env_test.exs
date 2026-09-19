defmodule Roundtable.SpawnEnvTest do
  @moduledoc """
  What a spawned child does not get to inherit.

  The cases that matter are the ones that actually happened: an agent holding
  this node's cookie, an agent pointing `mix test` at the live database, and a
  `PATH` that made every `mix` command in an agent's shell die on the release's
  own boot script.
  """
  use ExUnit.Case, async: false

  alias Roundtable.SpawnEnv

  setup do
    existing = System.get_env()

    on_exit(fn ->
      for {name, _} <- System.get_env(),
          not Map.has_key?(existing, name),
          do: System.delete_env(name)

      for {name, value} <- existing, do: System.put_env(name, value)
    end)

    :ok
  end

  describe "what gets unset" do
    test "the release's variables, cookie included" do
      System.put_env("RELEASE_COOKIE", "a-real-cookie")
      System.put_env("RELEASE_NODE", "roundtable")

      assert "RELEASE_COOKIE" in SpawnEnv.names()
      assert "RELEASE_NODE" in SpawnEnv.names()

      assert {~c"RELEASE_COOKIE", false} in SpawnEnv.sanitised()
    end

    test "the service's own runtime configuration" do
      System.put_env("DATABASE_PATH", "/somewhere/roundtable.db")
      System.put_env("ROUNDTABLE_COOKIE", "another-cookie")
      System.put_env("MIX_ENV", "prod")

      names = SpawnEnv.names()

      assert "DATABASE_PATH" in names
      assert "ROUNDTABLE_COOKIE" in names
      assert "MIX_ENV" in names
    end

    test "and nothing else" do
      System.put_env("ROUNDTABLE_WORKSPACE", "/home/someone/code")
      System.put_env("EDITOR", "vim")

      names = SpawnEnv.names()

      refute "ROUNDTABLE_WORKSPACE" in names
      refute "EDITOR" in names
      refute "HOME" in names
    end
  end

  describe "PATH" do
    test "loses the release's directories and keeps the rest" do
      root = "/tmp/rt-release"
      System.put_env("PATH", "#{root}/erts-17.1/bin:#{root}/bin:/usr/bin:/home/me/.local/bin")

      assert {~c"PATH", cleaned} = SpawnEnv.path(root)
      cleaned = to_string(cleaned)

      assert cleaned == "/usr/bin:/home/me/.local/bin"
    end

    # The bug this prevents: `erl` resolving to the release's own copy, which
    # insists on a boot script that is not there for anybody else.
    test "so erl no longer resolves inside the release" do
      root = "/tmp/rt-release"
      System.put_env("PATH", "#{root}/erts-17.1/bin:/usr/bin")

      {~c"PATH", cleaned} = SpawnEnv.path(root)

      refute to_string(cleaned) =~ root
    end

    test "a directory that merely starts the same way is left alone" do
      System.put_env("PATH", "/tmp/rt-release-notes/bin:/usr/bin")

      {~c"PATH", cleaned} = SpawnEnv.path("/tmp/rt-release")

      assert to_string(cleaned) == "/tmp/rt-release-notes/bin:/usr/bin"
    end

    test "running from source, with no release, changes nothing" do
      System.put_env("PATH", "/usr/bin:/home/me/.local/bin")

      assert {~c"PATH", cleaned} = SpawnEnv.path(nil)
      assert to_string(cleaned) == "/usr/bin:/home/me/.local/bin"
    end
  end

  describe "the shape Port.open wants" do
    test "removals are false, and PATH is last so it survives them" do
      System.put_env("RELEASE_COOKIE", "a-real-cookie")

      sanitised = SpawnEnv.sanitised("/tmp/rt-release")

      assert Enum.all?(sanitised, fn {name, _} -> is_list(name) end)
      assert {~c"PATH", value} = List.last(sanitised)
      assert is_list(value)

      refute {~c"PATH", false} in sanitised
    end
  end
end
