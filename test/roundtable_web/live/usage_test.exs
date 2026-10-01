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

  test "chips in the chat show the reading on messages, live runs and suggestions", %{
    conn: conn
  } do
    {:ok, room} = Chat.create_room(%{name: "Usage chips", directory: File.cwd!()})
    {:ok, _ada} = Chat.create_agent(room.id, %{name: "ada", provider: "codex"})
    {:ok, _bob} = Chat.create_agent(room.id, %{name: "bob", provider: "claude"})

    Chat.record_provider_usage("codex", %{"percent" => 85})
    Chat.record_provider_usage("claude", %{"status" => "limited"})
    {:ok, _} = Chat.post(room.id, "written by ada", sender: "ada", kind: "agent")
    {:ok, _} = Chat.post(room.id, "written by bob", sender: "bob", kind: "agent")
    {:ok, _} = Chat.post(room.id, "written by nobody here", sender: "gone", kind: "agent")

    {:ok, view, _} = live(conn, "/rooms/#{room.id}")

    assert has_element?(view, ".message-meta .usage-chip.usage-warn", "85.0%")
    assert has_element?(view, ".message-meta .usage-chip.usage-warn", "limited")
    # Someone since removed, or from another room, reports nothing.
    assert has_element?(view, "#messages .message-meta .usage-chip", "not reported")
    html = render(view)

    # The chip says whose reading it is, in data, whether or not anything came.
    assert html =~ ~s(class="usage-chip usage-codex usage-warn")
    assert html =~ ~s(class="usage-chip usage-claude usage-warn")

    # A queued turn shows the same chip as a message does.
    {:ok, _} = Chat.post(room.id, "@ada work")
    [run] = Chat.runs(room.id)
    assert has_element?(view, "#run-#{run.id} .usage-chip", "85.0%")

    # @ suggestions carry each provider's reading beside the name. The JSON
    # is HTML-escaped in the attribute, so it is read back rather than grepped.
    document = LazyHTML.from_fragment(render(view))
    form = LazyHTML.query(document, "#message-form")
    [mentions] = LazyHTML.attribute(form, "data-mentions")
    choices = Jason.decode!(mentions)
    assert %{"name" => "ada", "usage" => "85.0%", "level" => "warn"} in choices
    assert %{"name" => "bob", "usage" => "limited", "level" => "warn"} in choices
  end

  test "a reading arriving after a message is on screen pushes its chip update", %{conn: conn} do
    {:ok, room} = Chat.create_room(%{name: "Chip updates", directory: File.cwd!()})
    {:ok, _} = Chat.create_agent(room.id, %{name: "ada", provider: "codex"})
    {:ok, _} = Chat.post(room.id, "written before any reading", sender: "ada", kind: "agent")
    {:ok, view, _} = live(conn, "/rooms/#{room.id}")

    assert has_element?(view, ".message-meta .usage-chip", "not reported")

    Chat.record_provider_usage("codex", %{"percent" => 92})
    _ = :sys.get_state(view.pid)

    {_, {:push_event, "usage-update", payload}} =
      assert_push_event(view, "usage-update", %{provider: "codex"})

    assert payload.label == "92.0%"
    assert payload.level == "warn"
    assert payload.recorded =~ "Recorded"
  end
end
