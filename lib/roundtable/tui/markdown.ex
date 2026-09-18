defmodule Roundtable.TUI.Markdown do
  @moduledoc """
  The little of Markdown that agents actually write, turned into lines.

  Agent replies are mostly prose with headings, bullets and fenced code, and
  showing that raw — `##`, backticks, ``` — is showing the punctuation instead
  of the text. This renders the structure and drops the markers.

  It wraps on words. Breaking mid-word to fill a column makes every reply look
  corrupted, which is what the client did before.
  """

  @doc """
  Splits a body into blocks.

  Blocks are `{:heading, text}`, `{:bullet, text}`, `{:code, language, lines}`
  or `{:text, text}`. A blank line separates paragraphs and is kept, because
  the shape of a reply carries meaning.
  """
  def blocks(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> parse([], nil)
    |> Enum.reverse()
  end

  defp parse([], acc, nil), do: acc

  # An unterminated fence still has to render; the turn may have been cut off.
  defp parse([], acc, {language, lines}), do: [{:code, language, Enum.reverse(lines)} | acc]

  defp parse([line | rest], acc, nil) do
    cond do
      fence = fence_language(line) ->
        parse(rest, acc, {fence, []})

      heading = heading_text(line) ->
        parse(rest, [{:heading, heading} | acc], nil)

      bullet = bullet_text(line) ->
        parse(rest, [{:bullet, bullet} | acc], nil)

      String.trim(line) == "" ->
        parse(rest, [:blank | acc], nil)

      true ->
        parse(rest, [{:text, String.trim_trailing(line)} | acc], nil)
    end
  end

  defp parse([line | rest], acc, {language, lines}) do
    if fence?(line),
      do: parse(rest, [{:code, language, Enum.reverse(lines)} | acc], nil),
      else: parse(rest, acc, {language, [String.trim_trailing(line) | lines]})
  end

  defp fence?(line), do: String.starts_with?(String.trim_leading(line), "```")

  defp fence_language(line) do
    trimmed = String.trim_leading(line)

    if String.starts_with?(trimmed, "```"),
      do: trimmed |> String.trim_leading("`") |> String.trim(),
      else: nil
  end

  defp heading_text(line) do
    case Regex.run(~r/^\s{0,3}(\#{1,6})\s+(.+)$/, line) do
      [_, _, text] -> String.trim(text)
      _ -> nil
    end
  end

  defp bullet_text(line) do
    case Regex.run(~r/^\s{0,4}[-*+]\s+(.+)$/, line) do
      [_, text] -> String.trim(text)
      _ -> nil
    end
  end

  @doc """
  Wraps text on word boundaries.

  A word longer than the line — a path, a URL — is broken, because the
  alternative is a line that overflows and corrupts the frame.
  """
  def wrap(text, width) when width > 0 do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce([], fn word, lines ->
      case lines do
        [] -> Enum.reverse(split_word(word, width))
        [current | rest] -> place(word, current, rest, width)
      end
    end)
    |> Enum.reverse()
    |> case do
      [] -> [""]
      lines -> lines
    end
  end

  def wrap(_text, _width), do: [""]

  defp place(word, current, rest, width) do
    if String.length(current) + 1 + String.length(word) <= width do
      [current <> " " <> word | rest]
    else
      Enum.reverse(split_word(word, width)) ++ [current | rest]
    end
  end

  defp split_word(word, width) do
    if String.length(word) <= width do
      [word]
    else
      word
      |> String.graphemes()
      |> Enum.chunk_every(width)
      |> Enum.map(&Enum.join/1)
    end
  end

  @doc "Strips inline markers that only make sense when they are rendered."
  def plain(text) do
    text
    |> String.replace(~r/`([^`]+)`/, "\\1")
    |> String.replace(~r/\*\*([^*]+)\*\*/, "\\1")
  end
end
