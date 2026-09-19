defmodule RoundtableWeb.OrganizationSwitcherTest do
  use RoundtableWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Roundtable.Chat

  setup do
    {:ok, alpha} = Chat.create_organization(%{"name" => "Alpha"})
    {:ok, beta} = Chat.create_organization(%{"name" => "Beta"})

    {:ok, alpha_eng} =
      Chat.create_room(%{
        "name" => "Alpha Engineering",
        "directory" => File.cwd!(),
        "organization_id" => alpha.id
      })

    {:ok, beta_sales} =
      Chat.create_room(%{
        "name" => "Beta Sales",
        "directory" => File.cwd!(),
        "organization_id" => beta.id
      })

    %{alpha: alpha, beta: beta, alpha_eng: alpha_eng, beta_sales: beta_sales}
  end

  test "the sidebar lists only the teams of the project you are in", %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, ~p"/rooms/#{ctx.alpha_eng.id}")

    assert render(view) =~ "Alpha Engineering"
    refute render(view) =~ "Beta Sales"
  end

  test "opening a team selects its project in the switcher", %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, ~p"/rooms/#{ctx.beta_sales.id}")

    assert has_element?(view, "#switch-organization-#{ctx.beta.id}.selected")
    refute has_element?(view, "#switch-organization-#{ctx.alpha.id}.selected")
  end

  test "switching project opens that project's first team", %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, ~p"/rooms/#{ctx.alpha_eng.id}")

    view |> element("#switch-organization-#{ctx.beta.id}") |> render_click()

    assert render(view) =~ "Beta Sales"
    refute render(view) =~ "Alpha Engineering"
  end

  test "a project with no teams opens empty rather than showing another one's",
       %{conn: conn} = ctx do
    {:ok, empty} = Chat.create_organization(%{"name" => "Empty project"})

    {:ok, view, _html} = live(conn, ~p"/rooms/#{ctx.alpha_eng.id}")

    view |> element("#switch-organization-#{empty.id}") |> render_click()

    refute render(view) =~ "Alpha Engineering"
    refute render(view) =~ "Beta Sales"
    assert render(view) =~ "A little space for your next big idea."
  end

  test "the switcher links to where organizations are managed", %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, ~p"/rooms/#{ctx.alpha_eng.id}")

    assert has_element?(view, "#manage-organizations-link")
  end
end
