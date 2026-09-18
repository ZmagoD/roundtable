defmodule RoundtableWeb.Plugs.MCP do
  @moduledoc """
  The tool server a participant's CLI talks to: JSON-RPC, one POST at a time.

  No session and no event stream. Everything here is a question with an answer,
  so there is nothing for the service to say on its own and nothing to keep
  open between calls — which also means a CLI that dies mid-turn leaves nothing
  behind.
  """
  @behaviour Plug
  import Plug.Conn

  alias Roundtable.MCP

  # The revision of the MCP spec these answers are written to. A client asking
  # for another one is answered in its own: initialize, tools/list and
  # tools/call have not changed shape between the revisions in use.
  @protocol_version "2025-06-18"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{method: "POST"} = conn, _opts) do
    case MCP.participant(bearer(conn)) do
      {:ok, agent} -> respond(conn, agent, conn.body_params)
      {:error, reason} -> refuse(conn, reason)
    end
  end

  # A GET is a client asking to be told things unprompted. Saying plainly that
  # there is no such stream costs it one request; holding one open that will
  # never carry anything costs it a connection for the length of the turn.
  def call(conn, _opts),
    do: send_json(conn, 405, %{error: "Roundtable's tools only answer a POST."})

  defp respond(conn, agent, %{"method" => method} = request) do
    result = handle(method, params(request), agent)

    case {request["id"], result} do
      # A notification is told nothing, not even that it was understood.
      {nil, _} -> send_resp(conn, 202, "")
      {id, {:ok, payload}} -> send_json(conn, 200, %{jsonrpc: "2.0", id: id, result: payload})
      {id, {:error, code, message}} -> send_json(conn, 200, error(id, code, message))
    end
  end

  defp respond(conn, _agent, _body),
    do: send_json(conn, 200, error(nil, -32_600, "Send one JSON-RPC request per POST."))

  defp handle("initialize", params, _agent) do
    {:ok,
     %{
       protocolVersion: params["protocolVersion"] || @protocol_version,
       capabilities: %{tools: %{}},
       serverInfo: %{name: "roundtable", version: version()},
       instructions:
         "The rooms in this Roundtable. Look at them whenever you need to know who is where, " <>
           "and build one — a room, its brief, its participants — when the human asks you to."
     }}
  end

  defp handle("notifications/" <> _rest, _params, _agent), do: {:ok, %{}}
  defp handle("ping", _params, _agent), do: {:ok, %{}}
  defp handle("tools/list", _params, _agent), do: {:ok, %{tools: MCP.tools()}}

  defp handle("tools/call", params, agent) do
    # A tool that refuses is a result the agent can read and act on, not a
    # transport failure: JSON-RPC errors are for calls that never happened.
    case MCP.call(agent, params["name"], arguments(params)) do
      {:ok, text} -> {:ok, content(text, false)}
      {:error, message} -> {:ok, content(message, true)}
    end
  end

  defp handle(method, _params, _agent), do: {:error, -32_601, "#{method} is not supported here."}

  defp content(text, error?), do: %{content: [%{type: "text", text: text}], isError: error?}

  defp error(id, code, message),
    do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}

  defp params(%{"params" => params}) when is_map(params), do: params
  defp params(_request), do: %{}

  defp arguments(%{"arguments" => arguments}) when is_map(arguments), do: arguments
  defp arguments(_params), do: %{}

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _rest] -> token
      _ -> nil
    end
  end

  # 403 rather than 401: a 401 sends an MCP client off to look for an
  # authorization server, and there is none. The only token that works here is
  # the one the service handed this participant when its turn started.
  defp refuse(conn, reason), do: send_json(conn, 403, %{error: explain(reason)})

  defp explain(:gone), do: "That participant is no longer in a room."
  defp explain(:expired), do: "That token belongs to a turn that has ended."
  defp explain(_reason), do: "Roundtable's tools need the token given to a participant's turn."

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp version, do: to_string(Application.spec(:roundtable, :vsn))
end
