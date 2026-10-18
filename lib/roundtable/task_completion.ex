defmodule Roundtable.TaskCompletion do
  @moduledoc "Fresh, fail-closed Git and GitHub evidence for managed task completion."

  def verify(room) do
    review = room.completion_review

    with :ok <- review_present(review),
         {:ok, record} <- Roundtable.TaskCheckouts.inspect_owned(room.checkout_id, room.directory),
         {:ok, head} <- git(room.directory, ["rev-parse", "HEAD"]),
         :ok <-
           ensure(head == review["sha"], "The reviewed commit is no longer the checkout HEAD."),
         {:ok, ""} <- git(room.directory, ["status", "--porcelain"]),
         {:ok, branch} <- git(room.directory, ["branch", "--show-current"]),
         :ok <- ensure(branch == record.branch, "The task branch changed."),
         {:ok, repo} <- repository(record.remote),
         {:ok, pr} <- json("gh", ["api", "repos/#{repo}/pulls/#{review["pr"]}"], room.directory),
         :ok <- verify_pr(pr, repo, branch, head),
         {:ok, checks} <-
           json(
             "gh",
             [
               "pr",
               "checks",
               to_string(review["pr"]),
               "--repo",
               repo,
               # Every check on the PR, not only required ones: a repository
               # without branch protection has none required, and that must
               # not read as "nothing to wait for" or as an error.
               "--json",
               "name,bucket,link"
             ],
             room.directory
           ),
         :ok <- verify_checks(checks),
         {:ok, _} <- git(room.directory, ["fetch", "--no-tags", record.remote, "refs/heads/main"]),
         {:ok, main} <- git(room.directory, ["rev-parse", "FETCH_HEAD"]),
         {:ok, _} <-
           git(room.directory, ["merge-base", "--is-ancestor", pr["merge_commit_sha"], main]),
         :ok <- synchronized(review, record.source, main) do
      {:ok,
       %{
         "repository" => repo,
         "pr" => review["pr"],
         "url" => pr["html_url"],
         "sha" => head,
         "merge_sha" => pr["merge_commit_sha"],
         "main_sha" => main,
         "checks" => checks,
         "review" => review,
         "verified_at" => DateTime.to_iso8601(DateTime.utc_now())
       }}
    else
      {:ok, _} -> {:error, "The checkout has unfinished changes."}
      {:error, reason} -> {:error, reason}
    end
  end

  def review_present(review) do
    ensure(
      is_map(review) and commit?(review["sha"]) and is_integer(review["pr"]) and
        review["pr"] > 0 and text?(review["precommit"]) and text?(review["policy"]) and
        review["accepted_by"] != nil,
      "Record driver acceptance, precommit evidence and parent policy for the final commit first."
    )
  end

  defp commit?(sha), do: is_binary(sha) and Regex.match?(~r/^[0-9a-f]{40}$/, sha)
  defp text?(value), do: is_binary(value) and String.trim(value) != ""

  def verify_pr(pr, repo, branch, head) do
    ensure(
      pr["merged"] == true and is_binary(pr["merge_commit_sha"]) and
        get_in(pr, ["base", "ref"]) == "main" and
        get_in(pr, ["base", "repo", "full_name"]) == repo and
        get_in(pr, ["head", "repo", "full_name"]) == repo and
        get_in(pr, ["head", "ref"]) == branch and get_in(pr, ["head", "sha"]) == head,
      "The associated PR must be merged into main with this exact final task commit."
    )
  end

  def verify_checks(checks) do
    ensure(
      is_list(checks) and checks != [] and Enum.all?(checks, &(&1["bucket"] == "pass")),
      "The PR checks are missing, pending or unsuccessful."
    )
  end

  defp synchronized(%{"sync_main" => true}, source, main) do
    with {:ok, "main"} <- git(source, ["branch", "--show-current"]),
         {:ok, ^main} <- git(source, ["rev-parse", "HEAD"]),
         {:ok, ""} <- git(source, ["status", "--porcelain"]),
         do: :ok,
         else: (_ -> {:error, "Synchronize the clean parent checkout to main before closing."})
  end

  defp synchronized(_, _, _), do: :ok

  defp repository(remote) do
    case Regex.run(
           ~r/^(?:https:\/\/github\.com\/|git@github\.com:)([^\/]+\/[^\/]+?)(?:\.git)?$/,
           remote
         ) do
      [_, repo] -> {:ok, repo}
      _ -> {:error, "Completion requires the original GitHub repository remote."}
    end
  end

  defp ensure(true, _), do: :ok
  defp ensure(_, reason), do: {:error, reason}

  defp git(path, args),
    do: command("git", ["-c", "core.hooksPath=/dev/null", "-C", path] ++ args, path)

  defp json(program, args, path) do
    with {:ok, output} <- command(program, args, path),
         {:ok, value} <- Jason.decode(output),
         do: {:ok, value},
         else: (_ ->
                  {:error, "GitHub verification is unavailable or returned incomplete evidence."})
  end

  defp command(program, args, path) do
    runner = Application.get_env(:roundtable, :completion_command, &System.cmd/3)

    case runner.(program, args,
           cd: path,
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}]
         ) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {_, _} ->
        {:error,
         "#{program} verification failed; keep the task room and retry after resolving it."}
    end
  rescue
    _ -> {:error, "#{program} verification is unavailable. The task was left in place."}
  end
end
