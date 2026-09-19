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

  test "creates an organization without a folder", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/organizations")

    view
    |> form("#organization-form",
      organization: %{name: "Marketing Co", directory: "", context: ""}
    )
    |> render_submit()

    assert Enum.any?(Chat.organizations(), &(&1.name == "Marketing Co"))
    refute has_element?(view, "#organization-form-error")
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
