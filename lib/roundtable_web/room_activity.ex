defmodule RoundtableWeb.RoomActivity do
  @moduledoc false

  @states [
    {"running", "working", "Working"},
    {"approval", "awaiting approval", "Approval"},
    {"waiting_quota", "waiting for quota", "Quota"},
    {"queued", "queued", "Queued"}
  ]

  def summaries(rooms, work) do
    children = Enum.group_by(rooms, & &1.parent_id)

    Map.new(rooms, fn room ->
      own = counts(room.id, work)
      nested = subtree_counts(room.id, children, work)
      {room.id, summary(own, nested)}
    end)
  end

  defp counts(id, work),
    do: Map.new(@states, fn {state, _, _} -> {state, work[{id, state}] || 0} end)

  defp subtree_counts(id, children, work) do
    Enum.reduce(Map.get(children, id, []), %{}, fn child, acc ->
      acc |> merge(counts(child.id, work)) |> merge(subtree_counts(child.id, children, work))
    end)
  end

  defp merge(left, right), do: Map.merge(left, right, fn _, a, b -> a + b end)

  defp summary(own, nested) do
    sub_rooms? = Enum.all?(own, fn {_, count} -> count == 0 end)
    counts = if sub_rooms?, do: nested, else: own
    active = Enum.filter(@states, fn {state, _, _} -> Map.get(counts, state, 0) > 0 end)

    case active do
      [] ->
        %{state: "idle", text: "Idle", label: "Idle"}

      [{state, _, text} | _] ->
        label = Enum.map_join(active, ", ", fn {key, label, _} -> "#{counts[key]} #{label}" end)
        suffix = if sub_rooms?, do: " in sub-rooms", else: ""
        mixed = if length(active) > 1, do: " +", else: ""

        %{
          state: state,
          text: text <> mixed <> if(sub_rooms?, do: " ↳", else: ""),
          label: label <> suffix
        }
    end
  end
end
