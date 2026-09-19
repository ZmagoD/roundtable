defmodule Roundtable.SpawnEnv do
  @moduledoc """
  What a process the service starts should *not* inherit from the service.

  `Port.open` adds to the parent's environment rather than replacing it, so an
  agent's CLI — and every command that CLI runs — starts life holding whatever
  the service was holding. Two kinds of thing are in there and neither belongs
  to a child:

  **The keys to this node.** A release exports `RELEASE_COOKIE`, which is the
  distributed Erlang cookie for the running service. Anything that has it can
  attach to the node that owns the database, the queue and the approvals. The
  cookie is also in a file on disk that a process running as this user can read,
  so removing it here is not a wall — it is the difference between "sitting in
  every shell we hand out" and "something you went looking for".

  **This service's own runtime configuration.** `DATABASE_PATH` names the live
  database and `MIX_ENV` says which environment to be. An agent that ran `mix
  test` in a checkout inherited both and pointed the suite at the running
  service's data; the sandbox rolled it back, and it should never have been able
  to aim there in the first place.

  `PATH` is cleaned rather than removed. A release puts its own ERTS at the
  front, so `erl` resolves to a copy that insists on the release's boot script
  and every `mix` command in an agent's shell dies on it. Dropping those
  directories is what makes the toolchain work at all, and it takes `erl_call`
  out of the child's reach on the way past.
  """

  # Named exactly, not by prefix, so adding one is a decision rather than a
  # side effect of what somebody called a variable.
  @strip ["ROUNDTABLE_COOKIE", "DATABASE_PATH", "MIX_ENV"]

  @doc """
  Removals and a cleaned `PATH`, for the `env:` option of `Port.open`.

  Values of `false` unset a variable in the child. Put anything the child is
  meant to have *after* this list, so an intentional value is never unset by it.
  """
  def sanitised(release_root \\ System.get_env("RELEASE_ROOT")) do
    Enum.map(names(), &{String.to_charlist(&1), false}) ++ [path(release_root)]
  end

  @doc "The variables that get unset, given what this process is holding."
  def names do
    System.get_env()
    |> Map.keys()
    |> Enum.filter(&(String.starts_with?(&1, "RELEASE_") or &1 in @strip))
    |> Enum.sort()
  end

  @doc "`PATH` with the release's own directories taken out of it."
  def path(release_root \\ System.get_env("RELEASE_ROOT")) do
    {~c"PATH", String.to_charlist(clean_path(System.get_env("PATH", ""), release_root))}
  end

  defp clean_path(path, nil), do: path

  defp clean_path(path, release_root) do
    path
    |> String.split(":", trim: true)
    |> Enum.reject(&under?(&1, release_root))
    |> Enum.join(":")
  end

  # Compared as paths rather than as text: a directory that merely starts with
  # the same characters is somebody else's.
  defp under?(entry, root) do
    entry = Path.expand(entry)
    root = Path.expand(root)

    entry == root or String.starts_with?(entry, root <> "/")
  end
end
