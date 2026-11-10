defmodule Roundtable.Failover do
  @moduledoc """
  Chooses who takes over when a participant runs out of provider quota.

  The role is the failover group: participants in the same room whose role
  text matches back each other up, no configuration needed. The highest cost
  tier goes first, so a rescued turn keeps the capability it was given and the
  local economy model is the last link rather than the first. A participant
  that is already working, benched on quota, or whose CLI is missing is never
  handed work.
  """

  alias Roundtable.{Agents, Chat, Usage}
  alias Roundtable.Chat.Agent

  @ranks %{"premium" => 0, "standard" => 1, "economy" => 2, "unknown" => 3}

  @doc """
  The participant that should take the interrupted turn, or `nil` when nobody
  can — the caller then falls back to waiting out the quota or failing.
  """
  def choose(failed) do
    failed.room_id
    |> Chat.agents()
    |> Enum.filter(&candidate?(&1, failed, installed()))
    |> Enum.sort_by(&{Map.fetch!(@ranks, &1.cost_tier), &1.name})
    |> List.first()
  end

  # A participant without a role has nothing to match against, so empty roles
  # form no pool however many of them there are.
  defp candidate?(member, failed, installed) do
    member.id != failed.id and pool_role(failed) != nil and pool_role(member) == pool_role(failed) and
      installed[member.provider] and not Chat.busy?(member.id) and
      Usage.level(reading(member.provider)) == "ok"
  end

  defp pool_role(%Agent{role: role}) when role in [nil, ""], do: nil
  defp pool_role(%Agent{role: role}), do: String.trim(role)

  # Tests run without provider CLIs, so the check is injectable the same way
  # the worker is.
  defp installed do
    Application.get_env(:roundtable, :installed_providers) ||
      Map.new(Agents.providers(), fn %{id: id, installed: installed} -> {id, installed} end)
  end

  # No reading is not a bad reading: an unreported provider still gets its
  # chance, the same as a participant invited before any turn ran.
  defp reading(provider), do: Map.get(Chat.provider_usage(), provider)
end
