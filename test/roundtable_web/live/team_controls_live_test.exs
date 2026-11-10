defmodule RoundtableWeb.TeamControlsLiveTest do
  @moduledoc """
  The team controls in a room: choosing a head, seeing where the folder comes
  from and what a participant works to, and stopping work or pausing schedules
  as two separate actions.
  """
  use RoundtableWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Roundtable.{Chat, Repo}
  alias Roundtable.Chat.Run

  setup do
    {:ok, organization} =
      Chat.create_organization(%{
        "name" => "Acme",
        "directory" => File.cwd!(),
        "context" => "Ship the billing service."
      })

    {:ok, room} =
      Chat.create_room(%{
        "name" => "Engineering",
        "directory" => "",
        "organization_id" => organization.id,
        "context" => "Tests with every change."
      })

    {:ok, ada} =
      Chat.create_agent(room.id, %{
        "name" => "ada",
        "provider" => "claude",
        "role" => "Review changes."
      })

    Chat.clear_team_head(room.id)
    %{organization: organization, room: room, ada: ada}
  end

  defp turn(agent, status) do
    {:ok, message} = Chat.post(agent.room_id, "work", kind: "agent", sender: agent.name)
    Repo.insert!(%Run{agent_id: agent.id, message_id: message.id, status: status})
  end

  test "a team without a head asks for one, and stops asking once chosen",
       %{conn: conn, room: room, ada: ada} do
    {:ok, view, _html} = live(conn, ~p"/rooms/#{room.id}")
    assert has_element?(view, "#choose-team-head", "Choose a team head")

    view |> element("#make-head-#{ada.id}") |> render_click()
    refute has_element?(view, "#choose-team-head")
  end

  test "the folder says where it comes from", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, ~p"/rooms/#{room.id}")
    view |> element("#edit-room-button") |> render_click()
    assert render(view) =~ "From Acme: #{File.cwd!()}"

    {:ok, _} = Chat.update_room(room.id, %{"directory" => File.cwd!()})
    {:ok, view, _html} = live(conn, ~p"/rooms/#{room.id}")
    view |> element("#edit-room-button") |> render_click()
    assert render(view) =~ "Custom folder: #{File.cwd!()}"
  end

  test "a folder change says it waits for new turns while work is running",
       %{conn: conn, room: room, ada: ada} do
    {:ok, view, _html} = live(conn, ~p"/rooms/#{room.id}")
    view |> element("#edit-room-button") |> render_click()
    refute has_element?(view, "#directory-applies-later")

    turn(ada, "running")
    {:ok, view, _html} = live(conn, ~p"/rooms/#{room.id}")
    view |> element("#edit-room-button") |> render_click()
    assert has_element?(view, "#directory-applies-later", "Applies to new turns")
  end

  test "the team brief shows the organization brief it adds to", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, ~p"/rooms/#{room.id}")
    view |> element("#edit-room-button") |> render_click()

    assert view |> element("#inherited-organization-brief") |> render() =~
             "Ship the billing service."
  end

  test "a participant's form previews all three layers it works to",
       %{conn: conn, room: room, ada: ada} do
    {:ok, view, _html} = live(conn, ~p"/rooms/#{room.id}")
    view |> element("button[phx-click=edit-agent][phx-value-id='#{ada.id}']") |> render_click()
    preview = view |> element("#effective-instructions") |> render()

    assert preview =~ "Organization brief"
    assert preview =~ "Ship the billing service."
    assert preview =~ "Team brief"
    assert preview =~ "Tests with every change."
    assert preview =~ "Member role"
    assert preview =~ "Review changes."
    # An inheriting team's participant works in the project's folder, not "".
    assert render(view) =~ ~s(<p class="fixed-field">#{File.cwd!()}</p>)
  end

  test "stop and pause are offered only when there is something to stop or pause",
       %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, ~p"/rooms/#{room.id}")

    assert has_element?(view, "#stop-team-button[disabled]")
    assert has_element?(view, "#pause-schedules-button[disabled]")
  end

  test "pausing schedules leaves running work alone", %{conn: conn, room: room, ada: ada} do
    {:ok, schedule} =
      Chat.create_schedule(room.id, %{"agent_id" => ada.id, "prompt" => "sweep", "at" => "9"})

    run = turn(ada, "queued")
    {:ok, view, _html} = live(conn, ~p"/rooms/#{room.id}")

    view |> element("#pause-schedules-button") |> render_click()

    refute Chat.schedule!(schedule.id).enabled
    assert Repo.get!(Run, run.id).status == "queued"
    assert render(view) =~ "Paused 1 schedule in Engineering."
  end

  test "stopping work leaves schedules on", %{conn: conn, room: room, ada: ada} do
    {:ok, schedule} =
      Chat.create_schedule(room.id, %{"agent_id" => ada.id, "prompt" => "sweep", "at" => "9"})

    run = turn(ada, "queued")
    {:ok, view, _html} = live(conn, ~p"/rooms/#{room.id}")

    view |> element("#stop-team-button") |> render_click()

    assert Repo.get!(Run, run.id).status == "stopped"
    assert Chat.schedule!(schedule.id).enabled
    assert render(view) =~ "Stopped the running and queued work in Engineering."
  end

  test "a schedule form shows its next run before it is saved", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, ~p"/rooms/#{room.id}")
    view |> element("#schedules-button") |> render_click()

    assert view |> element("#room-schedule-next-run") |> render() =~
             ~r/Next run: \w{3} \d{2} \w{3} at \d{2}:\d{2}/

    assert render(view) =~ "Saving does not run it now."
  end

  describe "before sending" do
    defp draft(view, body, to \\ "room") do
      view |> form("#message-form", message: %{body: body, to: to}) |> render_change()
    end

    test "a mention says who will start work, and naming someone in prose does not",
         %{conn: conn, room: room} do
      {:ok, view, _html} = live(conn, ~p"/rooms/#{room.id}")

      draft(view, "@ada look at the failing test")
      assert has_element?(view, "#starts-work", "Sending starts work for @ada.")

      draft(view, "ada might know why this fails")
      assert has_element?(view, "#starts-work", "Sending starts nobody's turn here.")

      assert Chat.messages(room.id) == []
    end

    test "an unaddressed message names the team head it will go to",
         %{conn: conn, room: room, ada: ada} do
      {:ok, _} = Chat.set_team_head(ada.id)
      {:ok, view, _html} = live(conn, ~p"/rooms/#{room.id}")

      draft(view, "what is next?")
      assert has_element?(view, "#starts-work", "Sending starts work for @ada.")
    end

    test "a command or an empty draft previews nothing", %{conn: conn, room: room} do
      {:ok, view, _html} = live(conn, ~p"/rooms/#{room.id}")

      draft(view, "/clear-history")
      refute has_element?(view, "#starts-work")

      draft(view, "   ")
      refute has_element?(view, "#starts-work")
    end
  end
end
