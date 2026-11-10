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

  describe "editing an organization" do
    setup do
      {:ok, organization} =
        Chat.create_organization(%{
          "name" => "Alpha",
          "directory" => File.cwd!(),
          "context" => "Ship the billing service."
        })

      %{organization: organization}
    end

    test "opens the form filled with what is saved, and focuses it",
         %{conn: conn, organization: organization} do
      {:ok, view, _html} = live(conn, ~p"/organizations")

      view |> element("#edit-organization-#{organization.id}") |> render_click()

      assert view |> element(".schedule-form-panel h2") |> render() =~ "Edit organization"
      assert has_element?(view, ~s|#organization_name[value="Alpha"]|)
      assert has_element?(view, ~s|#organization_directory[value="#{File.cwd!()}"]|)
      assert view |> element("#organization_context") |> render() =~ "Ship the billing service."
      assert has_element?(view, "#organization-#{organization.id}.selected")
      assert has_element?(view, "#cancel-edit-organization")
      assert_push_event(view, "focus", %{to: "#organization_name"})
    end

    test "saves every field and goes back to an empty new form",
         %{conn: conn, organization: organization} do
      {:ok, view, _html} = live(conn, ~p"/organizations")
      view |> element("#edit-organization-#{organization.id}") |> render_click()

      view
      |> form("#organization-form",
        organization: %{name: "Alpha Co", directory: "", context: "Sell the billing service."}
      )
      |> render_submit()

      saved = Chat.organization!(organization.id)
      assert saved.name == "Alpha Co"
      assert saved.directory in [nil, ""]
      assert saved.context == "Sell the billing service."

      assert view |> element("#organization-#{organization.id}") |> render() =~ "Alpha Co"
      assert view |> element(".schedule-form-panel h2") |> render() =~ "Add an organization"
      assert has_element?(view, ~s|#organization_name[value=""]|)
      refute has_element?(view, "#cancel-edit-organization")
    end

    test "does not create a second organization", %{conn: conn, organization: organization} do
      before = length(Chat.organizations())
      {:ok, view, _html} = live(conn, ~p"/organizations")
      view |> element("#edit-organization-#{organization.id}") |> render_click()

      view
      |> form("#organization-form", organization: %{name: "Alpha 2"})
      |> render_submit()

      assert length(Chat.organizations()) == before
    end

    test "keeps the edit open with the error when the folder does not exist",
         %{conn: conn, organization: organization} do
      {:ok, view, _html} = live(conn, ~p"/organizations")
      view |> element("#edit-organization-#{organization.id}") |> render_click()

      view
      |> form("#organization-form", organization: %{directory: "/no/such/place"})
      |> render_submit()

      assert view |> element("#organization-form-error") |> render() =~
               "must be an existing absolute directory"

      assert view |> element(".schedule-form-panel h2") |> render() =~ "Edit organization"
      assert has_element?(view, ~s|#organization_directory[value="/no/such/place"]|)
      assert Chat.organization!(organization.id).directory == File.cwd!()
    end

    test "refuses a name another organization already has",
         %{conn: conn, organization: organization} do
      {:ok, _} = Chat.create_organization(%{"name" => "Beta"})
      {:ok, view, _html} = live(conn, ~p"/organizations")
      view |> element("#edit-organization-#{organization.id}") |> render_click()

      view
      |> form("#organization-form", organization: %{name: "Beta"})
      |> render_submit()

      assert has_element?(view, "#organization-form-error")
      assert Chat.organization!(organization.id).name == "Alpha"
    end

    test "cancel drops the edit without saving it", %{conn: conn, organization: organization} do
      {:ok, view, _html} = live(conn, ~p"/organizations")
      view |> element("#edit-organization-#{organization.id}") |> render_click()
      view |> element("#cancel-edit-organization") |> render_click()

      assert view |> element(".schedule-form-panel h2") |> render() =~ "Add an organization"
      assert has_element?(view, ~s|#organization_name[value=""]|)
      assert Chat.organization!(organization.id).name == "Alpha"
    end

    test "New organization leaves the edit for an empty form",
         %{conn: conn, organization: organization} do
      {:ok, view, _html} = live(conn, ~p"/organizations")
      view |> element("#edit-organization-#{organization.id}") |> render_click()
      view |> element("#new-organization") |> render_click()

      assert view |> element(".schedule-form-panel h2") |> render() =~ "Add an organization"
      assert has_element?(view, ~s|#organization_name[value=""]|)
      assert_push_event(view, "focus", %{to: "#organization_name"})
    end
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
