defmodule Roundtable.Agents.Protocol do
  @moduledoc "Normalizes provider events without shell or terminal scraping."
  alias Roundtable.MCP

  # Where a provider that cannot take a secret on the command line reads it.
  @token_variable "ROUNDTABLE_MCP_TOKEN"

  # Overrides come before the subcommand, which is where codex looks for them.
  def command(%{provider: "codex"} = a), do: {"codex", tools(a) ++ ["app-server"]}

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

    {"claude",
     args ++ optional("--resume", a.session_id) ++ optional("--model", a.model) ++ tools(a)}
  end

  def command(%{provider: "opencode"} = a) do
    {"opencode",
     ["run", "--format", "json"] ++
       optional("--session", a.session_id) ++ optional("--model", a.model)}
  end

  @doc """
  The rooms themselves, handed to a participant as flags for its own CLI.

  Passed per turn rather than written into the CLI's own configuration: the
  token in it says which participant is calling, and that is only true for the
  turn it was minted for. A provider without both a way to take a server on the
  command line and an approval channel back to the room gets nothing — see
  `Roundtable.MCP`.
  """
  def tools(agent) do
    if MCP.offered?(agent),
      do: flags(agent.provider, MCP.url(), MCP.token(agent)),
      else: []
  end

  defp flags("claude", url, token) do
    config = %{
      mcpServers: %{
        roundtable: %{
          type: "http",
          url: url,
          headers: %{"Authorization" => "Bearer #{token}"}
        }
      }
    }

    ["--mcp-config", Jason.encode!(config)]
  end

  # Codex reads the token from the environment instead, which keeps it out of
  # the process list every user on the machine can read.
  defp flags("codex", url, _token) do
    [
      "-c",
      ~s(mcp_servers.roundtable.url="#{url}"),
      "-c",
      ~s(mcp_servers.roundtable.bearer_token_env_var="#{@token_variable}")
    ]
  end

  @doc "Environment for the CLI: a participant's key to its own rooms."
  def env(%{provider: "codex"} = agent) do
    if MCP.offered?(agent),
      do: [{~c"#{@token_variable}", String.to_charlist(MCP.token(agent))}],
      else: []
  end

  def env(_agent), do: []

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
