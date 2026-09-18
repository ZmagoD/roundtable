defmodule RoundtableWeb.RoomLiveTest do
  use RoundtableWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Roundtable.Chat

  test "create a room, add two sessions of one provider, and assign work", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    view |> element(".welcome button") |> render_click()

    view
    |> form("#room-form", room: %{name: "Checkout", directory: File.cwd!()})
    |> render_submit()

    assert has_element?(view, "h1", "Checkout")

    for name <- ["ada", "tester"] do
      view |> element(".header-actions button") |> render_click()

      view
      |> form("#agent-form",
        agent: %{
          name: name,
          provider: "codex",
          directory: File.cwd!(),
          role: "Review changes",
          model: ""
        }
      )
      |> render_submit()
    end

    assert has_element?(view, ".agent-card strong", "ada")
    assert has_element?(view, ".agent-card strong", "tester")

    view
    |> form("#message-form", message: %{body: "Check the tests", to: "tester"})
    |> render_submit()

    assert has_element?(view, ".message-text", "@tester Check the tests")
    [room] = Chat.rooms()
    assert [%{status: "queued", agent: %{name: "tester"}}] = Chat.runs(room.id)
    {:ok, reopened, _} = live(conn, "/rooms/#{room.id}")
    assert has_element?(reopened, ".message-text", "@tester Check the tests")
  end

  test "chat updates arrive in another browser session", %{conn: conn} do
    {:ok, room} = Chat.create_room(%{"name" => "Shared", "directory" => File.cwd!()})
    {:ok, first, _} = live(conn, "/rooms/#{room.id}")
    {:ok, second, _} = live(conn, "/rooms/#{room.id}")

    first
    |> form("#message-form", message: %{body: "Visible everywhere", to: "room"})
    |> render_submit()

    assert has_element?(second, ".message-text", "Visible everywhere")
  end

  test "save a model preset and select it for a planning assignment", %{conn: conn} do
    {:ok, room} = Chat.create_room(%{"name" => "Models", "directory" => File.cwd!()})

    {:ok, _} =
      Chat.create_agent(room.id, %{
        "name" => "ada",
        "provider" => "codex",
        "directory" => File.cwd!()
      })

    {:ok, view, _} = live(conn, "/rooms/#{room.id}")
    view |> element("#model-presets-button") |> render_click()

    view
    |> form("#preset-form",
      preset: %{
        name: "Strong planner",
        provider: "codex",
        model: "test-premium",
        cost_tier: "premium"
      }
    )
    |> render_submit()

    assert has_element?(view, ".preset-row", "Strong planner")
    [preset] = Chat.model_presets()
    view |> element(".modal-close") |> render_click()

    view
    |> form("#message-form", message: %{body: "Plan the implementation", to: "ada"})
    |> render_change()

    view
    |> form("#message-form",
      message: %{
        body: "Plan the implementation",
        to: "ada",
        preset_id: to_string(preset.id),
        purpose: "planning"
      }
    )
    |> render_submit()

    assert [%{model: "test-premium", purpose: "planning", cost_tier: "premium"}] =
             Chat.runs(room.id)

    assert has_element?(view, ".assignment-meta", "test-premium")
  end
end
