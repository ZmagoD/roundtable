defmodule Roundtable.Usage do
  @moduledoc "Reported token counts and quota snapshots; absent fields stay unknown."

  @token_keys ~w(input output cached cache_write)

  def tokens(value, fields) when is_map(value) do
    Map.new(
      for {key, native} <- fields, n = value[native], is_integer(n) and n >= 0, do: {key, n}
    )
  end

  def tokens(_, _fields), do: %{}

  def valid_tokens(value), do: tokens(value, Enum.map(@token_keys, &{&1, &1}))

  def sum(values) do
    Enum.reduce(values, %{}, fn value, acc ->
      Map.merge(acc, valid_tokens(value), fn _key, a, b -> a + b end)
    end)
  end

  def claude_tokens(value),
    do:
      tokens(value, [
        {"input", "input_tokens"},
        {"output", "output_tokens"},
        {"cached", "cache_read_input_tokens"},
        {"cache_write", "cache_creation_input_tokens"}
      ])

  def codex_tokens(value),
    do:
      tokens(value, [
        {"input", "inputTokens"},
        {"output", "outputTokens"},
        {"cached", "cachedInputTokens"},
        {"cache_write", "cacheWriteInputTokens"}
      ])

  def claude_limit(info) do
    %{
      "percent" => percent(info["utilization"]),
      "status" => status(info["status"]),
      "resets_at" => integer(info["resetsAt"]),
      "window" => info["rateLimitType"]
    }
  end

  def codex_limit(limits) do
    windows =
      for key <- ~w(primary secondary),
          is_map(limits[key]),
          used = limits[key]["usedPercent"],
          is_number(used) and used >= 0,
          do: {key, limits[key]}

    case Enum.max_by(windows, fn {_, window} -> window["usedPercent"] end, fn -> nil end) do
      nil ->
        %{}

      {key, window} ->
        %{
          "percent" => window["usedPercent"],
          "window" => key,
          "resets_at" => integer(window["resetsAt"])
        }
    end
  end

  def label(nil), do: "not reported"
  def label(%{data: data}), do: label(data)
  def label(%{"percent" => n}) when is_number(n), do: "#{Float.round(n / 1, 1)}%"
  def label(%{"status" => status}) when status in ["OK", "near limit", "limited"], do: status
  def label(_), do: "not reported"

  def token_label(usage) when map_size(usage) == 0, do: "not reported"

  def token_label(usage) do
    Enum.map_join(
      [
        {"input", "input"},
        {"output", "output"},
        {"cached", "cached"},
        {"cache_write", "cache write"}
      ],
      " · ",
      fn {key, label} ->
        "#{Map.get(usage, key, "not reported")} #{label}"
      end
    )
  end

  defp percent(n) when is_number(n) and n >= 0, do: Float.round(n * 100.0, 6)
  defp percent(_), do: nil
  defp integer(n) when is_integer(n) and n >= 0, do: n
  defp integer(_), do: nil
  defp status("allowed"), do: "OK"
  defp status("allowed_warning"), do: "near limit"
  defp status("rejected"), do: "limited"
  defp status(_), do: nil
end
