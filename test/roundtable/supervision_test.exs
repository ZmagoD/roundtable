defmodule Roundtable.SupervisionTest do
  use ExUnit.Case, async: true
  alias Roundtable.Chat.Run
  alias Roundtable.Supervision

  @now ~U[2026-10-01 10:00:00Z]

  defp run(attrs) do
    struct(
      %Run{status: "failed", supervised_retries: 0, updated_at: ~U[2026-10-01 09:50:00Z]},
      attrs
    )
  end

  test "a crash is retried, after a backoff that doubles with each attempt" do
    assert {:retry, _} = Supervision.decide(run(error: "Agent process exited: :killed"), @now)

    recent = run(error: "connection reset", updated_at: ~U[2026-10-01 09:59:30Z])
    assert Supervision.decide(recent, @now) == :wait

    second =
      run(error: "connection reset", supervised_retries: 1, updated_at: ~U[2026-10-01 09:58:30Z])

    assert Supervision.decide(second, @now) == :wait

    assert {:retry, _} =
             Supervision.decide(%{second | updated_at: ~U[2026-10-01 09:57:00Z]}, @now)
  end

  test "an interrupted turn with no error is retried too" do
    assert {:retry, _} = Supervision.decide(run(status: "interrupted", error: nil), @now)
  end

  test "after two restarts the third failure goes to a person" do
    assert {:give_up, _} = Supervision.decide(run(error: "boom", supervised_retries: 2), @now)
  end

  test "errors a retry cannot fix are never retried" do
    for error <- [
          "Authentication failed",
          "Context window exceeded",
          "Credit balance too low",
          "The team has no folder to work in. Give this team or its project a folder, then retry.",
          "OpenCode exited (0). ! permission requested: external_directory (/tmp/*); auto-rejecting"
        ] do
      assert {:give_up, _} = Supervision.decide(run(error: error), @now)
    end
  end

  test "a usage limit waits for the provider rather than retrying" do
    assert {:quota, %{resets_at: _}} =
             Supervision.decide(
               run(error: "You've hit your usage limit. Try again at 12:47 PM."),
               @now
             )
  end

  test "a turn given up on stays given up" do
    assert Supervision.decide(run(error: "boom", supervised_retries: Supervision.gave_up()), @now) ==
             :wait
  end

  test "only a running turn can be silent, and only after twenty minutes" do
    quiet = %Run{status: "running", updated_at: ~U[2026-10-01 09:39:00Z]}
    assert Supervision.silent?(quiet, @now)
    refute Supervision.silent?(%{quiet | updated_at: ~U[2026-10-01 09:45:00Z]}, @now)
    refute Supervision.silent?(%{quiet | status: "approval"}, @now)
  end

  test "a notice quotes only the first line of a reply" do
    assert Supervision.gist("Done.\nFiles: a, b") == "Done."
    assert Supervision.gist(nil) == ""
  end
end
