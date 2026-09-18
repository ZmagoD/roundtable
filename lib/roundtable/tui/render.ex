defmodule Roundtable.TUI.Render do
  @moduledoc """
  Draws the whole screen from a `Roundtable.TUI.State`.

  Pure: state in, iodata out, so the layout is testable without a terminal.
  Every line is padded to the exact terminal width *before* colour codes are
  added, because escape sequences occupy no columns and would otherwise throw
  the box drawing off.
  """
  alias Roundtable.TUI.{Commands, Markdown, State}

  @sidebar 18
  @gutter 2
  @sender 10
  # masthead, two rules, input, status
  @chrome 5

  @dim "\e[2m"
  @bold "\e[1m"
  @cyan "\e[36m"
  @yellow "\e[33m"
  @red "\e[31m"
  @green "\e[32m"
  @reset "\e[0m"

  @doc "Full-screen frame, cursor parked at the end of the input line."
  def render(%State{size: {rows, cols}} = state) when rows >= 8 and cols >= 40 do
    body = rows - @chrome
    width = cols - @sidebar - @gutter
    left = sidebar(state, body)
    # The changes pane takes from the transcript, never from the frame.
    changes = changes_lines(state, width, div(body, 2))

    palette = palette_lines(state, width)
    upper = upper_pane(state, body - length(changes) - length(palette), width)

    right = upper ++ palette ++ changes

    [
      "\e[H\e[2J",
      masthead(state, cols),
      rule(cols),
      Enum.zip(left, right)
      |> Enum.map(fn {l, r} -> [l, String.duplicate(" ", @gutter), r, "\n"] end),
      rule(cols),
      input_line(state, cols),
      status_line(state, cols),
      cursor_to(state, rows, cols)
    ]
  end

  def render(%State{size: {rows, _}}) do
    [
      "\e[H\e[2J",
      "Terminal too small for Roundtable.\r\n",
      "Need at least 8×40, have #{rows} rows."
    ]
  end

  @doc "How many lines the scrollable pane currently holds."
  def total_lines(%State{size: {_, cols}} = state) do
    width = cols - @sidebar - @gutter

    if state.help_visible,
      do: length(help_lines(width)),
      else: length(transcript_lines(state, width))
  end

  defp upper_pane(state, height, width) do
    cond do
      state.help_visible -> help(state, height, width)
      state.roster_visible -> roster(state, height, width)
      true -> transcript(state, height, width)
    end
  end

  defp masthead(state, cols) do
    where =
      case state.room do
        nil -> "no room"
        room -> "#{room.name}#{branch(state)} · #{room.directory}"
      end

    left = " roundtable"
    right = cut(where, max(cols - width(left) - 2, 0))
    gap = max(cols - width(left) - width(right) - 1, 1)

    [@bold, @green, left, @reset, String.duplicate(" ", gap), @dim, right, @reset, " \n"]
  end

  defp branch(%{changes: %{branch: branch}}) when is_binary(branch), do: " · " <> branch
  defp branch(_state), do: ""

  # A rule rather than a border: it separates without enclosing.
  defp rule(cols), do: [@dim, String.duplicate("─", cols), @reset, "\n"]

  defp sidebar(state, height) do
    rooms =
      Enum.map(state.rooms, fn room ->
        current? = state.room && room.id == state.room.id
        # An accent bar marks where you are; the others sit quietly behind it.
        bar = if current?, do: "▌", else: " "
        line = pad(" #{bar} #{cut(room.name, @sidebar - 4)}", @sidebar)
        if current?, do: [@green, @bold, line, @reset], else: [@dim, line, @reset]
      end)

    agents =
      Enum.map(state.agents, fn agent ->
        status = State.agent_status(agent, state.runs)
        {dot, colour} = agent_dot(status)
        name = cut(agent.name, @sidebar - 6)
        line = pad(" #{dot} #{name}", @sidebar)

        if status == "idle",
          do: [@dim, line, @reset],
          else: [colour, line, @reset]
      end)

    fit(
      [label("rooms")] ++
        rooms ++ [blank(), label("agents")] ++ agent_rows(agents),
      height,
      blank(),
      :top
    )
  end

  defp agent_rows([]), do: [[@dim, pad("   nobody yet", @sidebar), @reset]]
  defp agent_rows(agents), do: agents

  # Small dim caps, the way a section is named when there is no box to title.
  defp label(text),
    do: [@dim, pad(" " <> String.upcase(text), @sidebar), @reset]

  defp blank, do: pad("", @sidebar)

  # The palette sits where a completion menu belongs: just above what you are
  # typing, so the eye does not have to travel.
  defp palette_lines(state, width) do
    case State.palette(state) do
      [] ->
        []

      commands ->
        selected = State.selected(state)
        shown = Enum.take(commands, 8)
        hidden = length(commands) - length(shown)

        [heading("commands", width)] ++
          Enum.map(shown, &palette_line(&1, &1 == selected, width)) ++
          if hidden > 0,
            do: [[@dim, pad("   … and #{hidden} more", width), @reset]],
            else: []
    end
  end

  defp palette_line({name, arguments, description}, selected?, width) do
    left = "/#{name}#{if arguments == "", do: "", else: " " <> arguments}"
    column = min(34, max(div(width, 2), 14))
    marker = if selected?, do: "▸ ", else: "  "
    text = pad(marker <> cut(left, column - 3), column) <> pad(description, width - column)

    if selected?,
      do: [@bold, @green, text, @reset],
      else: [@cyan, pad(marker, 2), @reset, @dim, String.slice(text, 2..-1//1), @reset]
  end

  @doc false
  def help(state, height, width) do
    lines = help_lines(width)
    visible = max(height - 2, 1)
    max_scroll = max(length(lines) - visible, 0)
    offset = min(state.scroll, max_scroll)

    footer =
      if max_scroll > 0,
        do: [[@dim, pad(" ↑↓ for more · Esc or ? to close", width), @reset]],
        else: [[@dim, pad(" Esc or ? to close", width), @reset]]

    ([heading("how to use Roundtable", width)] ++
       (lines |> Enum.drop(offset) |> Enum.take(visible)) ++ footer)
    |> fit(height, pad("", width), :top)
  end

  @sections [
    {"Talking",
     [
       {"<message>", "post to the room; everyone reads it next turn"},
       {"@name <message>", "assign a turn to that participant"},
       {"@all <message>", "assign to everyone in the room"},
       {"Tab", "cycle the recipient, or complete a command"}
     ]},
    {"Getting around",
     [
       {"↑ ↓  PgUp PgDn", "scroll, or choose in the command palette"},
       {"^P  ^T  ^G", "roster · changes pane · lazygit"},
       {"^L", "redraw"},
       {"Esc", "close a pane, or clear the line"},
       {"^U  ^W  Home  End", "edit the line"},
       {"^C   ^D", "leave; running turns carry on"}
     ]}
  ]

  defp help_lines(width) do
    {talking, rest} = Enum.split(@sections, 1)

    entries =
      Enum.flat_map(talking, &section/1) ++
        [{:section, "Commands"}] ++
        Enum.map(Commands.all(), fn {name, arguments, description} ->
          {"/#{name}#{if arguments == "", do: "", else: " " <> arguments}", description}
        end) ++
        Enum.flat_map(rest, &section/1)

    Enum.map(entries, fn
      {:section, title} ->
        [@bold, pad(" " <> title, width), @reset]

      {keys, description} ->
        column = min(32, max(div(width, 2), 12))

        [
          @cyan,
          pad("  " <> cut(keys, column - 3), column),
          @reset,
          pad(description, width - column)
        ]
    end)
  end

  @doc false
  def roster(state, height, width) do
    header = heading("participants · #{length(state.agents)}", width)

    blocks =
      Enum.flat_map(state.agents, fn agent ->
        status = State.agent_status(agent, state.runs)
        {dot, colour} = agent_dot(status)
        model = agent.model || "provider default"

        headline =
          " #{dot} @#{agent.name}  #{agent.provider} · #{model} · #{agent.cost_tier}"

        role =
          case agent.role do
            nil -> ["   no role set — /role #{agent.name} <what they should do>"]
            "" -> ["   no role set — /role #{agent.name} <what they should do>"]
            text -> text |> Markdown.wrap(width - 4) |> Enum.map(&("   " <> &1))
          end

        [[colour, pad(headline, width), @reset]] ++
          Enum.map(role, &[@dim, pad(&1, width), @reset]) ++
          [pad("", width)]
      end)

    lines =
      case blocks do
        [] -> [[@dim, pad(" No participants yet — /agent <name> <provider>", width), @reset]]
        list -> list
      end

    fit([header | lines], height, pad("", width), :top)
  end

  @doc false
  def changes_lines(state, width, max_height) do
    directory = State.watched_directory(state)

    cond do
      not state.changes_visible or is_nil(directory) ->
        []

      match?({:error, _}, state.changes) ->
        {:error, reason} = state.changes
        [heading("changes", width), [@dim, pad(" " <> cut(reason, width - 1), width), @reset]]

      is_nil(state.changes) ->
        []

      state.changes.entries == [] ->
        [
          heading("changes · #{state.changes.branch}", width),
          [@dim, pad(" working tree clean", width), @reset]
        ]

      true ->
        summary =
          " #{length(state.changes.entries)} #{plural(length(state.changes.entries))}, " <>
            "+#{state.changes.added} -#{state.changes.removed}"

        rows = max(max_height - 2, 1)
        shown = Enum.take(state.changes.entries, rows)
        hidden = length(state.changes.entries) - length(shown)

        [heading("changes · #{state.changes.branch}", width)] ++
          Enum.map(shown, &entry_line(&1, width)) ++
          if hidden > 0 do
            [[@dim, pad("  …and #{hidden} more", width), @reset]]
          else
            []
          end ++
          [[@bold, pad(summary, width), @reset]]
    end
  end

  defp section({title, entries}), do: [{:section, title} | entries]

  defp plural(1), do: "file"
  defp plural(_), do: "files"

  defp heading(text, width) do
    text = cut(text, max(width - 2, 0))
    trailing = max(width - width(text) - 2, 0)

    [@dim, text, " ", String.duplicate("─", trailing), " ", @reset]
  end

  defp entry_line(entry, width) do
    counts =
      if entry.added + entry.removed > 0,
        do: "+#{entry.added} -#{entry.removed}",
        else: ""

    code = String.pad_leading(cut(entry.status, 2), 2)
    path = cut_left(entry.path, max(width - 5 - String.length(counts), 1))
    gap = max(width - 4 - width(path) - String.length(counts), 1)

    [
      entry_colour(entry.status),
      pad(" #{code} #{path}#{String.duplicate(" ", gap)}#{counts}", width),
      @reset
    ]
  end

  defp entry_colour("??"), do: @dim
  defp entry_colour("A" <> _), do: @green
  defp entry_colour("D" <> _), do: @red
  defp entry_colour("R" <> _), do: @cyan
  defp entry_colour(_), do: @yellow

  # Long paths are more useful from the tail: the file name beats the repo root.
  defp cut_left(text, width) when width <= 1, do: cut(text, width)

  defp cut_left(text, width) do
    if String.length(text) <= width do
      text
    else
      "…" <> String.slice(text, String.length(text) - width + 1, width - 1)
    end
  end

  defp agent_dot("running"), do: {"●", @green}
  defp agent_dot("approval"), do: {"◆", @yellow}
  defp agent_dot("queued"), do: {"◌", @dim}
  defp agent_dot(_), do: {"○", @dim}

  defp transcript(state, height, width) do
    lines = transcript_lines(state, width)
    max_scroll = max(length(lines) - height, 0)
    offset = max_scroll - min(state.scroll, max_scroll)

    lines
    |> Enum.drop(offset)
    |> Enum.take(height)
    |> fit(height, pad("", width), :bottom)
  end

  @doc false
  def transcript_lines(%{room: nil}, width) do
    [
      [@bold, pad(" Nothing here yet.", width), @reset],
      pad("", width),
      [@dim, pad(" Make a room on a project directory:", width), @reset],
      [@cyan, pad("   /new-room My Project /path/to/project", width), @reset],
      pad("", width),
      [@dim, pad(" Then bring someone in, and give them work:", width), @reset],
      [@cyan, pad("   /agent ada claude --role \"Implement what I ask for.\"", width), @reset],
      [@cyan, pad("   @ada have a look at the tests", width), @reset],
      pad("", width),
      [@dim, pad(" Press ? for everything else.", width), @reset]
    ]
  end

  def transcript_lines(%{messages: [], agents: []} = state, width) do
    [
      [@bold, pad(" #{state.room.name} is empty.", width), @reset],
      pad("", width),
      [@dim, pad(" Bring someone in:", width), @reset],
      [@cyan, pad("   /agent ada claude --role \"Implement what I ask for.\"", width), @reset],
      pad("", width),
      [@dim, pad(" Press ? for everything else.", width), @reset]
    ]
  end

  def transcript_lines(state, width) do
    messages =
      state.messages
      |> Enum.with_index()
      |> Enum.flat_map(fn {message, index} ->
        stamp = Calendar.strftime(message.inserted_at, "%H:%M")
        sender = cut(message.sender, @sender)
        colour = if message.kind == "agent", do: @cyan, else: @green
        head = "#{stamp} #{pad(sender, @sender)} "
        indent = String.duplicate(" ", width(head))
        body = width - width(head)

        # A blank line between turns: a wall of text is hard to read, and a
        # room is mostly other people's paragraphs.
        spacer = if index == 0, do: [], else: [pad("", width)]

        [first | continued] = message_lines(message.body, body)

        spacer ++
          [[@dim, stamp, @reset, " ", colour, @bold, pad(sender, @sender), @reset, " ", first]] ++
          Enum.map(continued, &[indent, &1])
      end)

    messages ++ approval_lines(state, width) ++ failure_lines(state, width)
  end

  defp approval_lines(state, width) do
    state.approvals
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {approval, index} ->
      summary = approval.params |> Jason.encode!() |> cut(width - 30)

      [
        [@yellow, pad("", width), @reset],
        [@yellow, pad(" ⚠ [#{index}] #{approval.agent} wants to use a tool", width), @reset],
        [@yellow, pad("   #{summary}", width), @reset],
        [
          @yellow,
          pad("   /approve accept #{index}   ·   /approve decline #{index}", width),
          @reset
        ]
      ]
    end)
  end

  defp failure_lines(state, width) do
    state.runs
    |> Enum.filter(&(&1.status in ["failed", "interrupted", "stopped"] and &1.error))
    |> Enum.take(3)
    |> Enum.map(fn run ->
      [
        @red,
        pad(" ✗ run #{run.id} #{run.agent.name}: #{cut(run.error, width - 24)}", width),
        @reset
      ]
    end)
  end

  defp input_line(state, cols) do
    bar = if state.mode == :command, do: @green, else: @dim
    placeholder = state.input == "" and state.mode == :message
    text = if placeholder, do: "Say something, or / for commands", else: state.input
    body = pad(cut(text, max(cols - 4, 0)), max(cols - 4, 0))

    [" ", bar, "▌", @reset, " ", if(placeholder, do: [@dim, body, @reset], else: body), " \n"]
  end

  defp status_line(state, cols) do
    left =
      state.status ||
        "?  help    ^P  who    ^T  changes    ^G  lazygit    ^C  quit"

    right = if state.connected, do: state.target, else: "disconnected"

    colour =
      cond do
        not state.connected -> @red
        state.status -> @yellow
        true -> @dim
      end

    room = max(cols - width(right) - 2, 0)
    [" ", colour, pad(cut(left, room), room), @reset, @dim, right, @reset, " "]
  end

  # Park the hardware cursor where the next character will land.
  defp cursor_to(state, rows, _cols) do
    column = 4 + width(String.slice(state.input, 0, state.cursor))
    "\e[?25h\e[#{rows - 1};#{column}H"
  end

  defp fit(rows, height, filler, align) do
    count = length(rows)

    cond do
      count == height -> rows
      count > height and align == :bottom -> Enum.drop(rows, count - height)
      count > height -> Enum.take(rows, height)
      align == :bottom -> List.duplicate(filler, height - count) ++ rows
      true -> rows ++ List.duplicate(filler, height - count)
    end
  end

  # A reply is Markdown: headings, bullets and fenced code, wrapped on words.
  defp message_lines(body, width) do
    body
    |> Markdown.blocks()
    |> Enum.flat_map(&block_lines(&1, width))
    |> trim_trailing_blanks()
    |> case do
      [] -> [pad("", width)]
      lines -> lines
    end
  end

  defp block_lines(:blank, width), do: [pad("", width)]

  defp block_lines({:heading, text}, width) do
    text |> Markdown.plain() |> Markdown.wrap(width) |> Enum.map(&[@bold, pad(&1, width), @reset])
  end

  defp block_lines({:bullet, text}, width) do
    # wrap/2 always yields at least one line, even for an empty bullet.
    [first | rest] = Markdown.plain(text) |> Markdown.wrap(max(width - 2, 1))

    [[@green, "• ", @reset, pad(first, width - 2)]] ++
      Enum.map(rest, &pad("  " <> &1, width))
  end

  # A gutter rather than fences: the bar says "code" without spending a line.
  defp block_lines({:code, _language, lines}, width) do
    Enum.map(lines, fn line ->
      [@dim, "▏", @reset, @cyan, pad(" " <> cut(line, max(width - 2, 0)), width - 1), @reset]
    end)
  end

  defp block_lines({:text, text}, width) do
    text |> Markdown.plain() |> Markdown.wrap(width) |> Enum.map(&pad(&1, width))
  end

  defp trim_trailing_blanks(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(IO.iodata_to_binary(&1) |> String.trim() == ""))
    |> Enum.reverse()
  end

  defp pad(_text, width) when width <= 0, do: ""

  defp pad(text, width) do
    text = cut(text, width)
    text <> String.duplicate(" ", width - width(text))
  end

  defp cut(_text, width) when width <= 0, do: ""

  defp cut(text, width) do
    text = text |> to_string() |> String.replace(~r/[\x00-\x1f]/, " ")

    if width(text) <= width do
      text
    else
      String.slice(text, 0, max(width - 1, 0)) <> "…"
    end
  end

  defp width(text), do: text |> to_string() |> String.length()
end
