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

  @doc """
  The patch for the working tree, staged and unstaged together.

  Capped, because a turn that rewrites a vendored directory would otherwise
  push a megabyte of diff through the socket to be rendered in a browser.
  """
  def diff(directory, limit \\ 200_000) when is_binary(directory) do
    case run(directory, ["diff", "HEAD"]) do
      {:ok, patch} when byte_size(patch) > limit ->
        {:ok, binary_part(patch, 0, limit) <> "\n… diff truncated"}

      other ->
        other
    end
  end

  defp run(directory, args) do
    # A room's own .git/config is the agent's to write, so nothing in it may
    # make the service run a program when the changes panel refreshes.
    case System.cmd("git", ["--no-optional-locks", "-C", directory] ++ args ++ no_external(args),
           stderr_to_stdout: true,
           env: overrides(directory)
         ) do
      {output, 0} -> {:ok, String.trim_trailing(output)}
      {output, _} -> {:error, first_line(output)}
    end
  rescue
    # No git on PATH, or the directory disappeared under us.
    error -> {:error, Exception.message(error)}
  end

  # A filter named in .git/config and switched on by .gitattributes or
  # .git/info/attributes runs on status and diff, and no flag turns filters off
  # wholesale. So each configured filter is emptied for the call. Only key names
  # are read, never values. The overrides go through GIT_CONFIG_PARAMETERS in
  # git's quoted 'key'='value' form: -c splits a filter name containing "=",
  # and an empty GIT_CONFIG_VALUE_n never reaches git from an Erlang port.
  defp overrides(directory) do
    settings =
      [{"core.fsmonitor", "false"}] ++
        for name <- filter_names(directory),
            {key, value} <- [clean: "", smudge: "", process: "", required: "false"],
            do: {"filter.#{name}.#{key}", value}

    [{"GIT_CONFIG_PARAMETERS", Enum.map_join(settings, " ", &quoted/1)}]
  end

  defp quoted({key, value}), do: "#{quote_part(key)}=#{quote_part(value)}"
  defp quote_part(text), do: "'" <> String.replace(text, "'", ~S"'\''") <> "'"

  defp filter_names(directory) do
    args =
      ["--no-optional-locks", "-C", directory] ++
        ~w(config --null --name-only --get-regexp) ++ [~S"^filter\."]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split(<<0>>, trim: true)
        |> Enum.map(&subsection/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      _no_filters ->
        []
    end
  end

  # filter.<name>.<key>: the name is everything between the first and the last
  # dot, which may itself contain dots, spaces or "=".
  defp subsection("filter." <> rest) do
    case String.split(rest, ".") do
      [_key_only] -> nil
      parts -> parts |> Enum.drop(-1) |> Enum.join(".")
    end
  end

  defp subsection(_key), do: nil

  defp no_external(["diff" | _]), do: ["--no-ext-diff", "--no-textconv"]
  defp no_external(_args), do: []

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
