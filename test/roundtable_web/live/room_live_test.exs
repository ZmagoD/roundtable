defmodule RoundtableWeb.RoomLiveTest do
  use RoundtableWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Roundtable.Chat

  test "build a team creates its helper and queues the request", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    view |> element("#build-team-button") |> render_click()

    view
    |> form("#team-form",
      team: %{
        name: "Payments",
        directory: File.cwd!(),
        provider: "codex",
        context: "Help me choose an implementer and a reviewer."
      }
    )
    |> render_submit()

    assert has_element?(view, "h1", "Payments")
    [room] = Chat.rooms()
    [agent] = Chat.agents(room.id)
    assert agent.name == "team-builder"
    assert agent.provider == "codex"
    refute agent.auto_approve
    assert agent.model == nil
    assert [%{status: "queued", agent_id: id}] = Chat.runs(room.id)
    assert id == agent.id
    assert has_element?(view, ".message-text", "Help me choose an implementer")
  end

  test "invalid team setup keeps the form and creates nothing", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    view |> element("#build-team-button") |> render_click()

    view
    |> form("#team-form",
      team: %{
        name: "Payments",
        directory: "/roundtable-missing-directory",
        provider: "codex",
        context: "Help me build a team."
      }
    )
    |> render_submit()

    assert has_element?(view, "#team-form")
    assert has_element?(view, "[role=alert]")
    assert Chat.rooms() == []
  end

  test "team setup rejects unsupported providers and empty goals" do
    for attrs <- [
          %{name: "Team", directory: File.cwd!(), provider: "grok", context: "A goal"},
          %{name: "Team", directory: File.cwd!(), provider: "codex", context: " "}
        ] do
      assert {:error, %Ecto.Changeset{}} = Chat.build_team(attrs)
      assert Chat.rooms() == []
    end
  end

  test "team builder is available inside an existing room and cancel creates nothing", %{
    conn: conn
  } do
    {:ok, room} = Chat.create_room(%{name: "Existing", directory: File.cwd!()})
    {:ok, view, _} = live(conn, "/rooms/#{room.id}")
    view |> element("#build-team-button") |> render_click()
    assert has_element?(view, "#team-form select option[value=codex]")
    assert has_element?(view, "#team-form select option[value=claude]")
    refute has_element?(view, "#team-form select option[value=grok]")
    refute has_element?(view, "#team-form select option[value=opencode]")
    view |> element(".modal-close") |> render_click()
    refute has_element?(view, "#team-form")
    assert [^room] = Chat.rooms()
    assert Chat.agents(room.id) == []
  end

  test "failed team setup preserves the draft and can be corrected with Claude", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    view |> element("#build-team-button") |> render_click()

    view
    |> form("#team-form",
      team: %{
        name: "Design",
        directory: "missing",
        provider: "claude",
        context: "Choose a design team"
      }
    )
    |> render_submit()

    assert has_element?(view, "#team-form input[name='team[name]'][value=Design]")
    assert has_element?(view, "#team-form select option[value=claude][selected]")
    view |> form("#team-form", team: %{directory: File.cwd!()}) |> render_submit()
    [room] = Chat.rooms()
    [agent] = Chat.agents(room.id)
    assert agent.provider == "claude"
    assert room.context == "Choose a design team"
    {:ok, reopened, _} = live(conn, "/rooms/#{room.id}")
    assert has_element?(reopened, ".agent-card strong", "team-builder")
    assert has_element?(reopened, ".message-text", "Choose a design team")
    assert [_] = Chat.runs(room.id)
  end

  test "team builder defaults to an installed supported provider", %{conn: conn} do
    path = System.get_env("PATH")

    directory =
      Path.join(System.tmp_dir!(), "roundtable-provider-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "claude"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(directory, "claude"), 0o755)
    System.put_env("PATH", directory)

    on_exit(fn ->
      System.put_env("PATH", path)
      File.rm_rf!(directory)
    end)

    {:ok, view, _} = live(conn, "/")
    view |> element("#build-team-button") |> render_click()
    assert has_element?(view, "#team-form select option[value=claude][selected]")
    refute has_element?(view, "#team-form select option[value=codex][selected]")
  end

  test "team builder form remains usable when no provider is installed", %{conn: conn} do
    path = System.get_env("PATH")
    System.put_env("PATH", "/roundtable-no-provider-binaries")
    on_exit(fn -> System.put_env("PATH", path) end)

    {:ok, view, _} = live(conn, "/")
    view |> element("#build-team-button") |> render_click()
    assert has_element?(view, "#team-form select option[value=codex][selected]")
    assert Chat.rooms() == []
  end

  test "create a room, add two sessions of one provider, and assign work", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    view |> element("#new-room-button") |> render_click()

    view
    |> form("#room-form", room: %{name: "Checkout"})
    |> render_submit()

    assert has_element?(view, "h1", "Checkout")

    for name <- ["ada", "tester"] do
      view |> element("#add-agent-button") |> render_click()

      view
      |> form("#agent-form",
        agent: %{
          name: name,
          provider: "codex",
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
      view |> element("#new-room-button") |> render_click()

      html =
        view
        |> form("#room-form", room: %{name: "Nowhere", directory: "/does/not/exist"})
        |> render_submit()

      assert html =~ "directory"
      assert Enum.count(Chat.rooms()) == 1
    end

    test "an invalid agent name is refused and the form keeps what was typed", %{view: view} do
      view |> element("#add-agent-button") |> render_click()

      html =
        view
        |> form("#agent-form",
          agent: %{name: "Not Valid", provider: "codex"}
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

    test "a profile is saved once and added to a room", %{view: view, room: room} do
      view |> element("#profiles-button") |> render_click()

      view
      |> form("#profile-form",
        profile: %{
          name: "reviewer",
          provider: "claude",
          role: "Review diffs, never write them",
          cost_tier: "standard",
          auto_approve: "true"
        }
      )
      |> render_submit()

      assert [profile] = Chat.agent_profiles()
      view |> element("[phx-click=add-profile][phx-value-id='#{profile.id}']") |> render_click()

      assert Enum.any?(Chat.agents(room.id), &(&1.name == "reviewer" and &1.auto_approve))
    end

    test "the room brief is edited in place and shown back", %{view: view, room: room} do
      view |> element("#edit-room-button") |> render_click()

      html =
        view
        |> form("#room-form",
          room: %{name: "Handlers", context: "Elixir and Phoenix. Tests first."}
        )
        |> render_submit()

      assert Chat.room!(room.id).context == "Elixir and Phoenix. Tests first."
      # The directory stays whatever the room was created on.
      assert Chat.room!(room.id).directory == room.directory
      assert html =~ "Handlers"

      view |> element("#edit-room-button") |> render_click()
      assert render(view) =~ "Elixir and Phoenix. Tests first."
    end

    test "tool approvals are switched on from the participant's own form", %{
      view: view,
      agent: agent
    } do
      view |> element("button.agent-edit[phx-value-id='#{agent.id}']") |> render_click()

      html =
        view
        |> form("#agent-form", agent: %{auto_approve: "true"})
        |> render_submit()

      assert Chat.agent!(agent.id).auto_approve
      assert html =~ "auto-approves"
    end

    test "always allow answers the request in front of you and stops the asking", %{
      conn: conn,
      room: room,
      agent: agent
    } do
      Application.put_env(:roundtable, :agent_worker, Roundtable.TestWorker)
      Application.put_env(:roundtable, :test_observer, self())
      Application.put_env(:roundtable, :start_agents, true)

      on_exit(fn ->
        Application.put_env(:roundtable, :start_agents, false)
        Application.delete_env(:roundtable, :agent_worker)
        Application.delete_env(:roundtable, :test_observer)
      end)

      Roundtable.Coordinator.post(room.id, "@ada do work")
      assert_receive {:agent_started, _pid, _, run, _}, 1000
      Roundtable.Coordinator.event(run.id, {:approval, "req-1", %{"command" => "ls"}})

      {:ok, view, _} = live(conn, "/rooms/#{room.id}")
      assert has_element?(view, ".approval-card")

      view |> element("[phx-click=always-allow]") |> render_click()

      assert_receive {:decision, "req-1", "accept"}, 1000
      assert Chat.agent!(agent.id).auto_approve
      assert Roundtable.Coordinator.approvals() == %{}
      Roundtable.Coordinator.stop(agent.id)
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

    test "the model field is a list you can actually pick from", %{view: view} do
      html = view |> element("#add-agent-button") |> render_click()

      # It opens on a provider that can name its models, not one that cannot.
      assert html =~ ~s(name="agent[model]")
      assert html =~ "Provider default"

      html =
        view
        |> form("#agent-form", agent: %{name: "x", provider: "claude"})
        |> render_change()

      # Claude Code documents these aliases in its own --help.
      for alias_name <- ~w(fable opus sonnet) do
        assert html =~ ~s(value="#{alias_name}")
      end

      assert html =~ "the CLI reports"
    end

    test "refreshing models preserves the agent draft and selected model", %{view: view} do
      view |> element("#add-agent-button") |> render_click()

      view
      |> form("#agent-form", agent: %{name: "local", provider: "codex"})
      |> render_change()

      view
      |> form("#agent-form", agent: %{name: "local", provider: "claude", model: "custom-model"})
      |> render_change()

      render_click(view, "refresh-models", %{})
      assert has_element?(view, "#agent-form input[name='agent[name]'][value='local']")
      assert has_element?(view, "#agent-form option[value='custom-model'][selected]")
      assert has_element?(view, "#agent-form option[value='sonnet']")
    end

    test "a provider that cannot list its models still takes a typed name", %{view: view} do
      view |> element("#add-agent-button") |> render_click()

      html =
        view
        |> form("#agent-form", agent: %{name: "x", provider: "codex"})
        |> render_change()

      assert html =~ "does not list its models"
      assert html =~ ~s(name="agent[model]")
    end

    test "editing keeps a model the CLI no longer lists", %{view: view, agent: agent} do
      {:ok, _} = Chat.update_agent(agent.id, %{"model" => "some-retired-model"})

      html = view |> element(".agent-edit[phx-value-id='#{agent.id}']") |> render_click()

      # Dropping it silently would change the agent behind the user's back.
      assert html =~ "some-retired-model"
    end

    test "the agent form shows the room's directory rather than asking for one", %{
      view: view,
      room: room
    } do
      html = view |> element("#add-agent-button") |> render_click()

      refute html =~ ~s(name="agent[directory]")
      assert html =~ room.directory
      assert html =~ "make a separate room"
    end

    test "the room form suggests directories instead of asking you to remember one", %{view: view} do
      html = view |> element("#new-room-button") |> render_click()

      # Something to click before a single character is typed.
      assert html =~ "directory-picker"

      html =
        view
        |> form("#room-form", room: %{name: "X", directory: File.cwd!() <> "/li"})
        |> render_change()

      assert html =~ "lib"
      refute html =~ "directory-name\">mix.exs"
    end

    test "picking a directory fills the field and goes in", %{view: view} do
      view |> element("#new-room-button") |> render_click()

      view
      |> form("#room-form", room: %{name: "X", directory: File.cwd!() <> "/"})
      |> render_change()

      html =
        view
        |> element("[phx-click=pick-directory][phx-value-path='#{File.cwd!()}/lib']")
        |> render_click()

      # The field now holds it, and the picker has moved one level down.
      assert html =~ "#{File.cwd!()}/lib"
      assert html =~ "roundtable"
    end

    test "a git repository is marked as one", %{view: view} do
      view |> element("#new-room-button") |> render_click()

      html =
        view
        |> form("#room-form",
          room: %{name: "X", directory: Path.dirname(File.cwd!()) <> "/round"}
        )
        |> render_change()

      assert html =~ "directory-repo"
    end

    test "a reply is rendered as markdown here too, not shown as markup", %{
      view: view,
      room: room
    } do
      body = "## What I checked\n\n- one thing\n\n```elixir\nCart.discount(105, 10)\n```"
      {:ok, _} = Chat.post(room.id, body, sender: "ada", kind: "agent")

      html = render(view)

      assert html =~ "<h4>What I checked</h4>"
      assert html =~ "message-bullet"
      assert html =~ "<pre><code>Cart.discount(105, 10)</code></pre>"
      refute html =~ "## What I checked"
      refute html =~ "```"
    end

    test "an agent cannot inject markup through a reply", %{view: view, room: room} do
      {:ok, _} =
        Chat.post(room.id, "<script>alert(1)</script> and <b>bold</b>",
          sender: "ada",
          kind: "agent"
        )

      html = render(view)

      # A room is full of other people's output; it is text, not markup.
      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end

    test "the composer carries who can be mentioned", %{view: view, room: room} do
      {:ok, _} =
        Chat.create_agent(room.id, %{"name" => "grace", "provider" => "opencode"})

      html = render(view)

      assert html =~ "data-mentions"
      # Everyone in the room, plus @all, which is a mention too.
      assert html =~ "ada"
      assert html =~ "grace"
      assert html =~ "all"
    end

    test "the mention menu survives patches and excludes other rooms", %{view: view} do
      {:ok, other} = Chat.create_room(%{name: "Other", directory: File.cwd!()})
      {:ok, _} = Chat.create_agent(other.id, %{name: "outsider", provider: "codex"})

      assert has_element?(
               view,
               "#mention-menu-container[phx-update=ignore] #mention-menu[role=listbox]"
             )

      assert has_element?(
               view,
               "#message-body[aria-controls=mention-menu][aria-autocomplete=list]"
             )

      assert has_element?(view, "#message-form[data-mentions='[\"all\",\"ada\"]']")
      view |> form("#message-form", message: %{body: "@ad"}) |> render_change()
      assert has_element?(view, "#mention-menu-container[phx-update=ignore] #mention-menu")
    end

    test "the composer says Enter sends", %{view: view} do
      html = render(view)

      assert html =~ "Enter to send"
      refute html =~ "Ctrl + Enter to send"
    end

    test "the mention list follows who is in the room", %{view: view, agent: agent} do
      assert render(view) =~ "ada"

      view |> element(".agent-edit[phx-value-id='#{agent.id}']") |> render_click()

      view
      |> form("#agent-form", agent: %{name: "ada-2", role: "", model: "", cost_tier: "unknown"})
      |> render_submit()

      html = render(view)
      assert html =~ "ada-2"
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

    test "editing can switch provider while keeping the directory fixed", %{
      view: view,
      agent: agent
    } do
      html =
        view
        |> element(".agent-edit[phx-value-id='#{agent.id}']")
        |> render_click()

      # A live session is built on the adapter and the working tree, so they are
      # shown as facts rather than controls.
      assert html =~ ~s(name="agent[provider]")
      refute html =~ ~s(name="agent[directory]")
      assert html =~ "fixed-field"
      assert html =~ agent.provider

      view
      |> form("#agent-form", agent: %{provider: "opencode", model: "qwen3-coder:30b"})
      |> render_submit()

      updated = Chat.agent!(agent.id)
      assert updated.provider == "opencode"
      assert updated.model == "qwen3-coder:30b"
      assert updated.directory == agent.directory
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

    test "the name can no longer be edited once the agent has taken a turn", %{
      conn: conn,
      room: room,
      agent: agent
    } do
      {:ok, _} = Chat.post(room.id, "@ada work")
      {:ok, view, _} = live(conn, "/rooms/#{room.id}")

      html = view |> element(".agent-edit[phx-value-id='#{agent.id}']") |> render_click()

      refute html =~ ~s(name="agent[name]")
      assert html =~ "has taken a turn"

      # Its role is still editable: that is an instruction for the next turn.
      view
      |> form("#agent-form", agent: %{role: "Review only.", model: "", cost_tier: "unknown"})
      |> render_submit()

      assert Chat.agent!(agent.id).role == "Review only."
      assert Chat.agent!(agent.id).name == "ada"
    end

    test "an agent without a role says so, and offers to set one", %{view: view} do
      assert render(view) =~ "No role set"
    end

    test "a terminal opens on the room's directory, and closes again", %{view: view, room: room} do
      refute has_element?(view, ".terminal-panel")

      html = view |> element("#terminal-button") |> render_click()
      assert html =~ "terminal-panel"
      assert html =~ room.directory
      assert html =~ ~s(phx-hook="Terminal")

      html = view |> element("#terminal-button") |> render_click()
      refute html =~ "terminal-panel"
    end

    test "keystrokes and resizes reach the shell", %{view: view} do
      view |> element("#terminal-button") |> render_click()

      # Base64 both ways: the socket carries JSON, terminal traffic is bytes.
      render_hook(view, "terminal-input", %{"data" => Base.encode64("echo hi\n")})
      render_hook(view, "terminal-resize", %{"rows" => 30, "cols" => 100})

      assert has_element?(view, ".terminal-panel")
    end

    test "input with no terminal open is ignored rather than crashing", %{view: view} do
      render_hook(view, "terminal-input", %{"data" => Base.encode64("rm -rf /\n")})
      render_hook(view, "terminal-resize", %{"rows" => 10, "cols" => 10})

      refute has_element?(view, ".terminal-panel")
    end

    test "switching rooms takes the terminal with it", %{view: view, conn: conn} do
      view |> element("#terminal-button") |> render_click()
      assert has_element?(view, ".terminal-panel")

      {:ok, other} = Chat.create_room(%{"name" => "Elsewhere", "directory" => File.cwd!()})
      {:ok, moved, _} = live(conn, "/rooms/#{other.id}")

      # A shell belongs to the directory it was opened in.
      refute has_element?(moved, ".terminal-panel")
    end

    test "removing a participant from the browser keeps its messages", %{
      view: view,
      room: room,
      agent: agent
    } do
      {:ok, _} =
        Chat.post(room.id, "something ada said", sender: "ada", agent_id: agent.id, kind: "agent")

      html = render(view)
      assert html =~ "data-confirm"

      view |> element("[phx-click=remove-agent][phx-value-id='#{agent.id}']") |> render_click()

      assert Chat.agents(room.id) == []
      assert Enum.any?(Chat.messages(room.id), &(&1.body == "something ada said"))
      assert render(view) =~ "What it said stays"
    end

    test "removing a room takes you back to no room", %{view: view, room: room} do
      {:ok, _} = Chat.post(room.id, "history that is about to go")

      view |> element("#remove-room-button") |> render_click()

      assert Chat.rooms() == []
      assert Roundtable.Repo.aggregate(Roundtable.Chat.Message, :count) == 0
    end

    test "both removals ask first", %{view: view, agent: agent} do
      html = render(view)

      room_button = Regex.run(~r/<button[^>]*id="remove-room-button".*?>/s, html) |> List.first()
      assert room_button =~ "data-confirm"
      assert room_button =~ "no undo"

      agent_button =
        Regex.run(
          ~r/<button[^>]*phx-click="remove-agent"[^>]*phx-value-id="#{agent.id}".*?>/s,
          html
        )
        |> List.first()

      assert agent_button =~ "data-confirm"
      assert agent_button =~ "cannot be undone"
    end

    test "a schedule is saved from the room and read back as a sentence", %{
      view: view,
      room: room,
      agent: agent
    } do
      view |> element("#schedules-button") |> render_click()

      view
      |> form("#schedule-form",
        schedule: %{
          agent_id: agent.id,
          prompt: "Sweep the bug board",
          at: "9, 17:30",
          days: "1,2,3,4,5",
          enabled: "true"
        }
      )
      |> render_submit()

      refute has_element?(view, ".preset-row")
      assert has_element?(view, "#schedule-form")
      assert [%{at: "09:00,17:30", agent_id: id}] = Chat.schedules(room.id)
      assert id == agent.id
    end

    test "a note is saved from the room and listed for the next turn", %{
      view: view,
      room: room
    } do
      view |> element("#room-notes-button") |> render_click()

      html =
        view
        |> form("#note-form",
          note: %{body: "Money is cents everywhere.", kind: "convention", pinned: "true"}
        )
        |> render_submit()

      assert html =~ "Money is cents everywhere."
      assert [%{kind: "convention", pinned: true, author: "you"}] = Chat.room_notes(room.id)
    end

    test "a note with nothing in it is refused and nothing is recorded", %{
      view: view,
      room: room
    } do
      view |> element("#room-notes-button") |> render_click()

      html =
        view
        |> form("#note-form", note: %{body: "   ", kind: "convention"})
        |> render_submit()

      assert html =~ "body"
      assert Chat.room_notes(room.id) == []
    end

    test "a note can be unpinned and removed from the room", %{view: view, room: room} do
      {:ok, note} = Chat.create_room_note(room.id, %{"body" => "Keep this", "pinned" => "true"})
      view |> element("#room-notes-button") |> render_click()

      view |> element("button[phx-click='pin-note'][phx-value-id='#{note.id}']") |> render_click()
      assert [%{pinned: false}] = Chat.room_notes(room.id)

      view
      |> element("button[phx-click='edit-note'][phx-value-id='#{note.id}']")
      |> render_click()

      view |> element("button[phx-click='delete-note']") |> render_click()
      assert Chat.room_notes(room.id) == []
    end

    test "the room schedule panel leaves schedule management to the schedules page", %{view: view} do
      view |> element("#schedules-button") |> render_click()

      refute has_element?(view, ".preset-row")
      assert has_element?(view, "#schedule-form")
    end

    test "a time nobody can read is refused with a reason", %{
      view: view,
      room: room,
      agent: agent
    } do
      view |> element("#schedules-button") |> render_click()

      html =
        view
        |> form("#schedule-form",
          schedule: %{agent_id: agent.id, prompt: "Sweep", at: "half nine"}
        )
        |> render_submit()

      assert html =~ "time of day"
      assert Chat.schedules(room.id) == []
    end

    test "closing a panel leaves the room visible", %{view: view} do
      view |> element("#add-agent-button") |> render_click()
      assert has_element?(view, "#agent-form")

      view |> element("[phx-click=close-panel]") |> render_click()
      refute has_element?(view, "#agent-form")
    end
  end
end
