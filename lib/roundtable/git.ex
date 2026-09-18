defmodule Roundtable.Git do
  @moduledoc """
  A read-only snapshot of what has changed in a working directory.

  Agents run their own git commands while a turn is in flight, so every call
  here passes `--no-optional-locks`: it keeps this process from writing the
  index cache and contending with whatever the agent is doing.

  Returns `{:error, reason}` rather than raising, because a room can point at
  a directory that is not a repository at all.
  """

  @type entry :: %{status: String.t(), path: String.t(), added: integer, removed: integer}

  @doc """
  Summarises the working tree at `directory`.

  Counts come from `diff --numstat HEAD`, so they cover staged and unstaged
  work alike. Untracked files are listed without counts: they have no blob to
  diff against, and reading each one to count lines is not worth the stat.
  """
  def status(directory) when is_binary(directory) do
    with {:ok, branch} <- run(directory, ["rev-parse", "--abbrev-ref", "HEAD"]),
         {:ok, porcelain} <- run(directory, ["status", "--porcelain"]),
         {:ok, numstat} <- run(directory, ["diff", "--numstat", "HEAD"]) do
      counts = parse_numstat(numstat)
      entries = parse_porcelain(porcelain, counts)

      {:ok,
       %{
         directory: directory,
         branch: branch,
         entries: entries,
         added: entries |> Enum.map(& &1.added) |> Enum.sum(),
         removed: entries |> Enum.map(& &1.removed) |> Enum.sum()
       }}
    end
  end

  defp run(directory, args) do
    case System.cmd("git", ["--no-optional-locks", "-C", directory] ++ args,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim_trailing(output)}
      {output, _} -> {:error, first_line(output)}
    end
  rescue
    # No git on PATH, or the directory disappeared under us.
    error -> {:error, Exception.message(error)}
  end

  defp first_line(output) do
    output |> String.split("\n", parts: 2) |> List.first() |> String.trim()
  end

  defp parse_numstat(""), do: %{}

  defp parse_numstat(output) do
    output
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      case String.split(line, "\t", parts: 3) do
        [added, removed, path] -> {path, {number(added), number(removed)}}
        _ -> {line, {0, 0}}
      end
    end)
  end

  # Binary files report "-" instead of a line count.
  defp number(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_porcelain("", _), do: []

  defp parse_porcelain(output, counts) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      {code, rest} = String.split_at(line, 3)
      path = rest |> String.trim() |> unrename() |> unquote_path()
      {added, removed} = Map.get(counts, path, {0, 0})

      %{status: String.trim(code), path: path, added: added, removed: removed}
    end)
  end

  # "R  old -> new" reports under the new path.
  defp unrename(path) do
    case String.split(path, " -> ", parts: 2) do
      [_old, new] -> new
      [only] -> only
    end
  end

  # Paths with unusual characters come back quoted.
  defp unquote_path(<<?", _::binary>> = path) do
    path |> String.trim("\"") |> String.replace("\\\"", "\"")
  end

  defp unquote_path(path), do: path
end
