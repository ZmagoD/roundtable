defmodule Roundtable.Supervision do
  @moduledoc """
  What the watchdog does with a turn that ended without finishing.

  Pure policy, kept apart from `Roundtable.Coordinator` so each rule can be read
  and tested on its own. The coordinator acts on the answer.
  """
  alias Roundtable.Agents.Protocol

  # Two restarts are enough to ride out a crash or a dropped connection; a third
  # failure of the same turn is a problem a person or the team head should see.
  @max_retries 2
  @gave_up 9

  # Silence this long from a running turn means it is stuck, not thinking: a
  # working turn reports tokens or output with every step.
  @silent_after 20 * 60

  # Nothing a retry can fix: the same turn would fail the same way.
  @permanent ~r/context (?:window|length)|maximum context|insufficient_quota|credit balance|billing|payment required|authentication|unauthorized|not logged in|log in|no folder to work in|permission requested/i

  # Turns queued behind one that failed are stopped with this, not the human's
  # "Stopped", so the watchdog can tell them apart: these wait on the failed
  # turn and go back in the queue when it is restarted.
  @held_back "Held back because an earlier turn of this participant failed. Retry to continue."

  def held_back, do: @held_back
  def max_retries, do: @max_retries
  def gave_up, do: @gave_up
  def silent_after, do: @silent_after

  @doc "Whether a running turn has gone quiet for long enough to be stopped."
  def silent?(%{status: "running", updated_at: updated_at}, now),
    do: DateTime.diff(now, updated_at) >= @silent_after

  def silent?(_run, _now), do: false

  @doc """
  The next step for a failed or interrupted turn:

    * `:wait` — leave it for now: given up already, or still backing off.
    * `{:quota, quota}` — the provider's usage limit; wait for its reset.
    * `{:retry, reason}` — restart it.
    * `{:give_up, reason}` — stop trying and tell the team head.
  """
  def decide(%{supervised_retries: retries}, _now) when retries >= @gave_up, do: :wait

  def decide(run, now) do
    error = run.error || "The turn ended without a reply."

    case Roundtable.Quota.failure(error) do
      {"rate_limited", quota} ->
        {:quota, quota}

      {"failed", message} ->
        cond do
          Regex.match?(@permanent, message) -> {:give_up, message}
          run.supervised_retries >= @max_retries -> {:give_up, message}
          backing_off?(run, now) -> :wait
          true -> {:retry, message}
        end
    end
  end

  # A minute, then two: long enough for a dropped connection to come back,
  # short enough that nobody is left waiting on a turn that only hiccupped.
  defp backing_off?(run, now),
    do: DateTime.diff(now, run.updated_at) < 60 * Integer.pow(2, run.supervised_retries)

  @doc "The first line of what a turn said, short enough for a notice."
  def gist(text) when is_binary(text) do
    text
    |> Protocol.error_message()
    |> String.split("\n", trim: true)
    |> List.first("")
    |> String.slice(0, 200)
  end

  def gist(_text), do: ""
end
