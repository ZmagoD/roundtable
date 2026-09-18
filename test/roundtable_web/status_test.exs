defmodule RoundtableWeb.StatusControllerTest do
  use RoundtableWeb.ConnCase, async: false

  alias Roundtable.Chat

  test "reports rooms, participants and what is waiting", %{conn: conn} do
    {:ok, room} = Chat.create_room(%{"name" => "Build", "directory" => File.cwd!()})

    {:ok, _} =
      Chat.create_agent(room.id, %{
        "name" => "ada",
        "provider" => "codex",
        "directory" => File.cwd!()
      })

    {:ok, _} = Chat.post(room.id, "@ada take a look")

    body = json_response(get(conn, ~p"/status.json"), 200)

    assert %{"rooms" => [entry], "totals" => totals} = body
    assert entry["name"] == "Build"
    assert entry["participants"] == 1
    assert entry["queued"] == 1

    assert totals == %{
             "rooms" => 1,
             "participants" => 1,
             "queued" => 1,
             "running" => 0,
             "waiting_for_approval" => 0
           }
  end

  test "a request addressed to another host is refused", %{conn: conn} do
    conn = get(%{conn | host: "rebound.example.com"}, ~p"/status.json")

    assert conn.status == 400
  end
end
