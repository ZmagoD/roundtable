defmodule RoundtableWeb.WorkspaceNavigationTest do
  use RoundtableWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Roundtable.Chat

  test "setup is explained separately from everyday team navigation", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")

    assert has_element?(view, "#workspace-navigation #build-team-button")

    assert has_element?(
             view,
             "#workspace-navigation #workspace-schedules-link[href='/schedules']"
           )

    assert has_element?(
             view,
             "#workspace-setup:not([open]) #profiles-button",
             "Saved agent roles"
           )

    assert has_element?(view, "#workspace-setup #model-presets-button", "Saved model settings")

    view |> element("#profiles-button") |> render_click()
    assert has_element?(view, "#modal-title", "Saved agent roles")
    assert has_element?(view, "#setup-panel p", "Add a copy to another team")

    view |> element("#setup-panel .modal-close") |> render_click()
    view |> element("#model-presets-button") |> render_click()
    assert has_element?(view, "#modal-title", "Saved model settings")
    assert has_element?(view, "#setup-panel p", "provider defaults work without it")
  end

  test "room and schedule navigation expose the current destination", %{conn: conn} do
    {:ok, room} = Chat.create_room(%{name: "Marketing", directory: File.cwd!()})
    {:ok, view, _} = live(conn, "/rooms/#{room.id}")
    assert has_element?(view, "nav[aria-label='Rooms'] a[aria-current='page']", "Marketing")

    {:ok, schedules, _} = live(conn, "/schedules")
    assert has_element?(schedules, "#workspace-schedules-link[aria-current='page']")

    assert has_element?(
             schedules,
             "nav[aria-label='Rooms'] a[href='/rooms/#{room.id}']",
             "Marketing"
           )

    assert has_element?(schedules, "#workspace-home-link[href='/']")
  end

  test "message times distinguish older days and years" do
    assert RoundtableWeb.RoomLive.time(~U[2024-01-02 09:15:00Z]) == "02 Jan 2024 · 09:15"
    today = DateTime.new!(Date.utc_today(), ~T[09:15:00], "Etc/UTC")
    assert RoundtableWeb.RoomLive.time(today) == "09:15"
  end

  test "room and workspace schedule panels have named native dialogs", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    view |> element("#build-team-button") |> render_click()
    assert has_element?(view, "dialog#setup-panel[aria-labelledby='modal-title'] #team-form")

    {:ok, schedules, _} = live(conn, "/schedules")
    schedules |> element(".room-header button") |> render_click()

    assert has_element?(
             schedules,
             "dialog#schedule-modal[aria-labelledby='schedule-modal-title']"
           )
  end
end
