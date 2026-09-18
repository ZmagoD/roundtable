defmodule RoundtableWeb.SchedulesLiveTest do
  use RoundtableWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Roundtable.Chat

  setup do
    {:ok, room} = Chat.create_room(%{name: "Billing", directory: File.cwd!()})

    {:ok, agent} =
      Chat.create_agent(room.id, %{name: "reviewer", provider: "codex", role: "Review changes"})

    %{room: room, agent: agent}
  end

  test "lists schedules across rooms and edits their instructions", %{
    conn: conn,
    room: room,
    agent: agent
  } do
    {:ok, schedule} =
      Chat.create_schedule(room.id, %{
        agent_id: agent.id,
        prompt: "Review open changes",
        at: "09:00"
      })

    {:ok, view, _html} = live(conn, "/schedules")
    assert has_element?(view, ".schedule-card", "Billing")
    assert has_element?(view, ".schedule-card", "Review open changes")

    view
    |> element("button[phx-click=edit-schedule][phx-value-id='#{schedule.id}']")
    |> render_click()

    view
    |> form("#workspace-schedule-form",
      schedule: %{prompt: "Review and report", at: "10:30", days: "1,2,3,4,5"}
    )
    |> render_submit()

    assert has_element?(view, ".schedule-card", "Review and report")
    assert Chat.schedule!(schedule.id).at == "10:30"
    assert Chat.schedule!(schedule.id).days == "1,2,3,4,5"
  end

  test "creates, disables and deletes a schedule", %{conn: conn, room: room, agent: agent} do
    {:ok, view, _html} = live(conn, "/schedules")

    view
    |> form("#workspace-schedule-form",
      schedule: %{agent_id: agent.id, prompt: "Check the board", at: "08:00"}
    )
    |> render_submit()

    [schedule] = Chat.schedules(room.id)
    assert has_element?(view, ".schedule-card", "Check the board")

    view
    |> element("button[phx-click=toggle-schedule][phx-value-id='#{schedule.id}']")
    |> render_click()

    assert Chat.schedule!(schedule.id).enabled == false

    view
    |> element("button[phx-click=delete-schedule][phx-value-id='#{schedule.id}']")
    |> render_click()

    assert Chat.schedules(room.id) == []
    assert has_element?(view, ".empty-state")
  end

  test "shows an empty state when no agents exist", %{conn: conn, agent: agent} do
    Chat.delete_agent(agent.id)
    {:ok, view, _html} = live(conn, "/schedules")
    assert has_element?(view, ".empty-state")
    assert has_element?(view, ".schedule-editor", "Add an agent")
    refute has_element?(view, "#workspace-schedule-form")
  end
end
