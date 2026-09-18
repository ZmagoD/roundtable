defmodule RoundtableWeb.Plugs.Status do
  @moduledoc """
  One GET that says what the service is doing, for things outside it.

  A desktop widget or a script should not have to open the browser UI, or read
  the log, to find out that a participant is waiting on an approval. The answer
  is room names and counts, behind the same host allow-list as every other
  response — see `RoundtableWeb.Plugs.AllowedHost`.
  """
  @behaviour Plug
  import Plug.Conn

  alias Roundtable.Chat

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{method: method} = conn, _opts) when method in ["GET", "HEAD"] do
    body = Chat.overview() |> Map.put(:version, version()) |> Jason.encode!()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(405, Jason.encode!(%{error: "Roundtable's status only answers a GET."}))
  end

  defp version, do: to_string(Application.spec(:roundtable, :vsn))
end
