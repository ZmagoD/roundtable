defmodule Roundtable.CompletionFixture do
  @moduledoc """
  Stands in for GitHub in completion tests. Git runs for real against a local
  bare repository that the fixture presents as the project's GitHub remote;
  `gh` answers from fixtures the test sets, so no network or account is used.
  """
  alias Roundtable.Chat

  @repo "octo/roundtable"
  @url "https://github.com/octo/roundtable.git"

  def url, do: @url

  def install(remote) do
    previous = Application.get_env(:roundtable, :completion_command)
    Application.put_env(:roundtable, :completion_command, runner(remote))
    Application.put_env(:roundtable, :completion_gh, %{})

    fn ->
      Application.delete_env(:roundtable, :completion_gh)

      if previous,
        do: Application.put_env(:roundtable, :completion_command, previous),
        else: Application.delete_env(:roundtable, :completion_command)
    end
  end

  # Replaces the one URL the fixture claims is GitHub with the bare repository.
  defp runner(remote) do
    fn
      "git", args, opts ->
        System.cmd("git", Enum.map(args, &if(&1 == @url, do: remote, else: &1)), opts)

      "gh", args, _opts ->
        case Application.get_env(:roundtable, :completion_gh, %{})[hd(args)] do
          nil -> {"gh: unavailable", 1}
          {:error, output} -> {output, 1}
          value -> {Jason.encode!(value), 0}
        end
    end
  end

  def gh(key, value),
    do:
      Application.put_env(
        :roundtable,
        :completion_gh,
        Map.put(Application.get_env(:roundtable, :completion_gh, %{}), key, value)
      )

  def git(path, args) do
    # CI runners have no git identity, so commits made here would be refused.
    identity = ["-c", "user.name=Roundtable Test", "-c", "user.email=test@roundtable.local"]
    {output, 0} = System.cmd("git", identity ++ ["-C", path] ++ args, stderr_to_stdout: true)
    String.trim(output)
  end

  @doc "Publishes the task branch and fast-forwards main to it, as a merged PR would."
  def merge(task, remote) do
    git(task.directory, ["push", remote, "#{task.checkout_branch}:#{task.checkout_branch}"])
    git(task.directory, ["push", remote, "#{task.checkout_branch}:main"])
    head = git(task.directory, ["rev-parse", "HEAD"])
    announce(task, head, head)
    head
  end

  @doc "What the fake GitHub says about the pull request and its required checks."
  def announce(task, head, merge_sha, overrides \\ %{}) do
    pr = %{
      "merged" => true,
      "merge_commit_sha" => merge_sha,
      "html_url" => "https://github.com/#{@repo}/pull/7",
      "base" => %{"ref" => "main", "repo" => %{"full_name" => @repo}},
      "head" => %{
        "ref" => task.checkout_branch,
        "sha" => head,
        "repo" => %{"full_name" => @repo}
      }
    }

    gh("api", Map.merge(pr, overrides))
    gh("pr", [%{"name" => "test", "bucket" => "pass", "link" => "https://ci.example/1"}])
  end

  def evidence(sha, extra \\ %{}) do
    Map.merge(
      %{
        "sha" => sha,
        "pr" => 7,
        "precommit" => "mix precommit: 0 failures",
        "policy" => "main synchronised by the driver"
      },
      extra
    )
  end

  def accept(task, sha, extra \\ %{}), do: Chat.accept_task(task.id, evidence(sha, extra))
end
