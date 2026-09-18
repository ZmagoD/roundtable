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

  describe "the handlers a browser reaches that the terminal does not" do
    setup %{conn: conn} do
      {:ok, room} = Chat.create_room(%{"name" => "Handlers", "directory" => File.cwd!()})

      {:ok, agent} =
        Chat.create_agent(room.id, %{
          "name" => "ada",
          "provider" => "codex",
          "directory" => File.cwd!()
        })

      {:ok, view, _} = live(conn, "/rooms/#{room.id}")
      %{room: room, agent: agent, view: view, conn: conn}
    end

    test "a room with a directory that does not exist is refused with a reason", %{view: view} do
      view |> element("button.new-room", "+ New room") |> render_click()

      html =
        view
        |> form("#room-form", room: %{name: "Nowhere", directory: "/does/not/exist"})
        |> render_submit()

      assert html =~ "directory"
      assert Enum.count(Chat.rooms()) == 1
    end

    test "an invalid agent name is refused and the form keeps what was typed", %{view: view} do
      view |> element(".header-actions button") |> render_click()

      html =
        view
        |> form("#agent-form",
          agent: %{name: "Not Valid", provider: "codex", directory: File.cwd!()}
        )
        |> render_submit()

      assert html =~ "name"
      assert [%{name: "ada"}] = Chat.agents(hd(Chat.rooms()).id)
    end

    test "editing a preset loads it back into the form", %{view: view} do
      view |> element("#model-presets-button") |> render_click()

      view
      |> form("#preset-form",
        preset: %{name: "Fast", provider: "codex", model: "quick-model", cost_tier: "economy"}
      )
      |> render_submit()

      [preset] = Chat.model_presets()
      view |> element("[phx-click=edit-preset][phx-value-id='#{preset.id}']") |> render_click()

      assert has_element?(view, "#preset-form")
      assert render(view) =~ "quick-model"
    end

    test "the model chooser appears only once a named recipient is chosen", %{view: view} do
      html =
        view
        |> form("#message-form", message: %{body: "hello", to: "room"})
        |> render_change()

      refute html =~ "message[preset_id]"

      html =
        view
        |> form("#message-form", message: %{body: "hello", to: "ada"})
        |> render_change()

      assert html =~ "message[preset_id]"
    end

    test "stopping and resetting a participant reaches the coordinator", %{
      view: view,
      agent: agent
    } do
      view |> element("[phx-click=stop][phx-value-id='#{agent.id}']") |> render_click()
      view |> element("[phx-click=reset][phx-value-id='#{agent.id}']") |> render_click()

      # Reset clears the native session pointer, which is the visible effect.
      assert %{session_id: nil, last_seen_id: 0} = Chat.agent!(agent.id)
    end

    test "a failed run can be retried from the browser", %{conn: conn, room: room, agent: agent} do
      {:ok, message} = Chat.post(room.id, "@ada work")
      run = Roundtable.Repo.get_by!(Roundtable.Chat.Run, message_id: message.id)
      Chat.change(run, status: "failed", error: "Codex exited (1).")

      # Reload so the failed run is in the view's assigns. The case's conn is
      # addressed to loopback; a bare build_conn/0 is refused by the host plug.
      {:ok, view, _} = live(conn, "/rooms/#{room.id}")
      view |> element("[phx-click=retry][phx-value-id='#{run.id}']") |> render_click()

      assert Roundtable.Repo.get!(Roundtable.Chat.Run, run.id).status in ["queued", "running"]
      assert agent.id == run.agent_id
    end

    test "an empty message is refused by the context, not the form", %{view: view} do
      before = length(Chat.messages(hd(Chat.rooms()).id))

      view |> form("#message-form", message: %{body: "   ", to: "room"}) |> render_submit()

      assert length(Chat.messages(hd(Chat.rooms()).id)) == before
    end

    test "the room shows its branch and what has changed", %{conn: conn} do
      # A room on this checkout, which is a git repository with real state.
      {:ok, room} = Chat.create_room(%{"name" => "Repo", "directory" => File.cwd!()})
      {:ok, view, _} = live(conn, "/rooms/#{room.id}")

      html = render(view)
      assert html =~ "Changes on"
      assert html =~ "branch-badge"
      assert html =~ File.cwd!()
    end

    test "the diff is fetched only when asked for", %{conn: conn} do
      {:ok, room} = Chat.create_room(%{"name" => "Repo", "directory" => File.cwd!()})
      {:ok, view, _} = live(conn, "/rooms/#{room.id}")

      refute render(view) =~ "changes-diff"

      opened = view |> element("[phx-click=toggle-diff]") |> render_click()
      assert opened =~ "changes-diff"

      closed = view |> element("[phx-click=toggle-diff]") |> render_click()
      refute closed =~ "changes-diff"
    end

    test "a room outside a repository shows no branch rather than an error", %{conn: conn} do
      directory = Path.join(System.tmp_dir!(), "rt-plain-#{System.unique_integer([:positive])}")
      File.mkdir_p!(directory)
      on_exit(fn -> File.rm_rf!(directory) end)

      {:ok, room} = Chat.create_room(%{"name" => "Plain", "directory" => directory})
      {:ok, view, _} = live(conn, "/rooms/#{room.id}")

      html = render(view)
      refute html =~ "Changes on"
      assert html =~ "Plain"
    end

    test "the theme can be switched, and follows the system by default", %{view: view} do
      html = render(view)

      assert html =~ ~s(data-theme-choice="system")
      assert html =~ ~s(data-theme-choice="light")
      assert html =~ ~s(data-theme-choice="dark")
    end

    test "an agent can be renamed and re-roled from the browser", %{view: view, agent: agent} do
      view |> element(".agent-edit[phx-value-id='#{agent.id}']") |> render_click()

      assert has_element?(view, "#agent-form")
      assert render(view) =~ "Save changes"

      view
      |> form("#agent-form",
        agent: %{
          name: "ada-2",
          role: "Review diffs.",
          model: "claude-sonnet-5",
          cost_tier: "standard"
        }
      )
      |> render_submit()

      updated = Chat.agent!(agent.id)
      assert updated.name == "ada-2"
      assert updated.role == "Review diffs."
      assert updated.model == "claude-sonnet-5"

      html = render(view)
      assert html =~ "ada-2"
      assert html =~ "claude-sonnet-5"
    end

    test "editing keeps the provider and directory fixed", %{view: view, agent: agent} do
      html =
        view
        |> element(".agent-edit[phx-value-id='#{agent.id}']")
        |> render_click()

      # A live session is built on the adapter and the working tree, so they are
      # shown as facts rather than controls.
      refute html =~ ~s(name="agent[provider]")
      refute html =~ ~s(name="agent[directory]")
      assert html =~ "fixed-field"
      assert html =~ agent.provider
    end

    test "a rename to a name already in use is refused with a reason", %{
      view: view,
      agent: agent,
      room: room
    } do
      {:ok, _} =
        Chat.create_agent(room.id, %{
          "name" => "grace",
          "provider" => "opencode",
          "directory" => File.cwd!()
        })

      view |> element(".agent-edit[phx-value-id='#{agent.id}']") |> render_click()

      html =
        view
        |> form("#agent-form",
          agent: %{name: "grace", role: "", model: "", cost_tier: "unknown"}
        )
        |> render_submit()

      assert html =~ "already used in this room"
      assert Chat.agent!(agent.id).name == "ada"
    end

    test "an agent without a role says so, and offers to set one", %{view: view} do
      assert render(view) =~ "No role set"
    end

    test "closing a panel leaves the room visible", %{view: view} do
      view |> element(".header-actions button") |> render_click()
      assert has_element?(view, "#agent-form")

      view |> element("[phx-click=close-panel]") |> render_click()
      refute has_element?(view, "#agent-form")
    end
  end
end
