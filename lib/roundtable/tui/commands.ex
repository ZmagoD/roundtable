defmodule Roundtable.TUI.Commands do
  @moduledoc """
  Every command the client understands, in one list.

  The help screen and the palette that appears as you type `/` both read this,
  so a command cannot exist in one and be missing from the other — which is
  how `/commands` quietly went stale before it was removed.
  """

  @commands [
    {"who", "", "roster: provider, model, cost tier, role, status"},
    {"providers", "", "which agent CLIs are installed"},
    {"profiles", "", "participant profiles you can add to a room"},
    {"hire", "<profile> [name]", "add a saved profile to this room"},
    {"models", "<provider> [filter]", "model names that provider offers"},
    {"agent", "<name> <provider> [--model m] [--role text] [--tier t]", "add a participant"},
    {"role", "<agent> <text>", "change what a participant is for"},
    {"model", "<agent> <id|default>", "pin a model, or hand the choice back"},
    {"auto", "<agent> on|off", "let it approve its own tool use"},
    {"rename", "<agent> <new>", "rename one, before its first turn"},
    {"remove", "<agent>", "remove a participant; its messages stay"},
    {"stop", "<agent>", "stop its queue"},
    {"reset", "<agent>", "clear its session; history stays"},
    {"retry", "[run]", "retry the newest failed run, or one by id"},
    {"approve", "accept|decline [n]", "answer a pending tool approval"},
    {"rooms", "", "list the rooms"},
    {"room", "<name>", "switch to one"},
    {"new-room", "<name> <dir>", "create one; . is where you started the client"},
    {"context", "[text]", "show the room's shared brief, or set it"},
    {"remove-room", "<name>", "delete a room and everything in it"},
    {"ask", "<room>/<agent> <question>", "their answer is posted back here"},
    {"delegate", "<room>/<agent> <task>", "they report back when it is done"},
    {"changes", "[on|off]", "the git pane for this room's directory"},
    {"lazygit", "", "hand the terminal over; quit it to come back"},
    {"refresh", "", "re-read the room now"},
    {"help", "", "this screen"},
    {"quit", "", "leave; running turns carry on"}
  ]

  @doc "Every command, as `{name, arguments, description}`."
  def all, do: @commands

  @doc """
  The commands a partially typed one could become.

  Everything while the line is just `/`, narrowing as it is typed. Once the
  command is complete and an argument has been started there is nothing left
  to choose, so the palette gets out of the way.
  """
  def matching("/" <> typed) do
    case String.split(typed, " ", parts: 2) do
      [name] ->
        Enum.filter(@commands, fn {command, _, _} -> String.starts_with?(command, name) end)

      _ ->
        []
    end
  end

  def matching(_input), do: []

  @doc "The longest prefix every match shares, for Tab to complete to."
  def common_prefix([]), do: ""
  def common_prefix([{name, _, _}]), do: name

  def common_prefix([{first, _, _} | rest]) do
    Enum.reduce(rest, first, fn {name, _, _}, acc -> shared(acc, name, "") end)
  end

  defp shared(<<c, a::binary>>, <<c, b::binary>>, acc), do: shared(a, b, acc <> <<c>>)
  defp shared(_, _, acc), do: acc
end
