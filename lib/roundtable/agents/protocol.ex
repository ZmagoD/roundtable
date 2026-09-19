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

  # The token is named here, not written here: an argument list is world-readable
  # through /proc, and a participant's key to the rooms has no business being in
  # it. Claude Code expands ${VAR} in an MCP configuration from its own
  # environment, which is where `env/1` puts it.
  defp flags("claude", url, _token) do
    config = %{
      mcpServers: %{
        roundtable: %{
          type: "http",
          url: url,
          headers: %{"Authorization" => "Bearer ${#{@token_variable}}"}
        }
      }
    }

    ["--mcp-config", Jason.encode!(config)]
  end

  # Codex names the variable to read rather than expanding one, for the same
  # reason and to the same effect.
  defp flags("codex", url, _token) do
    [
      "-c",
      ~s(mcp_servers.roundtable.url="#{url}"),
      "-c",
      ~s(mcp_servers.roundtable.bearer_token_env_var="#{@token_variable}")
    ]
  end

  @doc """
  Environment for the CLI: a participant's key to its own rooms, and nothing of
  the service's own.

  The only place the token is passed. Every provider that is offered the tools
  reads it from here, so it never appears in an argument list.

  The scrubbing is unconditional and comes first. A provider that is offered no
  tools is still a process running on this machine, and it has no more business
  holding this node's cookie than one that is — see `Roundtable.SpawnEnv`. The
  token goes last so that nothing in the removals can unset it.
  """
  def env(agent) do
    Roundtable.SpawnEnv.sanitised() ++ token_env(agent)
  end

  defp token_env(agent) do
    if MCP.offered?(agent),
      do: [{~c"#{@token_variable}", String.to_charlist(MCP.token(agent))}],
      else: []
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
