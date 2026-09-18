defmodule Roundtable.TUI.State do
  @moduledoc """
  The terminal client's model and its key handling.

  `handle_key/2` is pure: it returns the next state plus a list of effects for
  the event loop to carry out against `Roundtable.Client`. Nothing here talks to
  the service or the terminal, so the whole interaction surface is testable.
  """
  alias Roundtable.TUI.Render

  defstruct rooms: [],
            room: nil,
            agents: [],
            messages: [],
            runs: [],
            approvals: [],
            input: "",
            cursor: 0,
            scroll: 0,
            size: {24, 80},
            status: nil,
            connected: true,
            target: "",
            mode: :message,
            changes: nil,
            changes_visible: true,
            changes_target: nil,
            roster_visible: false,
            help_visible: false,
            handoff: nil,
            quit: false

  @providers ~w(codex claude opencode)

  def new(attrs \\ []), do: struct!(__MODULE__, attrs)

  @doc "Status shown for an agent, mirroring the web UI's rules."
  def agent_status(agent, runs) do
    runs
    |> Enum.filter(&(&1.agent_id == agent.id))
    |> Enum.find(&(&1.status in ["running", "approval", "queued"]))
    |> case do
      nil -> "idle"
      run -> run.status
    end
  end

  @doc "Applies freshly fetched room data without disturbing the input line."
  def put_data(state, data) do
    %{
      state
      | rooms: Keyword.get(data, :rooms, state.rooms),
        room: Keyword.get(data, :room, state.room),
        agents: Keyword.get(data, :agents, state.agents),
        messages: Keyword.get(data, :messages, state.messages),
        runs: Keyword.get(data, :runs, state.runs),
        approvals: Keyword.get(data, :approvals, state.approvals)
    }
  end

  @doc """
  The directory whose changes the pane watches.

  Agents can be given their own working directory (a separate worktree, say),
  so `/changes <agent>` follows that agent instead of the room.
  """
  def watched_directory(%{room: nil}), do: nil

  def watched_directory(state) do
    agent = Enum.find(state.agents, &(&1.name == state.changes_target))
    (agent && agent.directory) || state.room.directory
  end

  def put_changes(state, changes), do: %{state | changes: changes}

  def put_status(state, status), do: %{state | status: status}
  def clear_status(state), do: %{state | status: nil}
  def put_size(state, size), do: %{state | size: size}
  def put_connected(state, connected?), do: %{state | connected: connected?}

  @doc "Returns `{state, effects}`."
  def handle_key(state, key)

  def handle_key(state, key) when key in [:ctrl_c, :ctrl_d],
    do: {%{state | quit: true}, [:quit]}

  def handle_key(state, :ctrl_l), do: {clear_status(state), [:resize]}

  def handle_key(state, :ctrl_t),
    do: {%{clear_status(state) | changes_visible: not state.changes_visible}, []}

  def handle_key(state, :ctrl_g), do: {clear_status(state), [:git_ui]}

  def handle_key(state, :ctrl_p),
    do: {%{clear_status(state) | roster_visible: not state.roster_visible}, []}

  def handle_key(state, :enter), do: submit(clear_status(state))

  def handle_key(%{input: ""} = state, {:char, "?"}),
    do: {%{clear_status(state) | help_visible: not state.help_visible, scroll: 0}, []}

  def handle_key(state, {:char, char}) do
    {before, rest} = split(state)
    {%{state | input: before <> char <> rest, cursor: state.cursor + 1} |> retype(), []}
  end

  def handle_key(%{cursor: 0} = state, :backspace), do: {state, []}

  def handle_key(state, :backspace) do
    {before, rest} = split(state)
    kept = String.slice(before, 0, String.length(before) - 1)
    {%{state | input: kept <> rest, cursor: state.cursor - 1} |> retype(), []}
  end

  def handle_key(state, :delete) do
    {before, rest} = split(state)
    {%{state | input: before <> String.slice(rest, 1..-1//1)} |> retype(), []}
  end

  def handle_key(state, :left), do: {%{state | cursor: max(state.cursor - 1, 0)}, []}

  def handle_key(state, :right),
    do: {%{state | cursor: min(state.cursor + 1, String.length(state.input))}, []}

  def handle_key(state, :home), do: {%{state | cursor: 0}, []}
  def handle_key(state, :end_key), do: {%{state | cursor: String.length(state.input)}, []}

  def handle_key(state, :ctrl_u) do
    {_, rest} = split(state)
    {%{state | input: rest, cursor: 0} |> retype(), []}
  end

  def handle_key(state, :ctrl_w) do
    {before, rest} = split(state)
    kept = String.replace(before, ~r/\S*\s*$/u, "")
    {%{state | input: kept <> rest, cursor: String.length(kept)} |> retype(), []}
  end

  def handle_key(state, :up), do: {scroll(state, 1), []}
  def handle_key(state, :down), do: {scroll(state, -1), []}
  def handle_key(state, :page_up), do: {scroll(state, body_height(state)), []}
  def handle_key(state, :page_down), do: {scroll(state, -body_height(state)), []}

  def handle_key(%{help_visible: true} = state, :escape),
    do: {%{state | help_visible: false}, []}

  def handle_key(%{roster_visible: true} = state, :escape),
    do: {%{state | roster_visible: false}, []}

  def handle_key(state, :escape), do: {%{state | input: "", cursor: 0} |> retype(), []}
  def handle_key(state, :tab), do: {cycle_recipient(state), []}
  def handle_key(state, _), do: {state, []}

  defp split(state) do
    {String.slice(state.input, 0, state.cursor),
     String.slice(state.input, state.cursor..-1//1) || ""}
  end

  defp retype(state),
    do: %{state | mode: if(String.starts_with?(state.input, "/"), do: :command, else: :message)}

  defp scroll(state, by) do
    max_scroll = max(Render.total_lines(state) - body_height(state), 0)
    %{state | scroll: (state.scroll + by) |> max(0) |> min(max_scroll)}
  end

  defp body_height(%{size: {rows, _}}), do: max(rows - 6, 1)

  defp cycle_recipient(%{agents: []} = state),
    do: put_status(state, "No agents in this room yet.")

  defp cycle_recipient(state) do
    names = Enum.map(state.agents, & &1.name)

    {current, body} =
      case Regex.run(~r/^@([a-z][a-z0-9_-]*)\s*(.*)$/s, state.input) do
        [_, name, rest] -> {name, rest}
        _ -> {nil, state.input}
      end

    next =
      case Enum.find_index(names, &(&1 == current)) do
        nil -> List.first(names)
        index -> Enum.at(names, rem(index + 1, length(names)))
      end

    input = "@#{next} " <> body
    %{state | input: input, cursor: String.length(input)} |> retype()
  end

  # --- submitting -----------------------------------------------------------

  defp submit(state) do
    case String.trim(state.input) do
      "" -> {state, []}
      "/" <> command -> command(clear_input(state), command)
      body -> {clear_input(state), [{:post, body}]}
    end
  end

  defp clear_input(state), do: %{state | input: "", cursor: 0, mode: :message, scroll: 0}

  defp command(state, command) do
    case String.split(String.trim(command), " ", parts: 2) do
      [name] -> dispatch(state, name, "")
      [name, rest] -> dispatch(state, name, String.trim(rest))
    end
  end

  defp dispatch(state, name, _args) when name in ~w(quit q exit),
    do: {%{state | quit: true}, [:quit]}

  defp dispatch(state, "help", _),
    do: {%{state | help_visible: not state.help_visible, scroll: 0}, []}

  defp dispatch(state, "commands", _) do
    {put_status(
       state,
       "/room <name> · /new-room <name> <dir> · /agent <name> <provider> [dir] · " <>
         "/stop <agent> · /reset <agent> · /retry [run] · /approve accept|decline [n] · " <>
         "/changes [agent|room|off] · /who · /role <agent> <text> · " <>
         "/model <agent> <id> · /rename <agent> <new> · /ask <room>/<agent> <q> · /delegate <room>/<agent> <task> · " <>
         "/lazygit · /quit"
     ), []}
  end

  defp dispatch(state, "rooms", _) do
    names = Enum.map_join(state.rooms, " · ", & &1.name)

    {put_status(state, if(names == "", do: "No rooms yet. /new-room <name> <dir>", else: names)),
     []}
  end

  defp dispatch(state, "room", ""), do: {put_status(state, "Usage: /room <name>"), []}

  defp dispatch(state, "room", name) do
    case find_room(state, name) do
      nil -> {put_status(state, "No room called #{name}."), []}
      room -> {%{state | scroll: 0}, [{:switch_room, room.id}]}
    end
  end

  defp dispatch(state, "new-room", args) do
    # The directory is the last path-looking token, so a room can be called
    # "Design Team" without its second word becoming the path. It may be
    # relative: the client resolves it against the shell it was started in,
    # which is the directory the person is actually sitting in.
    case Regex.run(~r/^(.+?)\s+([~.\/]\S*)$/, String.trim(args)) do
      [_, name, directory] ->
        {state, [{:create_room, name, directory}]}

      _ ->
        {put_status(state, "Usage: /new-room <name> <directory>, for example /new-room Web ."),
         []}
    end
  end

  defp dispatch(state, "agent", args) do
    {positional, flags} = split_flags(args)

    case String.split(positional, " ", trim: true) do
      [name, provider | rest] when provider in @providers ->
        directory = flags["dir"] || Enum.join(rest, " ")

        attrs =
          %{
            "name" => name,
            "provider" => provider,
            "directory" => if(directory == "", do: nil, else: directory)
          }
          |> put_given("role", flags["role"])
          |> put_given("model", flags["model"])
          |> put_given("cost_tier", flags["tier"])

        {state, [{:create_agent, attrs}]}

      [_, provider | _] ->
        {put_status(
           state,
           "Unknown provider #{provider}. One of: #{Enum.join(@providers, ", ")}"
         ), []}

      _ ->
        {put_status(
           state,
           "Usage: /agent <name> <#{Enum.join(@providers, "|")}> [dir] " <>
             "[--model m] [--role text] [--tier economy|standard|premium]"
         ), []}
    end
  end

  defp dispatch(state, "role", args) do
    case String.split(String.trim(args), " ", parts: 2) do
      [name, text] when text != "" ->
        with_agent(
          state,
          name,
          &{state, [{:update_agent, &1.id, %{"role" => unquote_value(text)}}]}
        )

      _ ->
        {put_status(state, "Usage: /role <agent> <what they should do>"), []}
    end
  end

  defp dispatch(state, "rename", args) do
    case String.split(String.trim(args), " ", parts: 2) do
      [name, new_name] when new_name != "" ->
        with_agent(
          state,
          name,
          &{state, [{:update_agent, &1.id, %{"name" => String.trim(new_name)}}]}
        )

      _ ->
        {put_status(state, "Usage: /rename <agent> <new name>"), []}
    end
  end

  defp dispatch(state, "model", args) do
    case String.split(String.trim(args), " ", parts: 2) do
      [name, model] when model != "" ->
        # "default" hands the choice back to the provider.
        value = if model in ["default", "-"], do: nil, else: unquote_value(model)
        with_agent(state, name, &{state, [{:update_agent, &1.id, %{"model" => value}}]})

      _ ->
        {put_status(state, "Usage: /model <agent> <model id|default>"), []}
    end
  end

  defp dispatch(state, kind, args) when kind in ~w(ask delegate) do
    case String.split(String.trim(args), " ", parts: 2) do
      [target, body] when body != "" ->
        {state, [{:cross_room, kind, target, body}]}

      _ ->
        {put_status(
           state,
           "Usage: /#{kind} <room>/<agent> <#{(kind == "ask" && "question") || "task"}>"
         ), []}
    end
  end

  defp dispatch(state, name, _) when name in ~w(who roster participants),
    do: {%{state | roster_visible: not state.roster_visible}, []}

  defp dispatch(state, action, name) when action in ~w(stop reset) do
    case Enum.find(state.agents, &(&1.name == String.trim(name))) do
      nil -> {put_status(state, "Usage: /#{action} <agent name>"), []}
      agent -> {state, [{String.to_existing_atom(action), agent.id}]}
    end
  end

  defp dispatch(state, "retry", args) do
    run =
      case Integer.parse(args) do
        {id, _} -> Enum.find(state.runs, &(&1.id == id))
        :error -> Enum.find(state.runs, &(&1.status in ["failed", "interrupted", "stopped"]))
      end

    case run do
      nil -> {put_status(state, "No failed run to retry."), []}
      run -> {state, [{:retry, run.id}]}
    end
  end

  defp dispatch(state, "approve", args) do
    case String.split(args, " ", trim: true) do
      [decision | rest] when decision in ["accept", "decline"] ->
        index = with [n] <- rest, {n, ""} <- Integer.parse(n), do: n, else: (_ -> 1)

        case Enum.at(state.approvals, index - 1) do
          nil -> {put_status(state, "No approval ##{index} is pending."), []}
          a -> {state, [{:approve, a.run_id, a.request_id, decision}]}
        end

      _ ->
        {put_status(state, "Usage: /approve accept|decline [number]"), []}
    end
  end

  defp dispatch(state, "changes", "off"), do: {%{state | changes_visible: false}, []}
  defp dispatch(state, "changes", ""), do: {%{state | changes_visible: true}, []}

  defp dispatch(state, "changes", "room"),
    do: {%{state | changes_visible: true, changes_target: nil}, []}

  defp dispatch(state, "changes", name) do
    case Enum.find(state.agents, &(&1.name == String.trim(name))) do
      nil -> {put_status(state, "No agent called #{name}. Try /changes room."), []}
      agent -> {%{state | changes_visible: true, changes_target: agent.name}, []}
    end
  end

  defp dispatch(state, name, _) when name in ~w(lazygit git), do: {state, [:git_ui]}

  defp dispatch(state, "refresh", _), do: {state, [:refresh]}

  defp dispatch(state, name, _),
    do: {put_status(state, "Unknown command /#{name}. Try /help."), []}

  defp with_agent(state, name, fun) do
    case Enum.find(state.agents, &(&1.name == String.trim(name))) do
      nil -> {put_status(state, "No agent called #{String.trim(name)}."), []}
      agent -> fun.(agent)
    end
  end

  defp put_given(attrs, _key, nil), do: attrs
  defp put_given(attrs, _key, ""), do: attrs
  defp put_given(attrs, key, value), do: Map.put(attrs, key, value)

  # "a b --model x --role do things" -> {"a b", %{"model" => "x", "role" => "do things"}}
  defp split_flags(args) do
    [positional | flags] = String.split(args, ~r/\s--/)

    {String.trim(positional),
     Map.new(flags, fn flag ->
       case String.split(flag, " ", parts: 2) do
         [key] -> {key, ""}
         [key, value] -> {key, unquote_value(String.trim(value))}
       end
     end)}
  end

  defp unquote_value(<<quote_char, _::binary>> = value) when quote_char in [?", ?'] do
    if String.last(value) == <<quote_char>> and String.length(value) > 1,
      do: String.slice(value, 1..-2//1),
      else: value
  end

  defp unquote_value(value), do: value

  defp find_room(state, name) do
    name = String.trim(name)

    Enum.find(state.rooms, &(&1.name == name)) ||
      Enum.find(state.rooms, &(String.downcase(&1.name) == String.downcase(name))) ||
      case Integer.parse(name) do
        {id, ""} -> Enum.find(state.rooms, &(&1.id == id))
        _ -> nil
      end
  end
end
