defmodule Roundtable.Quota do
  @moduledoc "Normalizes provider quota failures and chooses a durable retry time."
  alias Roundtable.Agents.Protocol

  @codes ~w(rate_limit rate_limit_error rate_limit_exceeded usage_limit_reached usage_limit_exceeded rateLimitExceeded usageLimitExceeded)
  @temporary ~r/rate[ _-]?limit|usage[ _-]?limit|quota (?:has been )?exceeded|too many requests|you(?:'|’)ve (?:hit|reached) your limit/i
  @permanent ~r/context (?:window|length)|maximum context|insufficient_quota|credit balance|billing|payment required|authentication|unauthorized/i

  def failure(error) do
    message = Protocol.error_message(error)

    if limited?(error, message) do
      {"rate_limited", %{message: message, resets_at: reset_value(error) || clock_reset(message)}}
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

  defp reset_value(error) when is_map(error),
    do: error["resetsAt"] || error["resets_at"]

  defp reset_value(_), do: nil

  @doc """
  The reset time a provider gives only as a wall-clock time in its message, such
  as Codex's "try again at 12:47 PM", as a Unix timestamp.

  The clock is the machine's own, as the CLI printing it runs here. A time that
  has already passed today means tomorrow.
  """
  def clock_reset(message, now \\ :calendar.local_time())

  def clock_reset(message, {today, _} = now) when is_binary(message) do
    case Regex.run(~r/try again at (\d{1,2}):(\d{2})\s*([AP]M)?/i, message) do
      [_, hour, minute | meridiem] ->
        time = {to_24h(String.to_integer(hour), meridiem), String.to_integer(minute), 0}
        day = if {today, time} > now, do: today, else: next_day(today)
        unix({day, time})

      nil ->
        nil
    end
  end

  def clock_reset(_message, _now), do: nil

  defp to_24h(12, [meridiem]), do: if(String.upcase(meridiem) == "AM", do: 0, else: 12)

  defp to_24h(hour, [meridiem]),
    do: if(String.upcase(meridiem) == "PM", do: hour + 12, else: hour)

  defp to_24h(hour, _), do: hour

  defp next_day(date),
    do:
      date
      |> :calendar.date_to_gregorian_days()
      |> Kernel.+(1)
      |> :calendar.gregorian_days_to_date()

  @unix_epoch 62_167_219_200

  defp unix(local) do
    case :calendar.local_time_to_universal_time_dst(local) do
      [utc | _] -> :calendar.datetime_to_gregorian_seconds(utc) - @unix_epoch
      [] -> nil
    end
  end

  def retry_at(reset, count, now) do
    fallback = DateTime.add(now, min(900 * Integer.pow(2, min(count, 5)), 21_600), :second)

    case timestamp(reset) do
      {:ok, at} ->
        if DateTime.compare(at, now) == :gt,
          do: DateTime.add(at, 15, :second),
          else: fallback

      _ ->
        fallback
    end
  end

  defp timestamp(value) when is_integer(value), do: DateTime.from_unix(value)
  defp timestamp(_), do: :error
end
