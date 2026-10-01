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

  @doc """
  The reading a slot keeps when two reports compete for it.

  Claude sends its five-hour and weekly limits as separate events, and a room
  shows one reading per provider, so the window closer to its limit wins: a
  stricter status beats a calmer one, a higher percentage beats a lower one,
  and a fresher reading of the same window always replaces an older one, even
  when it looks better — after a reset the old warning must go. Codex reports
  both of its windows in a single event, so it arrives here already decided.
  """
  def keep(one, two) do
    cond do
      one == nil or two == nil -> two || one
      one["window"] == two["window"] -> two
      true -> across_windows(one, two)
    end
  end

  defp across_windows(one, two) do
    cond do
      strictness(one) > strictness(two) -> one
      strictness(one) < strictness(two) -> two
      one["percent"] == nil or two["percent"] == nil -> two
      one["percent"] >= two["percent"] -> one
      true -> two
    end
  end

  @doc "How loud a reading is: warning at 80% or more, `near limit` or `limited`."
  def level(%{data: data}), do: level(data)
  def level(%{"percent" => n}) when is_number(n) and n >= 80, do: "warn"
  def level(%{"status" => status}) when status in ["near limit", "limited"], do: "warn"
  def level(_), do: "ok"

  defp strictness(%{"status" => "limited"}), do: 3
  defp strictness(%{"status" => "near limit"}), do: 2
  defp strictness(_), do: 0

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
