defmodule Roundtable.Quota do
  @moduledoc "Normalizes provider quota failures and chooses a durable retry time."
  alias Roundtable.Agents.Protocol

  @codes ~w(rate_limit rate_limit_error rate_limit_exceeded usage_limit_reached usage_limit_exceeded rateLimitExceeded usageLimitExceeded)
  @temporary ~r/rate[ _-]?limit|usage[ _-]?limit|quota (?:has been )?exceeded|too many requests|you(?:'|’)ve (?:hit|reached) your (?:usage )?limit/i
  @try_again ~r/try again at (\d{1,2}):(\d{2})(?:\s*(AM|PM))?/i
  @permanent ~r/context (?:window|length)|maximum context|insufficient_quota|credit balance|logged out|billing|payment required|authentication|unauthorized|too long/i

  def failure(error) do
    message = Protocol.error_message(error)

    if limited?(error, message) do
      {"rate_limited", %{message: message, resets_at: reset_value(error, message)}}
    else
      {"failed", message}
    end
  end

  defp limited?(error, message) when is_map(error) do
    error = if is_map(error["data"]), do: Map.merge(error, error["data"]), else: error
    code = error["codexErrorInfo"] || error["type"] || error["code"]

    cond do
      code in @codes ->
        true

      code in [
        "contextWindowExceeded",
        "sessionBudgetExceeded",
        "unauthorized",
        "insufficient_quota"
      ] ->
        false

      error["statusCode"] == 429 ->
        not Regex.match?(@permanent, message)

      true ->
        limited?(nil, message)
    end
  end

  defp limited?(_, message),
    do: Regex.match?(@temporary, message) and not Regex.match?(@permanent, message)

  # Files a retry deadline for the provider's wording as well as its events:
  # "You've hit your usage limit. Try again at 12:47 PM" carries the moment in
  # the message. The wall-clock tuple is turned into an absolute deadline by
  # `retry_at/3`, which already knows `now`.
  defp reset_value(error, message) when is_map(error),
    do: reset_value(error) || try_again(message)

  defp reset_value(_error, message), do: try_again(message)

  defp reset_value(error) when is_map(error), do: error["resetsAt"] || error["resets_at"]
  defp reset_value(_), do: nil

  @doc """
  A retry time written in a provider's message as a wall clock, or nothing.

  Kept as a tuple here rather than a timestamp: it names a time of day local
  to this machine, and turning it into an absolute moment is `retry_at/3`'s
  job, which knows the moment the turn ended.
  """
  def try_again(message) when is_binary(message) do
    case Regex.run(@try_again, message) do
      [_, h, m] ->
        {:wall, hour(h, m, nil), String.to_integer(m)}

      [_, h, m, meridiem] ->
        {:wall, hour(h, m, meridiem), String.to_integer(m)}

      _ ->
        nil
    end
  end

  defp hour(h, _m, nil), do: String.to_integer(h)

  defp hour(h, _m, meridiem) do
    h = String.to_integer(h)

    cond do
      h == 12 -> if String.upcase(meridiem) == "PM", do: 12, else: 0
      String.upcase(meridiem) == "PM" -> h + 12
      true -> h
    end
  end

  def retry_at(reset, count, now) do
    fallback = DateTime.add(now, min(900 * Integer.pow(2, min(count, 5)), 21_600), :second)

    case timestamp(reset, now) do
      {:ok, at} ->
        if DateTime.compare(at, now) == :gt,
          do: DateTime.add(at, 15, :second),
          else: fallback

      _ ->
        fallback
    end
  end

  defp timestamp({:wall, h, m}, now), do: {:ok, wall_deadline(h, m, now)}
  defp timestamp(value, _now) when is_integer(value), do: DateTime.from_unix(value)
  defp timestamp(_, _), do: :error

  # The provider names a time of day on this machine, so "the next 12:47 PM"
  # is measured against the machine's own clock and the gap from there is
  # added to `now`, which the rest of the scheduler already read as UTC.
  defp wall_deadline(h, m, now) do
    local_now = NaiveDateTime.local_now()
    target = %{local_now | hour: h, minute: m, second: 0}

    gap =
      if NaiveDateTime.compare(target, local_now) in [:gt, :eq] do
        NaiveDateTime.diff(target, local_now)
      else
        NaiveDateTime.diff(target, local_now) + 86_400
      end

    DateTime.add(now, gap, :second)
  end
end
