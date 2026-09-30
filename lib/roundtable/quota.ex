defmodule Roundtable.Quota do
  @moduledoc "Normalizes provider quota failures and chooses a durable retry time."
  alias Roundtable.Agents.Protocol

  @codes ~w(rate_limit rate_limit_error rate_limit_exceeded usage_limit_reached usage_limit_exceeded rateLimitExceeded usageLimitExceeded)
  @temporary ~r/rate[ _-]?limit|usage[ _-]?limit|quota (?:has been )?exceeded|too many requests|you(?:'|’)ve (?:hit|reached) your limit/i
  @permanent ~r/context (?:window|length)|maximum context|insufficient_quota|credit balance|billing|payment required|authentication|unauthorized/i

  def failure(error) do
    message = Protocol.error_message(error)

    if limited?(error, message) do
      {"rate_limited", %{message: message, resets_at: reset_value(error)}}
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
