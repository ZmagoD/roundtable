defmodule Roundtable.FakeCLIs do
  @moduledoc false
  # Puts stand-in provider executables first on PATH so "installed" and model
  # discovery are answered by files the test controls, not by the machine.
  def install(providers, opencode_models \\ ["ollama/qwen3:8b", "ollama/qwen3-coder:30b"]) do
    dir = Path.join(System.tmp_dir!(), "rt-clis-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    for name <- providers do
      path = Path.join(dir, name)
      body = if name == "opencode", do: "echo '#{Enum.join(opencode_models, "\n")}'", else: "true"
      File.write!(path, "#!/bin/sh\n#{body}\n")
      File.chmod!(path, 0o700)
    end

    path = System.fetch_env!("PATH")
    key = {Roundtable.Agents, :models, "opencode"}
    previous = :persistent_term.get(key, :missing)
    :persistent_term.erase(key)
    System.put_env("PATH", dir <> ":" <> path)

    fn ->
      System.put_env("PATH", path)

      if previous == :missing,
        do: :persistent_term.erase(key),
        else: :persistent_term.put(key, previous)

      File.rm_rf!(dir)
    end
  end
end
