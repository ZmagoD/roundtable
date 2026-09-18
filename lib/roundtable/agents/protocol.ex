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

  defp optional(_, value) when value in [nil, ""], do: []
  defp optional(flag, value), do: [flag, value]

  def text_blocks(blocks) when is_list(blocks) do
    blocks |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join("\n", & &1["text"])
  end

  def text_blocks(_), do: ""
end
