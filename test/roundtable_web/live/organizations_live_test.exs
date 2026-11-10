defmodule RoundtableWeb.OrganizationsLiveTest do
  use RoundtableWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Roundtable.Chat

  test "lists the organization every existing room was put in", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/organizations")

    existing = Chat.default_organization()

    assert has_element?(view, "#organization-#{existing.id}")
    assert has_element?(view, "#organization-form")
  end

  test "creates an organization without a folder and opens it, empty", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/organizations")

    result =
      view
      |> form("#organization-form",
        organization: %{name: "Marketing Co", directory: "", context: ""}
      )
      |> render_submit()

    created = Enum.find(Chat.organizations(), &(&1.name == "Marketing Co"))
    assert {:error, {:live_redirect, %{to: to}}} = result
    assert to == "/?organization=#{created.id}"
    assert Chat.rooms(created.id) == []
  end

  test "shows each team's head, members and what it is doing", %{conn: conn} do
    {:ok, organization} = Chat.create_organization(%{"name" => "Alpha"})

    {:ok, room} =
      Chat.create_room(%{
        "name" => "Engineering",
        "directory" => File.cwd!(),
        "organization_id" => organization.id
      })

    {:ok, morgan} = Chat.create_agent(room.id, %{"name" => "morgan", "provider" => "claude"})
    {:ok, _} = Chat.create_agent(room.id, %{"name" => "ada", "provider" => "claude"})
    {:ok, _} = Chat.set_team_head(morgan.id)
    {:ok, message} = Chat.post(room.id, "work", kind: "agent", sender: "morgan")

    Roundtable.Repo.insert!(%Roundtable.Chat.Run{
      agent_id: morgan.id,
      message_id: message.id,
      status: "approval"
    })

    {:ok, view, _html} = live(conn, ~p"/organizations")
    status = view |> element("#team-status-#{room.id}") |> render()

    assert status =~ "Head: morgan"
    assert status =~ "2 members"
    assert status =~ "1 needs approval"
  end

  test "an empty organization offers to create its first team", %{conn: conn} do
    {:ok, organization} = Chat.create_organization(%{"name" => "Empty"})
    {:ok, view, _html} = live(conn, ~p"/organizations")

    assert view |> element("#organization-#{organization.id}") |> render() =~ "No teams yet"

    assert has_element?(
             view,
             ~s|#create-team-#{organization.id}[href="/?organization=#{organization.id}"]|
           )
  end

  test "editing the folder says which teams it moves and which keep their own",
       %{conn: conn} do
    {:ok, organization} =
      Chat.create_organization(%{"name" => "Alpha", "directory" => File.cwd!()})

    for {name, directory} <- [{"Inherits", ""}, {"Own folder", File.cwd!()}] do
      {:ok, _} =
        Chat.create_room(%{
          "name" => name,
          "directory" => directory,
          "organization_id" => organization.id
        })
    end

    {:ok, view, _html} = live(conn, ~p"/organizations")
    view |> element("#edit-organization-#{organization.id}") |> render_click()
    impact = view |> element("#folder-impact") |> render()

    assert impact =~ "Teams using this folder: Inherits."
    assert impact =~ "applies to their new turns"
    assert impact =~ "Teams with their own folder, unaffected: Own folder."
  end

  test "creates an organization with a folder and a brief", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/organizations")

    view
    |> form("#organization-form",
      organization: %{
        name: "Roundtable app",
        directory: File.cwd!(),
        context: "One local workspace for a human and named agents."
      }
    )
    |> render_submit()

    created = Enum.find(Chat.organizations(), &(&1.name == "Roundtable app"))

    assert created.directory == File.cwd!()
    assert created.context == "One local workspace for a human and named agents."
  end

  test "shows the error when the folder does not exist", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/organizations")

    view
    |> form("#organization-form",
      organization: %{name: "Ghost", directory: "/no/such/place", context: ""}
    )
    |> render_submit()

    assert has_element?(view, "#organization-form-error")
    assert render(view) =~ "must be an existing absolute directory"
    refute Enum.any?(Chat.organizations(), &(&1.name == "Ghost"))
  end

  test "renames an organization", %{conn: conn} do
    {:ok, organization} = Chat.create_organization(%{"name" => "Alpha"})

    {:ok, view, _html} = live(conn, ~p"/organizations")

    view |> element("#edit-organization-#{organization.id}") |> render_click()

    view
    |> form("#organization-form", organization: %{name: "Alpha Co", directory: "", context: ""})
    |> render_submit()

    assert Chat.organization!(organization.id).name == "Alpha Co"
  end

  test "counts the teams in an organization", %{conn: conn} do
    {:ok, organization} = Chat.create_organization(%{"name" => "Alpha"})

    {:ok, _room} =
      Chat.create_room(%{
        "name" => "Engineering",
        "directory" => File.cwd!(),
        "organization_id" => organization.id
      })

    {:ok, view, _html} = live(conn, ~p"/organizations")

    card = element(view, "#organization-#{organization.id}")

    assert render(card) =~ "1 team"
    assert render(card) =~ "Engineering"
  end
end
