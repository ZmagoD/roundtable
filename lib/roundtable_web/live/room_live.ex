defmodule RoundtableWeb.RoomLive do
  use RoundtableWeb, :live_view
  alias Roundtable.{Chat, Coordinator}
  alias Roundtable.Chat.RoomNote

  @impl true
  def mount(_, _, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Roundtable.PubSub, "rooms")
      # Files move while a turn runs, and nothing broadcasts when they do.
      :timer.send_interval(2_000, self(), :poll_git)
    end

    {:ok,
     assign(socket,
       room: nil,
       rooms: Chat.rooms(),
       agents: [],
       last_message_id: 0,
       model_presets: Chat.model_presets(),
       agent_profiles: Chat.agent_profiles(),
       profile_form: to_form(%{"cost_tier" => "unknown"}, as: :profile),
       editing_profile: nil,
       preset_form: to_form(%{"cost_tier" => "unknown"}, as: :preset),
       editing_preset: nil,
       editing_agent: nil,
       editing_renamable: true,
       editing_room: nil,
       schedules: [],
       schedule_form: to_form(%{"days" => "", "at" => "09:00"}, as: :schedule),
       editing_schedule: nil,
       notes: [],
       note_form: note_form(),
       note_seq: 0,
       editing_note: nil,
       team_form: to_form(%{}, as: :team),
       room_form: to_form(%{}, as: :room),
       agent_form: to_form(%{}, as: :agent),
       runs: [],
       approvals: [],
       providers: Roundtable.Agents.providers(),
       model_options: [],
       directory_options: [],
       panel: nil,
       form_error: nil,
       message_form: to_form(%{"body" => "", "to" => "room"}, as: :message),
       directory: System.get_env("ROUNDTABLE_WORKSPACE") || File.cwd!(),
       changes: nil,
       diff: nil,
       terminal: nil,
       page_title: "Roundtable"
     )
     |> stream(:messages, [])}
  end

  @impl true
  def handle_params(params, _, socket) do
    if connected?(socket) && socket.assigns.room,
      do: Phoenix.PubSub.unsubscribe(Roundtable.PubSub, "room:#{socket.assigns.room.id}")

    room =
      case params["id"] do
        nil -> List.first(Chat.rooms())
        id -> Enum.find(Chat.rooms(), &(to_string(&1.id) == id))
      end

    if room && connected?(socket), do: Chat.subscribe(room.id)

    {:noreply,
     socket
     |> close_terminal()
     |> assign(room: room, panel: nil, form_error: nil, last_message_id: 0, diff: nil)
     |> stream(:messages, [], reset: true)
     |> refresh()
     |> poll_git()}
  end

  @impl true
  def handle_event("panel", %{"name" => name}, socket) do
    socket = assign(socket, editing_agent: nil, editing_renamable: true, editing_room: nil)
    room_form = to_form(%{"directory" => socket.assigns.directory}, as: :room)
    socket = assign(socket, directory_options: Roundtable.Directories.suggest(""))

    agent_form =
      to_form(
        %{
          "directory" =>
            (socket.assigns.room && socket.assigns.room.directory) || socket.assigns.directory,
          "provider" => default_provider(),
          "cost_tier" => "unknown"
        },
        as: :agent
      )

    {:noreply,
     assign(socket,
       panel: name,
       team_form:
         to_form(
           %{
             "directory" => socket.assigns.directory,
             "provider" => team_provider(socket.assigns.providers)
           },
           as: :team
         ),
       form_error: nil,
       model_options: Roundtable.Agents.models(agent_form[:provider].value),
       room_form: room_form,
       agent_form: agent_form,
       preset_form:
         to_form(%{"provider" => List.first(Roundtable.Agents.ids()), "cost_tier" => "unknown"},
           as: :preset
         ),
       editing_preset: nil,
       editing_profile: nil,
       editing_schedule: nil,
       schedule_form: schedule_form(socket.assigns.agents),
       editing_note: nil,
       note_form: note_form(),
       note_seq: socket.assigns.note_seq + 1,
       profile_form:
         to_form(
           %{
             "provider" => default_provider(),
             "cost_tier" => "unknown",
             "auto_approve" => "false"
           },
           as: :profile
         ),
       editing_agent: nil,
       editing_renamable: true
     )}
  end

  def handle_event("edit-schedule", %{"id" => id}, socket) do
    schedule = Chat.schedule!(String.to_integer(id))

    attrs = %{
      "agent_id" => to_string(schedule.agent_id),
      "name" => schedule.name,
      "prompt" => schedule.prompt,
      "at" => schedule.at,
      "days" => schedule.days,
      "enabled" => to_string(schedule.enabled)
    }

    {:noreply,
     assign(socket,
       panel: "schedules",
       editing_schedule: schedule.id,
       form_error: nil,
       schedule_form: to_form(attrs, as: :schedule)
     )}
  end

  def handle_event("save-schedule", %{"schedule" => attrs}, %{assigns: %{room: room}} = socket)
      when not is_nil(room) do
    saved =
      case socket.assigns.editing_schedule do
        nil -> Chat.create_schedule(room.id, attrs)
        id -> Chat.update_schedule(id, attrs)
      end

    case saved do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(
           editing_schedule: nil,
           form_error: nil,
           schedule_form: schedule_form(socket.assigns.agents)
         )
         |> refresh()}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           form_error: errors(changeset),
           schedule_form: to_form(attrs, as: :schedule)
         )}
    end
  end

  def handle_event("save-schedule", _attrs, socket), do: {:noreply, socket}

  def handle_event("toggle-schedule", %{"id" => id}, socket) do
    schedule = Chat.schedule!(String.to_integer(id))
    {:ok, _} = Chat.update_schedule(schedule.id, %{"enabled" => !schedule.enabled})
    {:noreply, refresh(socket)}
  end

  def handle_event("delete-schedule", %{"id" => id}, socket) do
    Chat.delete_schedule(String.to_integer(id))

    {:noreply,
     socket
     |> assign(editing_schedule: nil, schedule_form: schedule_form(socket.assigns.agents))
     |> put_flash(:info, "Schedule removed. Nothing else changes.")
     |> refresh()}
  end

  def handle_event("edit-note", %{"id" => id}, socket) do
    note = Chat.room_note!(String.to_integer(id))

    attrs = %{"body" => note.body, "kind" => note.kind, "pinned" => to_string(note.pinned)}

    {:noreply,
     assign(socket,
       panel: "notes",
       editing_note: note.id,
       form_error: nil,
       note_form: to_form(attrs, as: :note)
     )}
  end

  def handle_event("save-note", %{"note" => attrs}, %{assigns: %{room: room}} = socket)
      when not is_nil(room) do
    # Written here, so the note says who by. Participants get their own byline
    # if they are ever given the pen.
    attrs = Map.put_new(attrs, "author", "you")

    saved =
      case socket.assigns.editing_note do
        nil -> Chat.create_room_note(room.id, attrs)
        id -> Chat.update_room_note(id, attrs)
      end

    case saved do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(
           editing_note: nil,
           form_error: nil,
           note_form: note_form(),
           note_seq: socket.assigns.note_seq + 1
         )
         |> refresh()}

      {:error, changeset} ->
        {:noreply,
         assign(socket, form_error: errors(changeset), note_form: to_form(attrs, as: :note))}
    end
  end

  def handle_event("save-note", _attrs, socket), do: {:noreply, socket}

  def handle_event("pin-note", %{"id" => id}, socket) do
    note = Chat.room_note!(String.to_integer(id))
    {:ok, _} = Chat.update_room_note(note.id, %{"pinned" => !note.pinned})
    {:noreply, refresh(socket)}
  end

  def handle_event("delete-note", %{"id" => id}, socket) do
    Chat.delete_room_note(String.to_integer(id))

    {:noreply,
     socket
     |> assign(editing_note: nil, note_form: note_form(), note_seq: socket.assigns.note_seq + 1)
     |> put_flash(:info, "Note removed. The next turn will not see it.")
     |> refresh()}
  end

  def handle_event("edit-profile", %{"id" => id}, socket) do
    profile = Chat.agent_profile!(String.to_integer(id))

    attrs = %{
      "name" => profile.name,
      "provider" => profile.provider,
      "model" => profile.model,
      "cost_tier" => profile.cost_tier,
      "role" => profile.role,
      "auto_approve" => to_string(profile.auto_approve)
    }

    {:noreply,
     assign(socket,
       panel: "profiles",
       editing_profile: profile.id,
       form_error: nil,
       profile_form: to_form(attrs, as: :profile)
     )}
  end

  def handle_event("save-profile", %{"profile" => attrs}, socket) do
    saved =
      case socket.assigns.editing_profile do
        nil -> Chat.create_agent_profile(attrs)
        id -> Chat.update_agent_profile(id, attrs)
      end

    case saved do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(
           editing_profile: nil,
           form_error: nil,
           agent_profiles: Chat.agent_profiles(),
           profile_form: to_form(%{"cost_tier" => "unknown"}, as: :profile)
         )}

      {:error, changeset} ->
        {:noreply,
         assign(socket, form_error: errors(changeset), profile_form: to_form(attrs, as: :profile))}
    end
  end

  def handle_event("delete-profile", %{"id" => id}, socket) do
    Chat.delete_agent_profile(String.to_integer(id))

    {:noreply,
     socket
     |> assign(
       editing_profile: nil,
       agent_profiles: Chat.agent_profiles(),
       profile_form: to_form(%{"cost_tier" => "unknown"}, as: :profile)
     )
     |> put_flash(:info, "Profile deleted. Participants added from it stay in their rooms.")}
  end

  def handle_event("add-profile", %{"id" => id}, %{assigns: %{room: room}} = socket)
      when not is_nil(room) do
    case Chat.add_profile_to_room(room.id, String.to_integer(id)) do
      {:ok, agent} ->
        {:noreply,
         socket
         |> assign(panel: nil)
         |> put_flash(:info, "@#{agent.name} joined #{room.name}.")
         |> refresh()}

      {:error, changeset} ->
        {:noreply, assign(socket, form_error: errors(changeset))}
    end
  end

  def handle_event("add-profile", _, socket), do: {:noreply, socket}

  def handle_event("remove-agent", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.agents, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      agent ->
        case Coordinator.remove_agent(agent.id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(panel: nil, editing_agent: nil)
             |> put_flash(:info, "@#{agent.name} removed. What it said stays in the room.")
             |> refresh()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not remove @#{agent.name}.")}
        end
    end
  end

  def handle_event("remove-room", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.rooms, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      room ->
        case Coordinator.remove_room(room.id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> close_terminal()
             |> assign(panel: nil, editing_agent: nil)
             |> put_flash(:info, "#{room.name} and everything in it is gone.")
             |> push_patch(to: ~p"/")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not remove #{room.name}.")}
        end
    end
  end

  def handle_event("edit-room", _, %{assigns: %{room: room}} = socket) when not is_nil(room) do
    attrs = %{"name" => room.name, "directory" => room.directory, "context" => room.context}

    {:noreply,
     assign(socket,
       panel: "room",
       editing_room: room.id,
       editing_agent: nil,
       form_error: nil,
       directory_options: [],
       room_form: to_form(attrs, as: :room)
     )}
  end

  def handle_event("edit-room", _, socket), do: {:noreply, socket}

  def handle_event("edit-agent", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.agents, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      agent ->
        attrs = %{
          "name" => agent.name,
          "provider" => agent.provider,
          "role" => agent.role,
          "model" => agent.model,
          "cost_tier" => agent.cost_tier,
          "auto_approve" => to_string(agent.auto_approve),
          "directory" => agent.directory
        }

        {:noreply,
         assign(socket,
           panel: "agent",
           model_options: Roundtable.Agents.models(agent.provider),
           editing_agent: agent.id,
           editing_renamable: Chat.renamable?(agent),
           form_error: nil,
           agent_form: to_form(attrs, as: :agent)
         )}
    end
  end

  def handle_event("open-terminal", _, %{assigns: %{room: room}} = socket)
      when not is_nil(room) do
    if socket.assigns.terminal do
      {:noreply, socket}
    else
      case Roundtable.Terminal.start_link(owner: self(), directory: room.directory) do
        {:ok, terminal} ->
          {:noreply, assign(socket, terminal: terminal)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not open a terminal: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("open-terminal", _, socket), do: {:noreply, socket}

  def handle_event("close-terminal", _, socket), do: {:noreply, close_terminal(socket)}

  def handle_event("terminal-input", %{"data" => data}, socket) do
    if socket.assigns.terminal, do: Roundtable.Terminal.input(socket.assigns.terminal, data)
    {:noreply, socket}
  end

  def handle_event("terminal-resize", %{"rows" => rows, "cols" => cols}, socket) do
    if socket.assigns.terminal,
      do: Roundtable.Terminal.resize(socket.assigns.terminal, rows, cols)

    {:noreply, socket}
  end

  def handle_event("toggle-diff", _, socket) do
    if socket.assigns.diff do
      {:noreply, assign(socket, diff: nil)}
    else
      {:noreply, assign(socket, diff: read_diff(socket))}
    end
  end

  def handle_event("close-panel", _, socket),
    do:
      {:noreply,
       assign(socket, panel: nil, form_error: nil, editing_agent: nil, editing_room: nil)}

  def handle_event("create-room", %{"room" => attrs}, %{assigns: %{editing_room: id}} = socket)
      when not is_nil(id) do
    case Chat.update_room(id, attrs) do
      {:ok, _} ->
        {:noreply, socket |> assign(panel: nil, editing_room: nil) |> reload_room()}

      {:error, changeset} ->
        {:noreply,
         assign(socket, form_error: errors(changeset), room_form: to_form(attrs, as: :room))}
    end
  end

  def handle_event("build-team", %{"team" => attrs}, socket) do
    case Coordinator.build_team(attrs) do
      {:ok, room} ->
        {:noreply, push_patch(socket, to: ~p"/rooms/#{room.id}")}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           form_error: errors(changeset),
           team_form: to_form(attrs, as: :team)
         )}
    end
  end

  def handle_event("create-room", %{"room" => attrs}, socket) do
    case Chat.create_room(attrs) do
      {:ok, room} ->
        {:noreply, push_patch(socket, to: ~p"/rooms/#{room.id}")}

      {:error, changeset} ->
        {:noreply,
         assign(socket, form_error: errors(changeset), room_form: to_form(attrs, as: :room))}
    end
  end

  def handle_event("create-agent", %{"agent" => attrs}, %{assigns: %{editing_agent: id}} = socket)
      when not is_nil(id) do
    case Chat.update_agent(id, attrs) do
      {:ok, _} ->
        {:noreply, socket |> assign(panel: nil, editing_agent: nil) |> refresh()}

      {:error, changeset} ->
        {:noreply,
         assign(socket, form_error: errors(changeset), agent_form: to_form(attrs, as: :agent))}
    end
  end

  def handle_event("create-agent", %{"agent" => attrs}, socket) do
    preset =
      Enum.find(
        socket.assigns.model_presets,
        &(to_string(&1.id) == attrs["preset_id"] && &1.provider == attrs["provider"])
      )

    attrs =
      if preset,
        do: Map.merge(attrs, %{"model" => preset.model, "cost_tier" => preset.cost_tier}),
        else: attrs

    case Chat.create_agent(socket.assigns.room.id, attrs) do
      {:ok, _} ->
        {:noreply, socket |> assign(panel: nil) |> refresh()}

      {:error, changeset} ->
        {:noreply,
         assign(socket, form_error: errors(changeset), agent_form: to_form(attrs, as: :agent))}
    end
  end

  def handle_event("draft", %{"message" => attrs}, socket) do
    attrs =
      if attrs["to"] != socket.assigns.message_form[:to].value,
        do: Map.put(attrs, "preset_id", ""),
        else: attrs

    {:noreply, assign(socket, message_form: to_form(attrs, as: :message))}
  end

  def handle_event("room-draft", %{"room" => attrs}, socket) do
    {:noreply,
     assign(socket,
       room_form: to_form(attrs, as: :room),
       directory_options: Roundtable.Directories.suggest(attrs["directory"] || "")
     )}
  end

  def handle_event("pick-directory", %{"path" => path}, socket) do
    attrs = Map.put(socket.assigns.room_form.params, "directory", path)

    {:noreply,
     assign(socket,
       room_form: to_form(attrs, as: :room),
       # One click in, the next level out: picking is how you walk down a tree.
       directory_options: Roundtable.Directories.suggest(path <> "/")
     )}
  end

  def handle_event("agent-draft", %{"agent" => attrs}, socket) do
    attrs =
      if attrs["provider"] != socket.assigns.agent_form[:provider].value,
        do: Map.put(attrs, "preset_id", ""),
        else: attrs

    {:noreply,
     assign(socket,
       agent_form: to_form(attrs, as: :agent),
       model_options: Roundtable.Agents.models(attrs["provider"])
     )}
  end

  def handle_event("refresh-models", _, socket) do
    models = Roundtable.Agents.refresh_models(socket.assigns.agent_form[:provider].value)
    {:noreply, assign(socket, model_options: models)}
  end

  def handle_event("save-preset", %{"preset" => attrs}, socket) do
    result =
      if socket.assigns.editing_preset,
        do: Chat.update_model_preset(socket.assigns.editing_preset, attrs),
        else: Chat.create_model_preset(attrs)

    case result do
      {:ok, _} ->
        {:noreply,
         assign(socket,
           model_presets: Chat.model_presets(),
           editing_preset: nil,
           editing_agent: nil,
           preset_form:
             to_form(%{"provider" => attrs["provider"], "cost_tier" => "unknown"}, as: :preset),
           form_error: nil
         )}

      {:error, changeset} ->
        {:noreply,
         assign(socket, form_error: errors(changeset), preset_form: to_form(attrs, as: :preset))}
    end
  end

  def handle_event("edit-preset", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.model_presets, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      preset ->
        attrs =
          preset
          |> Map.take([:name, :provider, :model, :cost_tier])
          |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

        {:noreply,
         assign(socket, editing_preset: preset.id, preset_form: to_form(attrs, as: :preset))}
    end
  end

  def handle_event("send", %{"message" => attrs}, socket) do
    body = String.trim(attrs["body"] || "")
    target = Enum.find(socket.assigns.agents, &(&1.name == attrs["to"]))
    body = if target && body != "", do: "@#{target.name} " <> body, else: body

    assignment =
      if target,
        do: Chat.assignment(target, attrs["preset_id"], attrs["purpose"] || "general"),
        else: {:ok, nil}

    result =
      with {:ok, options} <- assignment,
           do: Coordinator.post(socket.assigns.room.id, body, assignment: options)

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(message_form: to_form(Map.put(attrs, "body", ""), as: :message))
         |> refresh()
         |> push_event("sent", %{})}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, to_string(error))}
    end
  end

  def handle_event(action, %{"id" => id}, socket) when action in ["stop", "reset"] do
    case {action, Enum.find(socket.assigns.agents, &(to_string(&1.id) == id))} do
      {_, nil} -> :ok
      {"stop", agent} -> Coordinator.stop(agent.id)
      {"reset", agent} -> Coordinator.reset(agent.id)
    end

    {:noreply, refresh(socket)}
  end

  def handle_event("retry", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.runs, &(to_string(&1.id) == id)) do
      nil -> :ok
      run -> Coordinator.retry(run.id)
    end

    {:noreply, refresh(socket)}
  end

  def handle_event(
        "approval",
        %{"run" => run, "request" => request, "decision" => decision},
        socket
      ) do
    with {run_id, ""} <- Integer.parse(run),
         {:ok, request_id} <- Jason.decode(request),
         true <-
           Enum.any?(
             socket.assigns.approvals,
             &(&1.run_id == run_id && &1.request_id == request_id)
           ) do
      Coordinator.approve(run_id, request_id, decision)
    end

    {:noreply, refresh(socket)}
  end

  # The request in front of you is where this decision belongs: allow it, and
  # say that this participant may go on without asking.
  def handle_event("always-allow", %{"run" => run, "request" => request, "agent" => name}, socket) do
    socket =
      case Enum.find(socket.assigns.agents, &(&1.name == name)) do
        nil ->
          socket

        agent ->
          Chat.update_agent(agent.id, %{"auto_approve" => true})
          put_flash(socket, :info, "#{agent.name} approves its own tool use from now on.")
      end

    handle_event(
      "approval",
      %{"run" => run, "request" => request, "decision" => "accept"},
      socket
    )
  end

  @impl true
  def handle_info({:terminal_output, data}, socket),
    do: {:noreply, push_event(socket, "terminal-output", %{data: data})}

  def handle_info({:terminal_exit, _status}, socket) do
    {:noreply, socket |> assign(terminal: nil) |> push_event("terminal-closed", %{})}
  end

  def handle_info(:poll_git, socket), do: {:noreply, poll_git(socket)}

  def handle_info(:room_updated, socket), do: {:noreply, refresh(socket)}

  def handle_info(:rooms_updated, socket),
    do: {:noreply, assign(socket, rooms: Chat.rooms(), model_presets: Chat.model_presets())}

  defp close_terminal(%{assigns: %{terminal: nil}} = socket), do: socket

  defp close_terminal(socket) do
    GenServer.stop(socket.assigns.terminal, :normal)
    assign(socket, terminal: nil)
  catch
    # Already gone: the shell exited, or the page is being torn down.
    :exit, _ -> assign(socket, terminal: nil)
  end

  # Git runs off the socket: a large repository must not hold up a render.
  defp poll_git(%{assigns: %{room: nil}} = socket), do: socket

  defp poll_git(socket) do
    case Roundtable.Git.status(socket.assigns.room.directory) do
      {:ok, changes} -> assign(socket, changes: changes)
      {:error, _} -> assign(socket, changes: nil)
    end
  end

  defp read_diff(%{assigns: %{room: nil}}), do: nil

  defp read_diff(socket) do
    case Roundtable.Git.diff(socket.assigns.room.directory) do
      {:ok, ""} -> "No changes yet."
      {:ok, patch} -> patch
      {:error, reason} -> reason
    end
  end

  # The header and the brief are drawn from the room in the assigns, so a change
  # to the room itself has to be read back rather than only its children.
  defp reload_room(%{assigns: %{room: nil}} = socket), do: refresh(socket)

  defp reload_room(socket),
    do: socket |> assign(room: Chat.room!(socket.assigns.room.id)) |> refresh()

  defp refresh(%{assigns: %{room: nil}} = socket), do: assign(socket, rooms: Chat.rooms())

  defp refresh(socket) do
    id = socket.assigns.room.id

    messages = Chat.messages_after(id, socket.assigns.last_message_id)

    last_id =
      case List.last(messages) do
        nil -> socket.assigns.last_message_id
        message -> message.id
      end

    socket
    |> stream(:messages, messages)
    |> assign(
      last_message_id: last_id,
      rooms: Chat.rooms(),
      agents: Chat.agents(id),
      schedules: Chat.schedules(id),
      notes: Chat.room_notes(id),
      runs: Chat.runs(id),
      approvals: Coordinator.approvals() |> Map.values() |> Enum.filter(&(&1.room_id == id))
    )
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, val}, acc ->
        String.replace(acc, "%{#{key}}", to_string(val))
      end)
    end)
    |> Enum.map_join(" · ", fn {key, val} -> "#{key}: #{Enum.join(val, ", ")}" end)
  end

  # A new schedule starts on whoever is already here, at an hour somebody might
  # actually want: the morning, every day.
  defp schedule_form(agents) do
    to_form(
      %{
        "agent_id" => agents |> List.first() |> then(&if(&1, do: to_string(&1.id), else: "")),
        "name" => "Daily check-in",
        "at" => "09:00",
        "days" => "",
        "enabled" => "true"
      },
      as: :schedule
    )
  end

  # A new note starts as a convention: the kind a room has most of, and the one
  # someone reaches for when writing down how things are done here. Its selects
  # are re-keyed on every save — see `note_seq` — because a browser will not
  # re-select a dropdown the person has already touched, however the server
  # re-renders it, and a sticky "Always, before the rest" pins every note after
  # the first one without saying so.
  defp note_form, do: to_form(%{"kind" => "convention", "pinned" => "false"}, as: :note)

  defp note_kinds, do: Enum.map(RoomNote.kinds(), &{note_kind(&1), &1})

  defp note_kind("convention"), do: "Convention — how this room works"
  defp note_kind("decision"), do: "Decision — what was settled, and why"
  defp note_kind("gotcha"), do: "Gotcha — what caught someone out"
  defp note_kind("scratch"), do: "Scratch — kept here, not sent to anyone"

  defp day_options(days) do
    known = [{"Every day", ""}, {"Weekdays", "1,2,3,4,5"}, {"Weekends", "6,7"}]

    if is_binary(days) and days != "" and days not in Enum.map(known, &elem(&1, 1)),
      do: known ++ [{"Days chosen earlier", days}],
      else: known
  end

  defp status(agent, runs) do
    own = Enum.filter(runs, &(&1.agent_id == agent.id))
    active = Enum.find(own, &(&1.status in ["running", "approval", "queued"]))
    if active, do: active.status, else: "idle"
  end

  # A visible list beats a datalist nobody discovers. Whatever the agent already
  # has is kept as an option, so editing does not silently drop a model this
  # CLI no longer lists.
  defp model_options(models, current) do
    known = [{"Provider default", ""} | Enum.map(models, &{&1, &1})]

    if is_binary(current) and current != "" and current not in models,
      do: known ++ [{current <> " (set earlier)", current}],
      else: known
  end

  defp preset_options(presets, provider) do
    [
      {"Agent default", ""}
      | Enum.filter(presets, &(&1.provider == provider))
        |> Enum.map(&{"#{&1.name} · #{&1.cost_tier}", to_string(&1.id)})
    ]
  end

  defp selected_provider(agents, name) do
    case Enum.find(agents, &(&1.name == name)) do
      nil -> nil
      agent -> agent.provider
    end
  end

  # The first provider that is installed and can name its models, so the form
  # opens on something with a list rather than an empty one.
  defp team_provider(providers) do
    case Enum.find(providers, &(&1.installed and &1.id in ["codex", "claude"])) do
      nil -> "codex"
      provider -> provider.id
    end
  end

  defp default_provider do
    providers = Roundtable.Agents.providers()

    listed =
      Enum.find(providers, &(&1.installed and Roundtable.Agents.models(&1.id) != []))

    installed = Enum.find(providers, & &1.installed)
    (listed || installed || List.first(providers)).id
  end

  defp cost_options,
    do: [
      {"Unrated", "unknown"},
      {"Economy · routine tasks", "economy"},
      {"Standard · balanced", "standard"},
      {"Premium · planning & review", "premium"}
    ]

  defp initials(name), do: name |> String.slice(0, 2) |> String.upcase()

  def time(datetime) do
    format =
      if DateTime.to_date(datetime) == Date.utc_today(), do: "%H:%M", else: "%d %b %Y · %H:%M"

    Calendar.strftime(datetime, format)
  end

  defp active_runs(runs),
    do: Enum.filter(runs, &(&1.status in ["running", "approval", "queued"])) |> Enum.reverse()

  defp failed_runs(runs),
    do: Enum.filter(runs, &(&1.status in ["failed", "interrupted", "stopped"]))
end
