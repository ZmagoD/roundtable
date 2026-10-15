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
  An expired reading never wins over a reading whose reset has not passed.
  """
  def keep(one, two) do
    cond do
      stale?(one) -> two || one
      stale?(two) -> one || two
      true -> keep_current(one, two)
    end
  end

  defp keep_current(one, two) do
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

  @doc "A quota observation expires at its provider-reported Unix reset time."
  def stale?(%{data: data}), do: stale?(data)

  def stale?(%{"resets_at" => reset}) when is_integer(reset),
    do: reset <= System.system_time(:second)

  def stale?(_), do: false

  @doc "How loud a current reading is: warning at 80% or more, `near limit` or `limited`."
  def level(%{data: data}), do: level(data)
  def level(reading), do: if(stale?(reading), do: "ok", else: reading_level(reading))

  defp reading_level(%{"percent" => n}) when is_number(n) and n >= 80, do: "warn"
  defp reading_level(%{"status" => status}) when status in ["near limit", "limited"], do: "warn"
  defp reading_level(_), do: "ok"

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

  def label(%{data: data}), do: label(data)
  def label(reading), do: if(stale?(reading), do: "not reported", else: reading_label(reading))

  @doc "The percentage left, formatted for display."
  def left_label(%{data: data}), do: left_label(data)

  def left_label(reading),
    do: if(stale?(reading), do: "not reported", else: reading_left_label(reading))

  @doc "The percentage left as an integer 0-100, or nil if not available."
  def left_percent(%{data: data}), do: left_percent(data)
  def left_percent(reading), do: if(stale?(reading), do: nil, else: reading_left_percent(reading))

  @doc "The window label for display, or nil if not available."
  def window_label(%{data: data}), do: window_label(data)
  def window_label(%{"window" => "five_hours"}), do: "5-hour window"
  def window_label(%{"window" => "seven_day"}), do: "weekly window"
  # Codex names its windows by rank, not length; primary is the shorter one.
  def window_label(%{"window" => "primary"}), do: "short window"
  def window_label(%{"window" => "secondary"}), do: "long window"
  def window_label(_), do: nil

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

  defp reading_label(%{"percent" => n}) when is_number(n), do: "#{Float.round(n / 1, 1)}%"

  defp reading_label(%{"status" => status}) when status in ["OK", "near limit", "limited"],
    do: status

  defp reading_label(_), do: "not reported"

  defp reading_left_label(%{"percent" => n}) when is_number(n),
    do: "#{reading_left_percent(%{"percent" => n})}% left"

  defp reading_left_label(%{"status" => status}) when status in ["OK", "near limit", "limited"],
    do: status

  defp reading_left_label(_), do: "not reported"

  defp reading_left_percent(%{"percent" => n}) when is_number(n),
    do: (100 - n) |> round() |> max(0) |> min(100)

  defp reading_left_percent(_), do: nil

  defp percent(n) when is_number(n) and n >= 0, do: Float.round(n * 100.0, 6)
  defp percent(_), do: nil
  defp integer(n) when is_integer(n) and n >= 0, do: n
  defp integer(_), do: nil
  defp status("allowed"), do: "OK"
  defp status("allowed_warning"), do: "near limit"
  defp status("rejected"), do: "limited"
  defp status(_), do: nil
end
