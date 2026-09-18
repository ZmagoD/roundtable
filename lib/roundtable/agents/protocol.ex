defmodule Roundtable.Agents.Protocol do
  @moduledoc "Normalizes provider events without shell or terminal scraping."
  def command(%{provider: "codex"}), do: {"codex", ["app-server"]}

  def command(%{provider: "claude"} = a) do
    args = [
      "-p",
      "--verbose",
      "--output-format",
      "stream-json",
      "--input-format",
      "stream-json",
      "--include-partial-messages",
      "--permission-mode",
      "default",
      "--permission-prompt-tool",
      "stdio"
    ]

    {"claude", args ++ optional("--resume", a.session_id) ++ optional("--model", a.model)}
  end

  def command(%{provider: "opencode"} = a) do
    {"opencode",
     ["run", "--format", "json"] ++
       optional("--session", a.session_id) ++ optional("--model", a.model)}
  end

  @doc "A flag and its value, or nothing: an empty value would be a parse error."
  def optional(_flag, value) when value in [nil, ""], do: []
  def optional(flag, value), do: [flag, value]

  @doc """
  A sentence a person can act on, out of whatever a provider called an error.

  Providers report failures as nested objects — an API error arrives with
  headers, a request id and a response body around the one line that says what
  went wrong. Inspecting the whole thing puts a wall of metadata where an
  explanation belongs, so this digs out the message and says what the status
  was, and only falls back to inspecting when there is nothing better.
  """
  def error_message(error)

  def error_message(error) when is_binary(error), do: error

  def error_message(%{} = error) when not is_struct(error) do
    # The useful part is often one level in, under "data".
    inner = if is_map(error["data"]), do: error["data"], else: error

    case sentence(inner) || sentence(error) do
      nil -> inspect(error)
      message -> with_status(message, inner["statusCode"] || error["statusCode"])
    end
  end

  def error_message(error), do: inspect(error)

  defp sentence(%{} = error) do
    [error["message"], error["error"], trimmed(error["responseBody"]), error["name"]]
    |> Enum.find(&(is_binary(&1) and &1 != ""))
  end

  defp with_status(message, status) when is_integer(status), do: "#{message} (HTTP #{status})"
  defp with_status(message, _status), do: message

  defp trimmed(body) when is_binary(body) do
    case String.trim(body) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_body), do: nil

  def text_blocks(blocks) when is_list(blocks) do
    blocks |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join("\n", & &1["text"])
  end

  def text_blocks(_), do: ""
end
