defmodule Roundtable.TUI.Render do
  @moduledoc """
  Draws the whole screen from a `Roundtable.TUI.State`.

  Pure: state in, iodata out, so the layout is testable without a terminal.
  Every line is padded to the exact terminal width *before* colour codes are
  added, because escape sequences occupy no columns and would otherwise throw
  the box drawing off.
  """
  alias Roundtable.TUI.State

  @sidebar 20
  @chrome 6

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
    left = sidebar(state, body)
    right = transcript(state, body, cols - @sidebar - 3)

    [
      "\e[H\e[2J",
      top_border(state, cols),
      Enum.zip(left, right) |> Enum.map(fn {l, r} -> ["│", l, "│", r, "│\n"] end),
      middle_border(cols),
      input_line(state, cols),
      plain_border(cols),
      status_line(state, cols),
      bottom_border(cols),
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

  @doc "How many transcript lines the current room would produce."
  def total_lines(%State{size: {_, cols}} = state),
    do: length(transcript_lines(state, cols - @sidebar - 3))

  defp top_border(state, cols) do
    title =
      case state.room do
        nil -> "no room"
        room -> "#{room.name} · #{room.directory}"
      end

    right = cols - @sidebar - 3
    label = cut(title, max(right - 3, 0))

    [
      "┌─ rooms ",
      String.duplicate("─", max(@sidebar - 8, 0)),
      "┬─ ",
      @bold,
      label,
      @reset,
      " ",
      String.duplicate("─", max(right - 3 - width(label), 0)),
      "┐\n"
    ]
  end

  defp middle_border(cols),
    do: [
      "├",
      String.duplicate("─", @sidebar),
      "┴",
      String.duplicate("─", cols - @sidebar - 3),
      "┤\n"
    ]

  defp plain_border(cols), do: ["├", String.duplicate("─", cols - 2), "┤\n"]
  defp bottom_border(cols), do: ["└", String.duplicate("─", cols - 2), "┘"]

  defp sidebar(state, height) do
    rooms =
      Enum.map(state.rooms, fn room ->
        current? = state.room && room.id == state.room.id
        marker = if current?, do: "▸ ", else: "  "
        line = pad(marker <> room.name, @sidebar)
        if current?, do: [@bold, line, @reset], else: line
      end)

    agents =
      Enum.map(state.agents, fn agent ->
        status = State.agent_status(agent, state.runs)
        {dot, colour} = agent_dot(status)
        name = cut(agent.name, @sidebar - 12)
        line = pad(" #{dot} #{pad(name, @sidebar - 12)} #{cut(status, 8)}", @sidebar)
        [colour, line, @reset]
      end)

    rows =
      rooms ++
        [pad("", @sidebar), [@dim, pad(" agents", @sidebar), @reset]] ++
        case agents do
          [] -> [[@dim, pad("  none yet", @sidebar), @reset]]
          list -> list
        end

    fit(rows, height, pad("", @sidebar), :top)
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
  def transcript_lines(state, width) do
    messages =
      Enum.flat_map(state.messages, fn message ->
        stamp = Calendar.strftime(message.inserted_at, "%H:%M")
        sender = cut(message.sender, 8)
        colour = if message.kind == "agent", do: @cyan, else: @bold
        head = "#{stamp} #{pad(sender, 8)} "
        indent = String.duplicate(" ", width(head))

        message.body
        |> wrap(width - width(head))
        |> Enum.with_index()
        |> Enum.map(fn
          {text, 0} ->
            [
              @dim,
              stamp,
              @reset,
              " ",
              colour,
              pad(sender, 8),
              @reset,
              " ",
              pad(text, width - width(head))
            ]

          {text, _} ->
            [indent, pad(text, width - width(head))]
        end)
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
    prompt = if state.mode == :command, do: ":", else: ">"
    inner = cols - 2
    text = cut(state.input, inner - 3)
    ["│ ", @bold, prompt, @reset, " ", pad(text, inner - 3), "│\n"]
  end

  defp status_line(state, cols) do
    left =
      state.status ||
        "/help · Tab recipient · ↑↓ scroll · ^L redraw · ^C quit"

    right = if state.connected, do: state.target, else: "disconnected"

    colour =
      cond do
        not state.connected -> @red
        state.status -> @yellow
        true -> @dim
      end

    inner = cols - 2
    room = max(inner - width(right) - 3, 0)
    ["│ ", colour, pad(cut(left, room), room), @reset, " ", @dim, right, @reset, " │\n"]
  end

  # Park the hardware cursor where the next character will land.
  defp cursor_to(state, rows, _cols) do
    column = 5 + width(String.slice(state.input, 0, state.cursor))
    "\e[?25h\e[#{rows - 2};#{column}H"
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

  defp wrap(text, width) when width > 0 do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case chunk(line, width) do
        [] -> [""]
        chunks -> chunks
      end
    end)
  end

  defp wrap(_, _), do: [""]

  defp chunk(line, width) do
    line
    |> String.graphemes()
    |> Enum.chunk_every(width)
    |> Enum.map(&Enum.join/1)
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
