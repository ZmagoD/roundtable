defmodule Roundtable.TaskCheckouts do
  @moduledoc """
  Independent Git clones owned by task rooms. The source is only ever read.
  Ownership records live outside the clone so normal Git operations cannot erase them.
  """

  def root do
    Application.get_env(
      :roundtable,
      :task_checkout_root,
      Path.join(System.user_home!(), ".local/share/roundtable/checkouts")
    )
    |> Path.expand()
  end

  def create(source) do
    :global.trans({{__MODULE__, root()}, self()}, fn -> create_locked(source) end)
  end

  defp create_locked(source) do
    with :ok <- safe_root(),
         :ok <- capacity(),
         {:ok, top} <- git(source, ["rev-parse", "--show-toplevel"]),
         true <- Path.expand(source) == top,
         {:ok, remote} <- git(source, ["remote", "get-url", "--push", "origin"]) do
      id = "#{System.system_time(:second)}-#{Ecto.UUID.generate()}"
      path = Path.join(root(), id)
      branch = "roundtable/task-#{id}"
      record = %{id: id, source: top, path: path, branch: branch, remote: remote}
      File.write!(manifest(id), Jason.encode!(record), [:exclusive])

      result =
        with {:ok, _} <- git(root(), ["clone", "--no-local", "--", top, path]),
             {:ok, _} <- git(path, ["remote", "set-url", "origin", remote]),
             {:ok, _} <- git(path, ["checkout", "-b", branch]),
             do: {:ok, record}

      case result do
        {:ok, _} ->
          result

        error ->
          discard_new(record)
          error
      end
    else
      false -> {:error, "Choose the root of a Git repository for this task."}
      error -> error
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc false
  def discard_new(record) do
    if File.exists?(record.path) do
      remove(record)
    else
      with :ok <- safe_root(),
           true <- record.path == Path.join(root(), record.id),
           {:ok, data} <- File.read(manifest(record.id)),
           {:ok, stored} <- Jason.decode(data),
           true <- stored["path"] == record.path,
           do: File.rm(manifest(record.id))
    end
  end

  def finish(id, path) do
    with {:ok, record} <- owned(id, path),
         {:ok, %{entries: []}} <- Roundtable.Git.status(path),
         {:ok, branch} <- git(path, ["branch", "--show-current"]),
         true <- branch == record.branch,
         {:ok, head} <- git(path, ["rev-parse", "HEAD"]),
         {:ok, remote} <-
           git(path, ["ls-remote", "--exit-code", record.remote, "refs/heads/#{branch}"]),
         true <- String.starts_with?(remote, head <> "\t") do
      remove(record)
    else
      {:ok, %{entries: _}} ->
        {:error, "Commit and push the remaining changes before finishing this task."}

      false ->
        {:error, "Push the task branch to its original remote before finishing this task."}

      error ->
        error
    end
  end

  def finish_verified(id, path, head) do
    :global.trans({{__MODULE__, id}, self()}, fn ->
      quarantine = path <> ".closing"

      with :ok <- safe_root(),
           true <- is_binary(id) and Regex.match?(~r/^\d+-[a-f0-9-]{36}$/, id),
           true <- path == Path.join(root(), id),
           {:ok, data} <- File.read(manifest(id)),
           {:ok, record} <- Jason.decode(data),
           true <- record["path"] == path and record["id"] == id and record["source"] != path do
        finish_owned(record, quarantine, head)
      else
        _ -> {:error, "Cleanup ownership evidence is missing. The folder was left in place."}
      end
    end)
  end

  defp finish_owned(%{"cleanup_head" => head} = record, quarantine, head) do
    cond do
      File.exists?(record["path"]) ->
        {:error, "A checkout exists after cleanup started. Inspect it before retrying."}

      record["cleanup_verified"] == true ->
        remove_quarantine(quarantine)

      true ->
        verify_quarantine(record, quarantine, head)
    end
  end

  defp finish_owned(record, quarantine, head) do
    with {:ok, _} <- owned(record["id"], record["path"]),
         {:ok, ^head} <- git(record["path"], ["rev-parse", "HEAD"]),
         {:ok, ""} <- git(record["path"], ["status", "--porcelain"]),
         false <- File.exists?(quarantine),
         :ok <- File.rename(record["path"], quarantine),
         :ok <- File.write(manifest(record["id"]), Jason.encode!(Map.put(record, "cleanup_head", head))) do
      verify_quarantine(record, quarantine, head)
    else
      _ -> {:error, "The checkout changed or cleanup could not start. Work was preserved."}
    end
  end

  defp verify_quarantine(record, quarantine, head) do
    with {:ok, %{type: :directory}} <- File.lstat(quarantine),
         {:ok, ^head} <- git(quarantine, ["rev-parse", "HEAD"]),
         {:ok, ""} <- git(quarantine, ["status", "--porcelain"]),
         :ok <- File.write(manifest(record["id"]), Jason.encode!(Map.merge(record,
           %{"cleanup_head" => head, "cleanup_verified" => true}))) do
      remove_quarantine(quarantine)
    else
      _ -> {:error, "Cleanup paused: inspect the preserved .closing checkout for new work."}
    end
  end

  defp remove_quarantine(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %{type: :directory}} ->
        case File.rm_rf(path) do
          {:ok, _} -> :ok
          _ -> {:error, "Checkout cleanup failed; its audit is retained. Retry to continue."}
        end
      _ -> {:error, "The cleanup folder was replaced. It was left in place."}
    end
  end

  def inspect_owned(id, path), do: owned(id, path)

  defp owned(id, path) when is_binary(id) do
    with true <- Regex.match?(~r/^\d+-[a-f0-9-]{36}$/, id),
         :ok <- safe_root(),
         true <- path == Path.join(root(), id),
         {:ok, %{type: :directory}} <- File.lstat(path),
         {:ok, data} <- File.read(manifest(id)),
         {:ok, record} <- Jason.decode(data),
         true <- record["id"] == id and record["path"] == path and record["source"] != path do
      {:ok,
       %{
         id: id,
         path: path,
         source: record["source"],
         branch: record["branch"],
         remote: record["remote"]
       }}
    else
      _ -> {:error, "This folder is not an owned task checkout. It was left in place."}
    end
  end

  defp remove(record) do
    with {:ok, _} <- owned(record.id, record.path),
         {:ok, _} <- File.rm_rf(record.path) do
      File.rm(manifest(record.id))
    end
  end

  defp manifest(id), do: Path.join(root(), id <> ".json")

  defp safe_root do
    # Refuse symlink ancestors as well as a replaced checkout itself: cleanup
    # must never follow an alias into the original project.
    paths = Path.split(root()) |> Enum.scan(&Path.join(&2, &1))

    if Enum.any?(paths, &match?({:ok, %{type: :symlink}}, File.lstat(&1))) do
      {:error, "The task checkout storage path must not contain symbolic links."}
    else
      File.mkdir_p(root())
    end
  end

  defp capacity do
    limit = Application.get_env(:roundtable, :task_checkout_limit, 8)

    if length(Enum.reject(Path.wildcard(Path.join(root(), "*.json")), &completed_manifest?/1)) < limit,
      do: :ok,
      else:
        {:error,
         "The #{limit} task checkout slots are in use. Finish a task before starting another."}
  end

  defp completed_manifest?(path) do
    with {:ok, data} <- File.read(path),
         {:ok, %{"cleanup_verified" => true, "path" => checkout}} <- Jason.decode(data) do
      not File.exists?(checkout) and not File.exists?(checkout <> ".closing")
    else
      _ -> false
    end
  end

  defp git(directory, args) do
    case System.cmd("git", ["-c", "core.hooksPath=/dev/null", "-C", directory] ++ args,
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}]
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, String.slice(String.trim(output), 0, 1000)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end
end
