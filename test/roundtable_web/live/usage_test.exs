defmodule RoundtableWeb.UsageTest do
  use RoundtableWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Roundtable.Chat

  test "cards show percentage, status, unknown usage, timestamps and per-agent tokens", %{
    conn: conn
  } do
    {:ok, room} = Chat.create_room(%{name: "Usage cards", directory: File.cwd!()})

    agents =
      for {name, provider} <- [{"ada", "codex"}, {"bob", "claude"}, {"cora", "opencode"}] do
        {:ok, agent} = Chat.create_agent(room.id, %{name: name, provider: provider})
        agent
      end

    [ada, bob, cora] = agents
    Chat.record_provider_usage("codex", %{"percent" => 42})
    Chat.record_provider_usage("claude", %{"status" => "near limit"})
    Chat.post(room.id, "@ada task")
    [run] = Chat.runs(room.id)
    Chat.record_tokens(run, "attempt", %{"input" => 100, "output" => 20, "cached" => 80})
    {:ok, view, _} = live(conn, "/rooms/#{room.id}")
    assert has_element?(view, "#provider-usage-#{ada.id}", "42.0%")
    assert has_element?(view, "#provider-usage-#{bob.id}", "near limit")
    assert has_element?(view, "#provider-usage-#{cora.id}", "not reported")
    assert has_element?(view, "#agent-usage-#{ada.id} time[datetime]")
    refute has_element?(view, "#agent-usage-#{cora.id} time")
    assert has_element?(view, "#token-usage-#{ada.id}", "100 input")
    assert has_element?(view, "#token-usage-#{ada.id}", "20 output")
    assert has_element?(view, "#token-usage-#{ada.id}", "80 cached")
    assert has_element?(view, "#token-usage-#{bob.id}", "not reported")
    assert has_element?(view, "#token-usage-#{cora.id}", "not reported")
  end

  test "provider updates refresh every room sharing that provider", %{conn: conn} do
    {:ok, first} = Chat.create_room(%{name: "First", directory: File.cwd!()})
    {:ok, second} = Chat.create_room(%{name: "Second", directory: File.cwd!()})
    {:ok, ada} = Chat.create_agent(first.id, %{name: "ada", provider: "claude"})
    {:ok, bob} = Chat.create_agent(second.id, %{name: "bob", provider: "claude"})
    {:ok, one, _} = live(conn, "/rooms/#{first.id}")
    {:ok, two, _} = live(conn, "/rooms/#{second.id}")
    {:ok, schedules, _} = live(conn, "/schedules")
    Chat.record_provider_usage("claude", %{"status" => "OK"})
    assert has_element?(one, "#provider-usage-#{ada.id}", "OK")
    assert has_element?(two, "#provider-usage-#{bob.id}", "OK")
    Chat.record_provider_usage("claude", %{"status" => "limited"})
    assert has_element?(one, "#provider-usage-#{ada.id}", "limited")
    assert has_element?(two, "#provider-usage-#{bob.id}", "limited")
    assert has_element?(schedules, "#workspace-navigation")
  end
end
