defmodule Roundtable.ModelsTest do
  use ExUnit.Case, async: false
  alias Roundtable.Agents

  setup do
    directory = Path.join(System.tmp_dir!(), "rt-models-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    executable = Path.join(directory, "opencode")
    listing = Path.join(directory, "models")
    File.write!(executable, "#!/bin/sh\ncat '#{listing}'\n")
    File.chmod!(executable, 0o700)
    File.write!(listing, "ollama/qwen3:8b\n")
    path = System.fetch_env!("PATH")
    key = {Agents, :models, "opencode"}
    previous = :persistent_term.get(key, :missing)
    :persistent_term.erase(key)
    System.put_env("PATH", directory <> ":" <> path)

    on_exit(fn ->
      System.put_env("PATH", path)

      if previous == :missing,
        do: :persistent_term.erase(key),
        else: :persistent_term.put(key, previous)

      File.rm_rf!(directory)
    end)

    %{listing: listing, key: key}
  end

  test "refresh discovers newly configured Ollama models without restarting", %{listing: listing} do
    assert Agents.models("opencode") == ["ollama/qwen3:8b"]
    File.write!(listing, "ollama/qwen3:8b\nollama/qwen3-coder:30b\n")
    assert Agents.models("opencode") == ["ollama/qwen3:8b"]

    assert Agents.refresh_models("opencode") == ["ollama/qwen3:8b", "ollama/qwen3-coder:30b"]
    assert Agents.models("opencode") == ["ollama/qwen3:8b", "ollama/qwen3-coder:30b"]
  end

  test "expired and legacy cache entries are replaced", %{key: key} do
    :persistent_term.put(key, {System.monotonic_time(:millisecond) - 1, ["old/model"]})
    assert Agents.models("opencode") == ["ollama/qwen3:8b"]

    :persistent_term.put(key, ["old/model"])
    assert Agents.models("opencode") == ["ollama/qwen3:8b"]
  end
end
