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

  @doc """
  Model names worth offering for a provider.

  Asked of the CLI where it can answer: `opencode models` lists what that
  installation can actually reach, which is the only trustworthy source and
  changes without us. Claude Code has no such command, so these are the aliases
  its own `--help` documents; it takes full names too. Codex has neither, so it
  gets nothing rather than a list invented here.

  Suggestions only — the field stays free text, because a model added tomorrow
  should not need a release.
  """
  def models(provider)

  def models("opencode"), do: cached_models("opencode", ["models"])
  def models("claude"), do: ["fable", "opus", "sonnet"]
  def models(_provider), do: []

  # Listing 400-odd models means running a CLI; once per boot is plenty.
  defp cached_models(executable, args) do
    key = {__MODULE__, :models, executable}

    case :persistent_term.get(key, :missing) do
      :missing ->
        models = read_models(executable, args)
        :persistent_term.put(key, models)
        models

      models ->
        models
    end
  end

  defp read_models(executable, args) do
    case System.find_executable(executable) do
      nil ->
        []

      path ->
        case System.cmd(path, args, stderr_to_stdout: true) do
          {output, 0} -> output |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
          _ -> []
        end
    end
  rescue
    _ -> []
  end

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
