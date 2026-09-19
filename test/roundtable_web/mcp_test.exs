defmodule RoundtableWeb.Plugs.MCPTest do
  @moduledoc """
  The wire between a participant's CLI and the rooms.

  A provider's MCP client is not ours and will not be patient with us: it
  expects an initialize it can read, a tool list it can use, a tool result it
  can hand its model, and a refusal that does not send it looking for an
  authorization server that does not exist.
  """
  use RoundtableWeb.ConnCase, async: false

  alias Roundtable.{Chat, MCP}

  setup %{conn: conn} do
    {:ok, room} = Chat.create_room(%{"name" => "Checkout", "directory" => File.cwd!()})
    {:ok, ada} = Chat.create_agent(room.id, %{"name" => "ada", "provider" => "claude"})
    run = turn(ada)

    %{
      conn: put_req_header(conn, "content-type", "application/json"),
      room: room,
      ada: ada,
      run: run
    }
  end

  # A token is only good while its turn is in progress, so a participant under
  # test needs one — exactly as it has one in production, where the token is
  # minted after the run is already running.
  defp turn(agent) do
    {:ok, message} = Chat.post(agent.room_id, "something to do")

    Roundtable.Repo.insert!(%Roundtable.Chat.Run{
      agent_id: agent.id,
      message_id: message.id,
      status: "running"
    })
  end

  defp rpc(conn, agent, body) do
    conn
    |> put_req_header("authorization", "Bearer " <> MCP.token(agent))
    |> post("/mcp", Jason.encode!(body))
  end

  defp request(method, params \\ %{}, id \\ 1),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  test "initialize answers in the client's own revision", %{conn: conn, ada: ada} do
    conn = rpc(conn, ada, request("initialize", %{"protocolVersion" => "2025-03-26"}))
    result = json_response(conn, 200)["result"]

    assert result["protocolVersion"] == "2025-03-26"
    assert result["serverInfo"]["name"] == "roundtable"
    assert result["capabilities"]["tools"] == %{}
    assert result["instructions"] =~ "rooms"
  end

  test "the tools arrive with schemas a client can offer", %{conn: conn, ada: ada} do
    conn = rpc(conn, ada, request("tools/list"))
    tools = json_response(conn, 200)["result"]["tools"]

    assert "create_room" in Enum.map(tools, & &1["name"])

    for tool <- tools do
      assert tool["inputSchema"]["type"] == "object"
    end
  end

  test "a tool call does the thing and says what it did", %{conn: conn, ada: ada} do
    conn =
      rpc(
        conn,
        ada,
        request("tools/call", %{"name" => "create_room", "arguments" => %{"name" => "Docs"}})
      )

    result = json_response(conn, 200)["result"]

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "created room"
    assert Chat.find_room("Docs")
  end

  test "a tool that refuses is a result, not a transport failure", %{conn: conn, ada: ada} do
    conn = rpc(conn, ada, request("tools/call", %{"name" => "create_room", "arguments" => %{}}))
    result = json_response(conn, 200)["result"]

    assert result["isError"] == true
    assert [%{"text" => text}] = result["content"]
    assert text =~ "name"
  end

  test "a method we do not have says so in JSON-RPC's own words", %{conn: conn, ada: ada} do
    conn = rpc(conn, ada, request("resources/list"))
    assert json_response(conn, 200)["error"]["code"] == -32_601
  end

  test "a notification is answered with nothing at all", %{conn: conn, ada: ada} do
    conn =
      rpc(conn, ada, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized",
        "params" => %{}
      })

    assert conn.status == 202
    assert conn.resp_body == ""
  end

  test "without a token, no tools and no hunt for a login", %{conn: conn} do
    conn = post(conn, "/mcp", Jason.encode!(request("tools/list")))

    assert conn.status == 403
    assert get_resp_header(conn, "www-authenticate") == []
    assert json_response(conn, 403)["error"] =~ "token"
  end

  test "a token for a participant that has gone is refused", %{conn: conn, ada: ada} do
    token = MCP.token(ada)
    {:ok, _} = Chat.delete_agent(ada.id)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/mcp", Jason.encode!(request("tools/list")))

    assert json_response(conn, 403)["error"] =~ "no longer"
  end

  test "a request addressed to another host never reaches the tools", %{conn: conn, ada: ada} do
    # DNS rebinding: a page that resolves its own domain to 127.0.0.1 would
    # otherwise be able to call these with the browser's own credentials.
    conn =
      %{conn | host: "rebound.example.com"}
      |> put_req_header("authorization", "Bearer " <> MCP.token(ada))
      |> post("/mcp", Jason.encode!(request("tools/list")))

    assert conn.status == 400
    refute conn.resp_body =~ "create_room"
  end

  test "there is no stream to attach to", %{conn: conn, ada: ada} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> MCP.token(ada))
      |> get("/mcp")

    assert json_response(conn, 405)["error"] =~ "POST"
  end
end
