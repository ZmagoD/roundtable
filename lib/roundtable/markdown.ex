defmodule Roundtable.Markdown do
  @moduledoc """
  The Markdown that agents write, parsed for browser rendering.

  Agent replies are mostly prose with headings, bullets and fenced code, and
  showing that raw — `##`, backticks, ``` — is showing the punctuation instead
  of the text. This renders the structure and drops the markers.
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

  @doc "Strips inline markers that only make sense when they are rendered."
  def plain(text) do
    text
    |> String.replace(~r/`([^`]+)`/, "\\1")
    |> String.replace(~r/\*\*([^*]+)\*\*/, "\\1")
  end
end
