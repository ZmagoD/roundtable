defmodule Roundtable.Directories do
  @moduledoc """
  Directory suggestions for the "which project?" field.

  Typing an absolute path from memory is the worst part of making a room, so
  the field completes as you type: the directories under what you have written
  so far, or under a sensible starting point when you have written nothing.

  Only directories, never files, and never hidden ones unless you have started
  typing a dot — a project directory is not `.git`.
  """

  @limit 12

  @doc """
  Directories worth offering for a partially typed path.

  A trailing slash means "inside this one"; anything else is treated as a
  prefix to match within its parent, which is what a shell does.
  """
  def suggest(typed, root \\ nil)

  def suggest(typed, root) when is_binary(typed) do
    typed = String.trim(typed)

    {parent, prefix} =
      cond do
        typed == "" -> {starting_point(root), ""}
        String.ends_with?(typed, "/") -> {expand(typed), ""}
        true -> {expand(Path.dirname(typed)), Path.basename(typed)}
      end

    list(parent, prefix)
  end

  def suggest(_typed, _root), do: []

  @doc "Where to start looking when nothing has been typed."
  def starting_point(root) do
    candidate = root || System.get_env("ROUNDTABLE_WORKSPACE") || System.user_home()

    if is_binary(candidate) and File.dir?(candidate), do: candidate, else: "/"
  end

  defp expand("~" <> rest),
    do: Path.join(System.user_home() || "~", String.trim_leading(rest, "/"))

  defp expand(path), do: Path.expand(path)

  defp list(parent, prefix) do
    case File.ls(parent) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&matches?(&1, prefix))
        |> Enum.map(&Path.join(parent, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.sort()
        |> Enum.take(@limit)

      {:error, _} ->
        []
    end
  end

  # A hidden directory is only worth offering once you have said you want one.
  defp matches?(entry, prefix) do
    String.starts_with?(entry, prefix) and
      (String.starts_with?(prefix, ".") or not String.starts_with?(entry, "."))
  end

  @doc "Whether a directory is a git repository, which is usually the point."
  def repository?(path), do: File.dir?(Path.join(path, ".git"))
end
