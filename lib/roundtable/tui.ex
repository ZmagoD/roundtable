defmodule Roundtable.TUI do
  @moduledoc """
  The terminal client's event loop.

  Owns the terminal, a reader process for raw stdin, and a subscription to the
  service's room activity. Keys become effects in `Roundtable.TUI.State`; this
  module is the only place that performs them.

  The terminal is always restored, including on a crash, so a failure here
  never leaves a shell in raw mode.
  """
  alias Roundtable.Client
  alias Roundtable.TUI.{Keys, Render, State, Terminal}

  @tick 1_000
  # Two ticks between git polls: fast enough to watch a turn edit files,
  # slow enough that a large repository is not restatted every second.
  @poll_ticks 2

  def run(%Client{} = client) do
    Terminal.configure_io()

    case Terminal.raw_mode() do
      :ok ->
        reader = spawn_link(__MODULE__, :read_loop, [self()])
        Terminal.enter_screen()

        try do
          {:ok, start(client)}
        after
          Process.unlink(reader)
          Process.exit(reader, :kill)
          Terminal.leave_screen()
          Terminal.restore()
        end

      {:error, _reason} ->
        {:error, :no_terminal}
    end
  end

  @doc false
  def read_loop(parent) do
    case Terminal.read_byte() do
      :eof ->
        send(parent, :input_closed)

      byte ->
        send(parent, {:input, byte})
        read_loop(parent)
    end
  end

  defp start(client) do
    if client.node, do: :net_kernel.monitor_nodes(true)
    :timer.send_interval(@tick, :tick)

    state =
      State.new(
        size: Terminal.size(),
        target: Client.describe(client),
        status: "Connected to #{Client.describe(client)}. /help for commands."
      )

    room = client |> Client.rooms() |> first_room()
    {:ok, relay} = watch(client, room)

    %{
      client: client,
      state: state,
      relay: relay,
      room_id: room && room.id,
      buffer: "",
      polling: false,
      ticks: 0
    }
    |> refresh()
    |> poll_git()
    |> draw()
    |> loop()
  end

  defp loop(context) do
    receive do
      {:input, byte} ->
        {keys, buffer} = Keys.decode(context.buffer <> byte)

        context =
          Enum.reduce(keys, %{context | buffer: buffer}, fn key, acc ->
            {state, effects} = State.handle_key(acc.state, key)
            Enum.reduce(effects, %{acc | state: state}, &perform/2)
          end)

        if context.state.quit, do: context.state, else: context |> draw() |> loop()

      message when message in [:room_updated, :rooms_updated] ->
        context |> drain() |> refresh() |> poll_git() |> draw() |> loop()

      :tick ->
        size = Terminal.size()
        context = %{context | ticks: context.ticks + 1}

        context =
          if rem(context.ticks, @poll_ticks) == 0, do: poll_git(context), else: context

        if size == context.state.size do
          loop(context)
        else
          %{context | state: State.put_size(context.state, size)} |> draw() |> loop()
        end

      {:changes, result} ->
        changes =
          case result do
            {:ok, changes} -> changes
            error -> error
          end

        %{context | polling: false, state: State.put_changes(context.state, changes)}
        |> draw()
        |> loop()

      {:nodedown, _} ->
        %{context | state: State.put_connected(context.state, false)} |> draw() |> loop()

      {:nodeup, _} ->
        context = %{context | state: State.put_connected(context.state, true)}
        {:ok, relay} = watch(context.client, context.state.room)
        %{context | relay: relay} |> refresh() |> draw() |> loop()

      :watch_ready ->
        loop(context)

      :input_closed ->
        :ok

      _other ->
        loop(context)
    end
  end

  # Collapse a burst of updates (a streaming agent) into one refresh.
  defp drain(context) do
    receive do
      message when message in [:room_updated, :rooms_updated] -> drain(context)
    after
      0 -> context
    end
  end

  # Runs git off the event loop: a big repository must never stall a keystroke.
  defp poll_git(%{polling: true} = context), do: context

  defp poll_git(context) do
    directory = State.watched_directory(context.state)

    if context.state.changes_visible and directory do
      parent = self()
      spawn(fn -> send(parent, {:changes, Roundtable.Git.status(directory)}) end)
      %{context | polling: true}
    else
      context
    end
  end

  # --- effects ---------------------------------------------------------------

  # Public only so the suite can drive an effect without owning a terminal:
  # everything below talks to the client and the state, never to the screen.
  @doc false
  def perform(effect, context)

  def perform(:quit, context), do: context
  def perform(:refresh, context), do: refresh(context)

  def perform(:resize, context),
    do: %{context | state: State.put_size(context.state, Terminal.size())}

  def perform({:post, _body}, %{state: %{room: nil}} = context),
    do: status(context, "Create a room first: /new-room <name> <directory>")

  def perform({:post, body}, context) do
    case Client.post(context.client, context.state.room.id, body) do
      {:ok, _} -> refresh(context)
      {:error, reason} -> status(context, describe(reason))
      other -> status(context, describe(other))
    end
  end

  def perform({:switch_room, room_id}, context) do
    Client.rewatch(context.client, context.relay, context.room_id, room_id)
    %{context | room_id: room_id} |> refresh() |> status(nil)
  end

  def perform({:create_room, name, directory}, context) do
    case Client.create_room(context.client, %{"name" => name, "directory" => directory}) do
      {:ok, room} ->
        Client.rewatch(context.client, context.relay, context.room_id, room.id)
        %{context | room_id: room.id} |> refresh() |> status("Room #{room.name} created.")

      {:error, reason} ->
        status(context, describe(reason))
    end
  end

  def perform({:create_agent, _}, %{state: %{room: nil}} = context),
    do: status(context, "Create a room first: /new-room <name> <directory>")

  def perform({:create_agent, attrs}, context) do
    attrs = Map.put_new_lazy(attrs, "directory", fn -> context.state.room.directory end)
    attrs = Map.update!(attrs, "directory", &expand(&1 || context.state.room.directory))

    case Client.create_agent(context.client, context.state.room.id, attrs) do
      {:ok, agent} -> refresh(context) |> status(joined(agent))
      {:error, reason} -> status(context, describe(reason))
    end
  end

  def perform({:cross_room, _kind, _target, _body}, %{state: %{room: nil}} = context),
    do: status(context, "Open a room first.")

  def perform({:cross_room, kind, target, body}, context) do
    case Client.cross_room_request(context.client, kind, context.state.room.id, target, body) do
      {:ok, request} ->
        refresh(context)
        |> status("Sent to #{target}. The reply lands here (request ##{request.id}).")

      {:error, reason} ->
        status(context, describe(reason))
    end
  end

  def perform({:remove_agent, agent_id, name}, context) do
    case Client.remove_agent(context.client, agent_id) do
      {:ok, _} -> refresh(context) |> status("@#{name} removed. What it said stays.")
      {:error, reason} -> status(context, describe(reason))
      other -> status(context, describe(other))
    end
  end

  def perform({:remove_room, room_id, name}, context) do
    case Client.remove_room(context.client, room_id) do
      {:ok, _} ->
        %{context | room_id: nil}
        |> refresh()
        |> status("#{name} and everything in it is gone.")

      {:error, reason} ->
        status(context, describe(reason))

      other ->
        status(context, describe(other))
    end
  end

  def perform({:update_agent, agent_id, attrs}, context) do
    case Client.update_agent(context.client, agent_id, attrs) do
      {:ok, agent} -> refresh(context) |> status("@#{agent.name} updated.")
      {:error, reason} -> status(context, describe(reason))
    end
  end

  def perform({:approve, run_id, request_id, decision}, context) do
    case Client.approve(context.client, run_id, request_id, decision) do
      :ok -> refresh(context) |> status("Approval #{decision}ed.")
      {:error, reason} -> status(context, describe(reason))
      other -> status(context, describe(other))
    end
  end

  def perform({action, id}, context) when action in [:stop, :reset, :retry] do
    apply(Client, action, [context.client, id])
    refresh(context) |> status("#{action} sent.")
  end

  def perform(:providers, context) do
    listed =
      Roundtable.Agents.providers()
      |> Enum.map_join(" · ", &"#{&1.id}#{if &1.installed, do: "", else: " (not installed)"}")

    status(context, listed)
  end

  def perform({:models, args}, context) do
    case String.split(args, " ", parts: 2) do
      [provider | rest] when provider != "" ->
        filter = List.first(rest) || ""
        models = Roundtable.Agents.models(provider)
        status(context, describe_models(provider, models, filter))

      _ ->
        status(context, "Usage: /models <provider> [filter]")
    end
  end

  def perform(:git_ui, context) do
    directory = State.watched_directory(context.state)

    cond do
      is_nil(directory) ->
        status(context, "No room selected.")

      path = System.get_env("ROUNDTABLE_TUI_HANDOFF") ->
        # The BEAM starts children in their own session, so a spawned lazygit
        # would have no terminal. The launcher owns it; hand the request back.
        command = System.get_env("ROUNDTABLE_GIT_UI") || "lazygit"
        handoff = %{path: path, directory: directory, command: command}
        %{context | state: %{context.state | handoff: handoff, quit: true}}

      true ->
        status(
          context,
          "lazygit needs the launcher to hand over the terminal. Start with bin/roundtable tui."
        )
    end
  end

  def perform(_, context), do: context

  # --- data -----------------------------------------------------------------

  defp refresh(context) do
    client = context.client
    rooms = Client.rooms(client)

    room =
      case context.room_id do
        nil -> first_room(rooms)
        id -> Enum.find(rooms, &(&1.id == id))
      end

    data =
      if room do
        [
          rooms: rooms,
          room: room,
          agents: Client.agents(client, room.id),
          messages: Client.messages(client, room.id),
          runs: Client.runs(client, room.id),
          approvals: Client.approvals(client, room.id)
        ]
      else
        [rooms: rooms, room: nil, agents: [], messages: [], runs: [], approvals: []]
      end

    if Enum.any?(data, &match?({_, {:error, _}}, &1)) do
      %{context | state: State.put_connected(context.state, false)}
    else
      %{
        context
        | room_id: room && room.id,
          state: context.state |> State.put_data(data) |> State.put_connected(true)
      }
    end
  end

  defp watch(client, room) do
    case Client.watch(client, self(), room && room.id) do
      {:ok, relay} -> {:ok, relay}
      _ -> {:ok, nil}
    end
  end

  defp first_room(rooms) when is_list(rooms), do: List.first(rooms)
  defp first_room(_), do: nil

  # Creating it is still right — the CLI may be installed later — but silence
  # would mean finding out at the first turn, from a spawn failure.
  defp joined(agent) do
    if Enum.any?(Roundtable.Agents.providers(), &(&1.id == agent.provider and &1.installed)),
      do: "@#{agent.name} joined.",
      else: "@#{agent.name} joined, but #{agent.provider} is not installed on PATH."
  end

  defp describe_models(provider, [], _filter),
    do: "#{provider} does not list its models. Any name it accepts works."

  defp describe_models(provider, models, filter) do
    case Enum.filter(models, &String.contains?(&1, filter)) do
      [] ->
        "No #{provider} model matches #{inspect(filter)} of #{length(models)}."

      matching ->
        shown = Enum.take(matching, 8)
        more = length(matching) - length(shown)
        suffix = if more > 0, do: " … and #{more} more of #{length(models)}", else: ""
        "#{provider}: #{Enum.join(shown, ", ")}#{suffix}"
    end
  end

  # Resolved here, in the client, because this process runs in the shell the
  # person started it from. The service is somewhere else entirely, and "." to
  # it would mean its own install directory.
  defp expand(directory) when is_binary(directory), do: Path.expand(directory)
  defp expand(other), do: other

  defp status(context, message), do: %{context | state: State.put_status(context.state, message)}

  defp draw(context) do
    Terminal.write(Render.render(context.state))
    context
  end

  defp describe(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join(" · ", fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(:disconnected), do: "Lost the service connection."
  defp describe(:timeout), do: "The service did not answer in time."
  defp describe(reason), do: inspect(reason)
end
