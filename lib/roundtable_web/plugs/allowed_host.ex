defmodule RoundtableWeb.Plugs.AllowedHost do
  @moduledoc """
  Rejects requests whose `Host` header is not a loopback name.

  Binding to loopback does not by itself keep remote pages out. A site that
  resolves its own domain to 127.0.0.1 (DNS rebinding) becomes same-origin with
  the service and can read any plain HTTP response, including a LiveView's
  initial render of room history and working directories. Origin checks cover
  the live socket; this covers every request that reaches it.

  Behind a proxy that adds its own authentication, allow that name with
  `config :roundtable, :allowed_hosts, ["localhost", "roundtable.internal"]`.
  """
  import Plug.Conn

  @loopback ["localhost", "127.0.0.1", "::1", "[::1]"]

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.host in Application.get_env(:roundtable, :allowed_hosts, @loopback) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(400, "Roundtable only answers requests addressed to localhost.\n")
      |> halt()
    end
  end
end
