defmodule Roundtable.FixtureAdapter do
  @moduledoc false
  @behaviour Roundtable.Agents.Adapter
  alias Roundtable.Agents.Worker
  def id, do: "fixture"
  def label, do: "Fixture CLI"
  def command(_agent, _prompt), do: {"python3", [Path.expand("test/support/fixture_cli.py")]}
  def start(state), do: Worker.write(state, %{prompt: state.prompt})
  def approve(state, _id, decision, _request), do: Worker.write(state, %{decision: decision})
  def exit_status(code, _), do: {"failed", "Unexpected exit #{code}"}

  def handle_event(%{"type" => "session", "id" => id}, state) do
    Roundtable.Coordinator.event(state.run.id, {:session, id})
    state
  end

  def handle_event(%{"type" => "approval", "id" => id}, state),
    do: Worker.approval(state, id, %{"command" => "test only"})

  def handle_event(%{"type" => "text", "text" => text}, state), do: Worker.put_output(state, text)
  def handle_event(%{"type" => "done"}, state), do: %{state | finished: {"completed", nil}}
  def handle_event(_, state), do: state
end
