defmodule Roundtable.Agents do
  @moduledoc """
  The registry of agent adapters.

  Adapters are configured rather than hard-coded so a new provider can be added
  without touching the coordinator or either client.
  """
  def adapters do
    Application.get_env(:roundtable, :adapters, [
      Roundtable.Agents.Codex,
      Roundtable.Agents.Claude,
      Roundtable.Agents.OpenCode
    ])
  end

  def ids, do: Enum.map(adapters(), & &1.id())

  def fetch!(id),
    do: Enum.find(adapters(), &(&1.id() == id)) || raise("Unknown agent adapter: #{id}")

  def providers do
    Enum.map(adapters(), fn adapter ->
      {executable, _} = adapter.command(%{session_id: nil, model: nil}, "")

      %{
        id: adapter.id(),
        label: adapter.label(),
        installed: System.find_executable(executable) != nil
      }
    end)
  end
end
