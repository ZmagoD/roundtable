defmodule Roundtable.FixtureMissingAdapter do
  @moduledoc false
  # An adapter whose CLI is not on PATH, so the "not installed" path is real
  # rather than mocked.
  @behaviour Roundtable.Agents.Adapter

  def id, do: "missing"
  def label, do: "Missing CLI"
  def command(_agent, _prompt), do: {"roundtable-no-such-cli", []}
  def start(state), do: state
  def approve(_state, _id, _decision, _request), do: :unsupported
  def exit_status(code, _state), do: {"failed", "exited #{code}"}
  def handle_event(_event, state), do: state
end
