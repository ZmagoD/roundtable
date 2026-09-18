defmodule RoundtableWeb.RoomLive do
  use RoundtableWeb, :live_view
  alias Roundtable.{Chat, Coordinator}

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
       preset_form: to_form(%{"cost_tier" => "unknown"}, as: :preset),
       editing_preset: nil,
       editing_agent: nil,
       editing_renamable: true,
       room_form: to_form(%{}, as: :room),
       agent_form: to_form(%{}, as: :agent),
       runs: [],
       approvals: [],
       providers: Roundtable.Agents.providers(),
       model_options: [],
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
    socket = assign(socket, editing_agent: nil, editing_renamable: true)
    room_form = to_form(%{"directory" => socket.assigns.directory}, as: :room)

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
       form_error: nil,
       model_options: Roundtable.Agents.models(agent_form[:provider].value),
       room_form: room_form,
       agent_form: agent_form,
       preset_form:
         to_form(%{"provider" => List.first(Roundtable.Agents.ids()), "cost_tier" => "unknown"},
           as: :preset
         ),
       editing_preset: nil,
       editing_agent: nil,
       editing_renamable: true
     )}
  end

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
    do: {:noreply, assign(socket, panel: nil, form_error: nil, editing_agent: nil)}

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
  defp time(datetime), do: Calendar.strftime(datetime, "%H:%M")

  defp active_runs(runs),
    do: Enum.filter(runs, &(&1.status in ["running", "approval", "queued"])) |> Enum.reverse()

  defp failed_runs(runs),
    do: Enum.filter(runs, &(&1.status in ["failed", "interrupted", "stopped"]))
end
