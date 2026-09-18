defmodule RoundtableWeb.PageControllerTest do
  use RoundtableWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Your agents."
  end

  test "a request addressed to another host is refused", %{conn: conn} do
    conn = get(%{conn | host: "rebound.example.com"}, ~p"/")

    assert conn.status == 400
    refute conn.resp_body =~ "Your agents."
  end
end
