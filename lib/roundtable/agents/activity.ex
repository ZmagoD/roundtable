defmodule Roundtable.Agents.Activity do
  @moduledoc """
  What a running turn is doing right now, in a few words for the room.

  A turn can spend many minutes inside one tool call — a test suite, a CI
  wait — and emit no text the whole time, which looks the same as a hung
  process. Each adapter names the step from its provider's own tool events;
  the wording is decided here so every provider reads alike.
  """

  @fixed %{
    "BashOutput" => "Checking a background command",
    "Grep" => "Searching the code",
    "Glob" => "Searching the code",
    "LS" => "Searching the code",
    "WebFetch" => "Looking something up on the web",
    "WebSearch" => "Looking something up on the web",
    "TodoWrite" => "Updating its plan"
  }

  @doc "The step for a tool call in the Anthropic Messages format."
  def tool(name, input) when not is_map(input), do: tool(name, %{})
  def tool("Bash", input), do: detail("Running a shell command", input["description"])
  def tool(name, input) when name in ["Read", "NotebookRead"], do: detail("Reading", file(input))

  def tool(name, input) when name in ["Edit", "MultiEdit", "Write", "NotebookEdit"],
    do: detail("Editing", file(input))

  def tool(name, input) when name in ["Task", "Agent"],
    do: detail("Waiting for a subagent", input["description"])

  def tool("mcp__roundtable__" <> _, _input), do: "Using the room tools"
  def tool(name, _input), do: Map.get(@fixed, name, "Using #{name}")

  @doc "The step for a Codex thread item, or nil for an item that is not one."
  def codex(%{"type" => "commandExecution"}), do: "Running a shell command"

  def codex(%{"type" => "fileChange", "changes" => [%{"path" => path} | _]}),
    do: detail("Editing", Path.basename(path))

  def codex(%{"type" => "fileChange"}), do: "Editing files"
  def codex(%{"type" => "mcpToolCall", "server" => "roundtable"}), do: "Using the room tools"
  def codex(%{"type" => "mcpToolCall", "tool" => tool}), do: "Using #{tool}"
  def codex(%{"type" => "dynamicToolCall", "tool" => tool}), do: "Using #{tool}"
  def codex(%{"type" => "collabAgentToolCall"}), do: "Waiting for a subagent"
  def codex(%{"type" => "webSearch"}), do: "Looking something up on the web"
  def codex(%{"type" => "reasoning"}), do: thinking()
  def codex(_item), do: nil

  @doc "Between tool calls: the model is working out what to do next."
  def thinking, do: "Thinking"

  defp file(input) do
    case input["file_path"] || input["notebook_path"] do
      path when is_binary(path) -> Path.basename(path)
      _ -> nil
    end
  end

  # The agent's own description of a command is the most useful thing to show,
  # and also the one most likely to run long.
  defp detail(step, text) when is_binary(text) and text != "",
    do: "#{step}: #{String.slice(text, 0, 120)}"

  defp detail(step, _text), do: step
end
